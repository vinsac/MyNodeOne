"""R1, S4 and the metric-label item: streaming, scopes, quotas, usage on /v1/*."""

import asyncio
import json
from types import SimpleNamespace

import httpx
import pytest
from prometheus_client import generate_latest

from conftest import ADMIN_KEY, METRICS_KEY, RAW_KEY, AsgiCall, bearer, total_inflight

CHAT = {"model": "test-model", "messages": [{"role": "user", "content": "say hi"}]}
COMPLETION = {"model": "test-model", "prompt": "say hi"}
EMBEDDING = {"model": "test-embed", "input": "say hi"}
STREAM_ENDPOINTS = [("/v1/chat/completions", CHAT), ("/v1/completions", COMPLETION)]


@pytest.fixture
def key_id(fake_postgres):
    return fake_postgres.add_key(RAW_KEY)


@pytest.mark.parametrize("path,payload,marker", [
    ("/v1/chat/completions", CHAT, b"one"),
    ("/v1/completions", COMPLETION, b"one"),
])
def test_streaming_request_succeeds(client, gateway, fake_postgres, key_id, path, payload, marker):
    response = client.post(path, json={**payload, "stream": True}, headers=bearer(RAW_KEY))

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    assert marker in response.content and b"two" in response.content
    assert total_inflight(gateway) == 0
    assert len(fake_postgres.usage) == 1
    usage_key, input_tokens, output_tokens = fake_postgres.usage[0]
    assert usage_key == key_id
    assert input_tokens > 0
    assert output_tokens == 2


@pytest.mark.parametrize("path,payload", STREAM_ENDPOINTS)
@pytest.mark.parametrize("status", [400, 500, 503])
def test_backend_error_on_a_stream_is_that_status_and_costs_nothing(
    client, gateway, backend, fake_postgres, key_id, path, payload, status,
):
    backend.stream_error = (status, "the backend's own message")

    response = client.post(path, json={**payload, "stream": True}, headers=bearer(RAW_KEY))

    assert response.status_code == status
    assert response.json() == {"detail": "the backend's own message"}
    assert fake_postgres.usage == []
    assert total_inflight(gateway) == 0


@pytest.mark.parametrize("path,payload", STREAM_ENDPOINTS)
def test_unreachable_backend_on_a_stream_is_a_503_and_costs_nothing(
    client, gateway, backend, fake_postgres, key_id, path, payload,
):
    def refuse(request):
        raise httpx.ConnectError("refused")

    gateway.backend_manager.http_client = httpx.AsyncClient(transport=httpx.MockTransport(refuse))

    response = client.post(path, json={**payload, "stream": True}, headers=bearer(RAW_KEY))

    assert response.status_code == 503
    assert response.json() == {"detail": "Backend service unavailable"}
    assert fake_postgres.usage == []
    assert total_inflight(gateway) == 0


def test_stream_error_is_counted_as_an_error_not_a_success(client, gateway, backend, key_id):
    def count(status):
        return gateway.REQUEST_COUNT.labels(
            model="test-model", priority="normal", status=status, endpoint="completions",
        )._value.get()

    errors, successes = count("error"), count("success")
    backend.stream_error = (500, "broken")

    client.post("/v1/completions", json={**COMPLETION, "stream": True}, headers=bearer(RAW_KEY))

    assert (count("error"), count("success")) == (errors + 1, successes)


def test_stream_helper_for_forward_request_raises_too(gateway, backend):
    """BackendManager.stream is what the legacy forward_request path iterates."""
    backend.stream_error = (502, "bad gateway upstream")
    lease = SimpleNamespace(slot=next(iter(gateway.backend_manager.slots.values())))

    async def scenario():
        async for _ in gateway.backend_manager.stream(lease, "/v1/completions", {"stream": True}):
            pass

    with pytest.raises(gateway.BackendStatusError) as raised:
        asyncio.run(scenario())
    assert raised.value.status_code == 502


