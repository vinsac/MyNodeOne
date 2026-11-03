"""R11: the Kubernetes client is synchronous, so it must never run on the event loop."""

import ast
import asyncio
import pathlib
import socket
import threading
import time
from unittest.mock import MagicMock

import httpx
import pytest
from kubernetes import client as k8s

from conftest import ADMIN_KEY, bearer

GGUF = "https://huggingface.co/org/repo/resolve/main/model.gguf"
HANDLERS = [
    ("GET", "/admin/config", None),
    ("POST", "/admin/config", {"hf_token": "hf_test"}),
    ("POST", "/admin/backend/vllm", {"model_id": "org/model"}),
    ("POST", "/admin/backend/llamacpp", {"model_url": GGUF}),
    ("POST", "/admin/backend/embedding", {"model_url": GGUF}),
    ("POST", "/admin/backend/vllm/config", {"max_model_len": 2048}),
    ("POST", "/admin/backend/llamacpp/config", {"context_size": 2048}),
    ("POST", "/admin/backend/embedding/config", {"context_size": 2048}),
    ("GET", "/admin/cluster/gpus", None),
    ("GET", "/admin/backend/vllm/replicas", None),
    ("POST", "/admin/backend/vllm/scale", {"replicas": 1}),
    ("POST", "/admin/backend/llamacpp/scale", {"replicas": 1}),
]
HANDLER_IDS = [f"{method} {path}" for method, path, _ in HANDLERS]

# A call that blocks the loop stalls it for at least as long as the call, so anything
# longer than the limit is always caught. The limit only has to stay clear of scheduler
# noise, which reached 0.163s here with a load average of 29.
LOOP_STALL_LIMIT = 0.5
BLOCKING_CALL_SECONDS = 0.75


class FakeK8sApi:
    """A generated Kubernetes API class, whose every method blocks its thread."""

    def __init__(self, block=None):
        self.calls = []
        self.block = block

    def __getattr__(self, name):
        def call(*args, **kwargs):
            self.calls.append((name, kwargs))
            if self.block is not None:
                self.block()
            return MagicMock()
        return call


@pytest.fixture
def admin(fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])


async def request(gateway, method, path, body):
    transport = httpx.ASGITransport(gateway.app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as http:
        return await http.request(method, path, json=body, headers=bearer(ADMIN_KEY))


async def with_loop_gap(coro):
    """Await coro while a ticker measures the longest the event loop was unavailable."""
    task = asyncio.ensure_future(coro)
    longest = 0.0
    last = time.monotonic()
    while not task.done():
        await asyncio.sleep(0.005)
        now = time.monotonic()
        longest = max(longest, now - last)
        last = now
    return await task, longest


@pytest.mark.parametrize("method,path,body", HANDLERS, ids=HANDLER_IDS)
def test_handler_keeps_the_loop_running_and_times_every_call(gateway, admin, monkeypatch, method, path, body):
    def slow():
        time.sleep(BLOCKING_CALL_SECONDS)

    core_v1, apps_v1 = FakeK8sApi(slow), FakeK8sApi(slow)
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (core_v1, apps_v1))

    _, longest_gap = asyncio.run(with_loop_gap(request(gateway, method, path, body)))

    calls = core_v1.calls + apps_v1.calls
    assert calls, "the handler never reached the Kubernetes API, so this test proved nothing"
    assert longest_gap < LOOP_STALL_LIMIT, f"the event loop stalled for {longest_gap:.3f}s"
    assert all(kwargs.get("_request_timeout") for _, kwargs in calls)


def test_loading_the_clients_is_off_the_loop_too(gateway, admin, monkeypatch):
    def slow_load():
        time.sleep(BLOCKING_CALL_SECONDS)
        return FakeK8sApi(), FakeK8sApi()

    monkeypatch.setattr(gateway, "get_k8s_clients", slow_load)

    _, longest_gap = asyncio.run(with_loop_gap(request(gateway, "GET", "/admin/backend/vllm/replicas", None)))

    assert longest_gap < LOOP_STALL_LIMIT, f"the event loop stalled for {longest_gap:.3f}s"


