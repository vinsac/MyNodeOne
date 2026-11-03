"""The Admin UI's vLLM download status comes from the pods, not from Redis keys nothing writes."""

import asyncio
import threading
from types import SimpleNamespace as NS

import pytest
from kubernetes.client.exceptions import ApiException
from kubernetes.config import ConfigException

from conftest import ADMIN_KEY, bearer

MODEL = "Qwen/Qwen3-14B-AWQ"


def init_status(running=False, exit_code=None, last_exit_code=None, name="model-downloader"):
    terminated = NS(exit_code=exit_code) if exit_code is not None else None
    last = NS(terminated=NS(exit_code=last_exit_code)) if last_exit_code is not None else NS(terminated=None)
    return NS(name=name, state=NS(running=NS() if running else None, terminated=terminated), last_state=last)


def pod(*statuses, name="vllm-0"):
    return NS(metadata=NS(name=name), status=NS(init_container_statuses=list(statuses) or None))


class FakeCore:
    def __init__(self, pods=(), list_error=None, hang=False, configmap_error=None):
        self.pods, self.list_error, self.hang = list(pods), list_error, hang
        self.configmap_error = configmap_error
        self.selectors = []
        self.release = threading.Event()

    def list_namespaced_pod(self, namespace, label_selector=None, **kwargs):
        self.selectors.append((namespace, label_selector))
        if self.hang:
            self.release.wait(30)
        if self.list_error:
            raise self.list_error
        return NS(items=self.pods)

    def read_namespaced_config_map(self, name, namespace, **kwargs):
        if self.configmap_error:
            raise self.configmap_error
        assert name == "vllm-config"
        return NS(data={"MODEL_NAME": MODEL})


@pytest.fixture
def status(client, gateway, fake_postgres, monkeypatch):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])

    def read(core):
        monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (core, None))
        response = client.get("/admin/models", headers=bearer(ADMIN_KEY))
        assert response.status_code == 200
        return response.json()["download_status"]
    return read


def test_running_init_container_is_downloading(status):
    core = FakeCore([pod(init_status(running=True))])

    assert status(core) == {"status": "downloading", "model": MODEL, "error": None}
    assert core.selectors == [("llmapi", "app=vllm")]


def test_failed_run_names_the_logs_to_read(status):
    result = status(FakeCore([pod(init_status(exit_code=1), name="vllm-1")]))

    assert result["status"] == "failed"
    assert result["model"] == MODEL
    assert "kubectl logs -n llmapi vllm-1 -c model-downloader" in result["error"]


def test_waiting_after_a_failed_run_is_failed(status):
    assert status(FakeCore([pod(init_status(last_exit_code=1))]))["status"] == "failed"


def test_a_failure_on_one_pod_outranks_a_download_on_another(status):
    core = FakeCore([pod(init_status(running=True)), pod(init_status(exit_code=1), name="vllm-1")])

    assert status(core)["status"] == "failed"


@pytest.mark.parametrize("pods", [
    [],
    [pod()],
    [pod(init_status())],
    [pod(init_status(exit_code=0))],
    [pod(init_status(last_exit_code=0))],
    [pod(init_status(running=True, name="another-init"))],
])
def test_nothing_to_report(status, pods):
    assert status(FakeCore(pods)) is None


def test_unreadable_configmap_only_loses_the_model_name(status):
    core = FakeCore([pod(init_status(running=True))], configmap_error=ApiException(status=403))

    assert status(core) == {"status": "downloading", "model": "unknown", "error": None}


def test_stale_redis_keys_are_ignored(status, fake_redis):
    """An older init wrote these and nothing clears them, so one could say 'downloading' forever."""
    fake_redis.data.update({
        "vllm:download:status": "downloading",
        "vllm:download:model": "old/model",
        "vllm:download:error": "old error",
    })

    assert status(FakeCore()) is None


def test_stale_redis_keys_dont_hide_that_status_is_unknown(status, fake_redis):
    fake_redis.data["vllm:download:status"] = "downloading"

    assert status(FakeCore(list_error=ApiException(status=500)))["status"] == "unavailable"


@pytest.mark.parametrize("error", [ApiException(status=403), ApiException(status=500), RuntimeError("secret detail")])
def test_pod_read_failure_is_unavailable_not_empty(status, error):
    assert status(FakeCore(list_error=error)) == {"status": "unavailable", "model": "unknown", "error": None}


def test_no_kubernetes_config_is_unavailable(client, gateway, fake_postgres, monkeypatch):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])

    def no_config():
        raise ConfigException("no config")
    monkeypatch.setattr(gateway, "get_k8s_clients", no_config)

    body = client.get("/admin/models", headers=bearer(ADMIN_KEY)).json()

    assert body["download_status"]["status"] == "unavailable"
    assert "models" in body


def test_slow_kubernetes_api_doesnt_stall_the_model_list(gateway, monkeypatch):
    monkeypatch.setattr(gateway, "VLLM_DOWNLOAD_STATUS_TIMEOUT_SECONDS", 0.05)
    core = FakeCore(hang=True)
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (core, None))

    async def scenario():
        try:
            # The hang is released only after this returns, so it can't pass by finishing.
            return await gateway._vllm_download_status()
        finally:
            core.release.set()

    assert asyncio.run(scenario())["status"] == "unavailable"


def test_page_renders_every_status_it_can_get(client):
    html = client.get("/admin/dashboard").text

    assert "ds.status === 'downloading'" in html
    assert "ds.status === 'failed'" in html
    assert "ds.status === 'unavailable'" in html
    assert "vLLM download status unavailable" in html


def test_status_needs_the_admin_scope(client, fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["inference"])

    assert client.get("/admin/models", headers=bearer(ADMIN_KEY)).status_code == 403