@pytest.mark.parametrize("spec_version,after_chunks", [
    ("2.3", "hang"),   # task group cancels the generator while it waits on the backend
    ("2.3", "drip"),
    ("2.4", "drip"),   # no listener task: is_disconnected() in the relay loop has to see it
])
def test_client_disconnect_releases_leases_and_charges_usage(
    gateway, backend, fake_postgres, key_id, spec_version, after_chunks
):
    backend.after_chunks = after_chunks
    body = json.dumps({**CHAT, "stream": True}).encode()

    call = AsgiCall(
        gateway.app, "POST", "/v1/chat/completions",
        token=RAW_KEY, chunks=[body], spec_version=spec_version, disconnect_after_chunks=2,
    )
    asyncio.run(call.run())

    assert call.status == 200
    assert total_inflight(gateway) == 0
    assert backend.stream_closed, "the backend request must be closed so the GPU stops generating"
    assert [entry[0] for entry in fake_postgres.usage] == [key_id]
    assert fake_postgres.usage[0][2] >= 1
    assert any(key.startswith(f"ratelimit:{key_id}:vllm:tpm") for key in gateway.redis_client.client.data)


def test_scope_check_on_completions(client, backend, fake_postgres):
    fake_postgres.add_key(METRICS_KEY, scopes=["metrics"])

    response = client.post("/v1/completions", json=COMPLETION, headers=bearer(METRICS_KEY))

    assert response.status_code == 403
    assert backend.requests == []


def test_completions_allowed_with_inference_scope(client, backend, key_id):
    response = client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY))

    assert response.status_code == 200
    assert [path for path, _ in backend.requests] == ["/v1/completions"]


def test_scope_is_checked_before_the_body_is_validated(client, fake_postgres):
    fake_postgres.add_key(METRICS_KEY, scopes=["metrics"])

    response = client.post("/v1/completions", content=b"{not json", headers=bearer(METRICS_KEY))

    assert response.status_code == 403


@pytest.mark.parametrize("path,payload", [
    ("/v1/chat/completions", CHAT),
    ("/v1/completions", COMPLETION),
    ("/v1/embeddings", EMBEDDING),
])
def test_quota_exceeded_is_rejected_before_the_backend(
    client, gateway, backend, fake_postgres, key_id, path, payload
):
    fake_postgres.quota_ok = False

    response = client.post(path, json=payload, headers=bearer(RAW_KEY))

    assert response.status_code == 429
    assert backend.requests == []
    assert total_inflight(gateway) == 0


def test_non_streaming_completion_records_usage(client, fake_postgres, key_id):
    response = client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY))

    assert response.status_code == 200
    assert fake_postgres.usage == [(key_id, 5, 7)]


def test_unknown_model_gets_404_and_never_reaches_a_metric_label(client, backend, key_id):
    bogus = "bogus-model-label-cardinality-attack"
    for path, payload in (("/v1/completions", COMPLETION), ("/v1/chat/completions", CHAT)):
        response = client.post(path, json={**payload, "model": bogus}, headers=bearer(RAW_KEY))
        assert response.status_code == 404

    assert backend.requests == []
    assert bogus.encode() not in generate_latest()


def test_raw_keys_absent_from_health_backends(gateway, backend, fake_postgres, key_id):
    fake_postgres.add_key(ADMIN_KEY, scopes=["metrics"])
    backend.after_chunks = "hang"

    async def scenario():
        stream = AsgiCall(
            gateway.app, "POST", "/v1/chat/completions",
            token=RAW_KEY, chunks=[json.dumps({**CHAT, "stream": True}).encode()],
        )
        running = asyncio.create_task(stream.run())
        while not gateway.rate_limiter.pools or total_inflight(gateway) < 2:
            await asyncio.sleep(0.005)

        health = await AsgiCall(gateway.app, "GET", "/health/backends", token=ADMIN_KEY).run()

        stream.disconnect()
        await running
        return health

    health = asyncio.run(scenario())

    assert health.status == 200
    text = health.body.decode()
    assert RAW_KEY not in text
    assert ADMIN_KEY not in text
    assert "sk-mynodeone" not in text
    assert key_id not in text, "only a shortened id is shown to metrics-scope callers"
    inflight = json.loads(text)["rate_limiter"]["per_key_inflight"]
    assert inflight == {key_id[:len("sha256:") + 16]: {"vllm": 1}}
