"""R20: saving the HuggingFace token gives a clear answer and leaves no plaintext behind."""

import base64
import http.server
import json
import pathlib
import threading

import pytest
from kubernetes import client as k8s
from kubernetes.client.exceptions import ApiException
from kubernetes.config import ConfigException

from conftest import ADMIN_KEY, bearer

TOKEN = "hf_secretvalue123"


class FakeCore:
    def __init__(self, error=None):
        self.error = error
        self.patches = []

    def patch_namespaced_secret(self, name, namespace, body, **kwargs):
        self.patches.append((name, namespace, body, kwargs))
        if self.error:
            raise self.error
        return {"metadata": {"name": name}}


@pytest.fixture
def admin(fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])


def save(client, token=TOKEN):
    return client.post("/admin/config", json={"hf_token": token}, headers=bearer(ADMIN_KEY))


def use(gateway, monkeypatch, core):
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (core, None))


def assert_no_token_anywhere(fake_redis, response):
    assert TOKEN not in json.dumps(fake_redis.data)
    assert TOKEN not in response.text
    assert "config:hf_token" not in fake_redis.data


def test_success_writes_only_the_secret(client, gateway, admin, fake_redis, monkeypatch):
    core = FakeCore()
    use(gateway, monkeypatch, core)

    response = save(client)

    assert response.status_code == 200
    assert response.json()["status"] == "saved"
    name, namespace, body, kwargs = core.patches[0]
    assert (name, namespace) == ("hf-token", "llmapi")
    assert base64.b64decode(body["data"]["token"]).decode() == TOKEN
    assert kwargs["_request_timeout"]
    assert_no_token_anywhere(fake_redis, response)


@pytest.mark.parametrize("status,expected,phrase", [
    (403, 503, "no permission"),
    (404, 409, "does not exist"),
    (500, 502, "status 500"),
])
def test_api_error_says_the_token_was_not_saved(client, gateway, admin, fake_redis, monkeypatch, status, expected, phrase):
    use(gateway, monkeypatch, FakeCore(ApiException(status=status, reason="x")))

    response = save(client)

    assert response.status_code == expected
    assert "NOT saved" in response.json()["detail"]
    assert phrase in response.json()["detail"]
    assert_no_token_anywhere(fake_redis, response)
    assert "config:hf_token_saved" not in fake_redis.data


def test_timeout_says_it_may_not_be_saved(client, gateway, admin, fake_redis, monkeypatch):
    monkeypatch.setattr(gateway.config, "K8S_REQUEST_TIMEOUT_SECONDS", 0.05)
    release = threading.Event()

    class Hanging(FakeCore):
        def patch_namespaced_secret(self, *args, **kwargs):
            release.wait(5)

    use(gateway, monkeypatch, Hanging())
    try:
        response = save(client)
    finally:
        release.set()

    assert response.status_code == 504
    assert "may not be saved" in response.json()["detail"]
    assert_no_token_anywhere(fake_redis, response)


def test_kubernetes_not_configured_says_the_token_was_not_saved(client, gateway, admin, fake_redis, monkeypatch):
    def not_configured():
        raise ConfigException("no config at " + TOKEN)

    monkeypatch.setattr(gateway, "get_k8s_clients", not_configured)

    response = save(client)

    assert response.status_code == 502
    assert "NOT saved" in response.json()["detail"]
    assert_no_token_anywhere(fake_redis, response)


@pytest.mark.parametrize("bad", ["", "   ", 123, None, ["x"]])
def test_bad_token_is_a_400_and_reaches_nothing(client, gateway, admin, monkeypatch, bad):
    core = FakeCore()
    use(gateway, monkeypatch, core)

    assert save(client, bad).status_code == 400
    assert core.patches == []


def test_requires_admin_scope(client, gateway, fake_postgres, monkeypatch):
    fake_postgres.add_key(ADMIN_KEY, scopes=["inference"])
    core = FakeCore()
    use(gateway, monkeypatch, core)

    assert save(client).status_code == 403
    assert core.patches == []


def test_config_reports_a_saved_token_and_an_older_plaintext_one(client, gateway, admin, fake_redis, monkeypatch):
    core = FakeCore()
    use(gateway, monkeypatch, core)

    def configured():
        return client.get("/admin/config", headers=bearer(ADMIN_KEY)).json()["hf_token_configured"]

    assert configured() is False
    fake_redis.data["config:hf_token"] = "older"
    assert configured() is True

    save(client)

    assert "config:hf_token" not in fake_redis.data
    assert configured() is True


class ApiServer(http.server.BaseHTTPRequestHandler):
    status = 200
    seen = []

    def do_PATCH(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        type(self).seen.append((self.path, self.headers["Content-Type"], json.loads(body)))
        reply = json.dumps({"kind": "Secret", "apiVersion": "v1", "metadata": {"name": "hf-token"}}).encode()
        self.send_response(self.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


@pytest.fixture
def api_server(gateway, monkeypatch):
    """The real Kubernetes client talking HTTP to a local stand-in for the API server."""
    ApiServer.seen = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ApiServer)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    api_client = k8s.ApiClient(k8s.Configuration(host=f"http://127.0.0.1:{server.server_address[1]}"))
    monkeypatch.setattr(gateway, "get_k8s_clients", lambda: (k8s.CoreV1Api(api_client), k8s.AppsV1Api(api_client)))
    yield ApiServer
    server.shutdown()
    server.server_close()
    ApiServer.status = 200


def test_real_client_sends_one_patch_of_only_the_token(client, admin, api_server):
    """Only PATCH, which is why the Role needs nothing beyond the patch verb."""
    response = save(client)

    assert response.status_code == 200
    (path, content_type, body), = api_server.seen
    assert path == "/api/v1/namespaces/llmapi/secrets/hf-token"
    assert "patch" in content_type
    assert body == {"data": {"token": base64.b64encode(TOKEN.encode()).decode()}}


def test_real_client_forbidden_is_the_clear_error(client, admin, api_server, fake_redis):
    api_server.status = 403

    response = save(client)

    assert response.status_code == 503
    assert "NOT saved" in response.json()["detail"]
    assert_no_token_anywhere(fake_redis, response)


def test_ui_shows_the_server_explanation():
    source = (pathlib.Path(__file__).parent.parent / "main.py").read_text()
    start = source.index("async function setHfToken()")
    assert "error.detail" in source[start:start + 1200]