@pytest.mark.parametrize("method,path,body", HANDLERS, ids=HANDLER_IDS)
def test_api_server_that_never_answers_gives_a_504(gateway, admin, monkeypatch, method, path, body):
    # The call has to reach its worker thread within this time to count as a call. At
    # 0.05s it often didn't, with a load average of 50.
    monkeypatch.setattr(gateway.config, "K8S_REQUEST_TIMEOUT_SECONDS", LOOP_STALL_LIMIT)
    release = threading.Event()
    api = FakeK8sApi(lambda: release.wait(5))
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (api, api))

    async def scenario():
        started = time.monotonic()
        try:
            result = await with_loop_gap(request(gateway, method, path, body))
            return (*result, time.monotonic() - started)
        finally:
            release.set()  # asyncio.run waits for the thread when it closes the loop

    response, longest_gap, elapsed = asyncio.run(scenario())

    assert elapsed < LOOP_STALL_LIMIT + 2  # The time limit, plus room for a busy machine
    assert longest_gap < LOOP_STALL_LIMIT, f"the event loop stalled for {longest_gap:.3f}s"
    if path == "/admin/config" and method == "GET":
        assert response.status_code == 200  # Reads Kubernetes only to fill in details
    else:
        assert response.status_code == 504
    # A hung API server gets one call per request, not one wait per remaining step.
    assert len(api.calls) == 1


def test_real_client_against_a_server_that_never_answers(gateway, admin, monkeypatch):
    # On the loop, a single read blocks it for this long.
    monkeypatch.setattr(gateway.config, "K8S_REQUEST_TIMEOUT_SECONDS", BLOCKING_CALL_SECONDS)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        host = f"http://127.0.0.1:{listener.getsockname()[1]}"
        api_client = k8s.ApiClient(k8s.Configuration(host=host))
        monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (k8s.CoreV1Api(api_client), k8s.AppsV1Api(api_client)))

        async def scenario():
            started = time.monotonic()
            result = await with_loop_gap(request(gateway, "GET", "/admin/backend/vllm/replicas", None))
            return (*result, time.monotonic() - started)

        response, longest_gap, elapsed = asyncio.run(scenario())

    assert response.status_code == 504
    assert elapsed < BLOCKING_CALL_SECONDS * 2 + 2  # The time limit, plus room for a busy machine
    assert longest_gap < LOOP_STALL_LIMIT, f"the event loop stalled for {longest_gap:.3f}s"


def test_real_client_against_a_closed_port(gateway, admin, monkeypatch):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    api_client = k8s.ApiClient(k8s.Configuration(host=f"http://127.0.0.1:{port}"))
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (k8s.CoreV1Api(api_client), k8s.AppsV1Api(api_client)))

    response = asyncio.run(request(gateway, "GET", "/admin/backend/vllm/replicas", None))

    assert response.status_code == 504


def test_a_validation_error_is_not_turned_into_a_500(gateway, admin, monkeypatch):
    api = FakeK8sApi()
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (api, api))
    response = asyncio.run(request(gateway, "POST", "/admin/backend/vllm/scale", {"replicas": 999}))

    assert response.status_code == 400


def test_no_kubernetes_call_can_bypass_the_helper():
    """Passing core_v1.x to _k8s_call is the only way to reach the API, so a direct
    call added later fails here, not in production when the API server is slow."""
    tree = ast.parse((pathlib.Path(__file__).parent.parent / "main.py").read_text())

    direct = [
        node.lineno for node in ast.walk(tree)
        if isinstance(node, ast.Call) and (
            (isinstance(node.func, ast.Name) and node.func.id == "get_k8s_clients")
            or (isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id in {"core_v1", "apps_v1"})
        )
    ]

    assert direct == []
