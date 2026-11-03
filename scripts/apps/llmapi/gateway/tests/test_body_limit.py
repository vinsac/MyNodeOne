"""S12: authenticate before parsing, and a body limit streaming can't bypass."""

import asyncio
import json

import pytest

from conftest import ADMIN_KEY, RAW_KEY, AsgiCall, bearer

LIMIT = 1024
INFERENCE_PATHS = ["/v1/chat/completions", "/v1/completions", "/v1/embeddings"]


@pytest.fixture(autouse=True)
def small_limit(gateway, monkeypatch):
    monkeypatch.setattr(gateway.config, "MAX_REQUEST_BODY_BYTES", LIMIT)


def test_unauthenticated_oversized_body_rejected(client):
    response = client.post("/v1/chat/completions", content=b"x" * (LIMIT + 1))

    assert response.status_code == 413
    assert str(LIMIT) in response.json()["detail"]


def test_declared_oversized_body_is_refused_without_reading_it(gateway):
    call = AsgiCall(
        gateway.app, "POST", "/v1/chat/completions",
        chunks=[b"x" * (LIMIT + 1)], headers=[(b"content-length", str(LIMIT + 1).encode())],
    )
    asyncio.run(call.run())

    assert call.status == 413
    assert call.body_messages_read == 0


def test_body_at_the_limit_is_accepted(client, fake_postgres):
    fake_postgres.add_key(RAW_KEY)
    padding = " " * (LIMIT - len(b'{"model":"test-model","prompt":"hi"}'))
    body = ('{"model":"test-model","prompt":"hi"}' + padding).encode()
    assert len(body) == LIMIT

    response = client.post("/v1/completions", content=body, headers=bearer(RAW_KEY))

    assert response.status_code == 200


def test_invalid_content_length_rejected(gateway):
    call = AsgiCall(gateway.app, "POST", "/v1/completions", headers=[(b"content-length", b"abc")])
    asyncio.run(call.run())

    assert call.status == 400


@pytest.mark.parametrize("path", INFERENCE_PATHS)
def test_unauthenticated_body_is_never_read(gateway, path):
    """Auth runs first: a caller without a key can't make the gateway buffer or parse."""
    call = AsgiCall(gateway.app, "POST", path, chunks=[b"{not json"])
    asyncio.run(call.run())

    assert call.status in (401, 403)
    assert call.body_messages_read == 0


@pytest.mark.parametrize("path", INFERENCE_PATHS)
def test_invalid_key_with_malformed_body_gets_401(client, path):
    response = client.post(path, content=b"{not json", headers=bearer("sk-mynodeone-wrong"))

    assert response.status_code == 401


@pytest.mark.parametrize("path", INFERENCE_PATHS)
def test_chunked_oversized_body_rejected(gateway, backend, fake_postgres, path):
    """No Content-Length, so only counting while reading can catch this."""
    fake_postgres.add_key(RAW_KEY)
    call = AsgiCall(gateway.app, "POST", path, token=RAW_KEY, chunks=[b"x" * 400] * 4)
    asyncio.run(call.run())

    assert call.status == 413
    assert call.body_messages_read == 3, "reading stops at the chunk that crosses the limit"
    assert backend.requests == []


def test_body_with_understated_content_length_rejected(gateway, fake_postgres):
    fake_postgres.add_key(RAW_KEY)
    call = AsgiCall(
        gateway.app, "POST", "/v1/completions", token=RAW_KEY,
        chunks=[b"x" * 800, b"x" * 800], headers=[(b"content-length", b"10")],
    )
    asyncio.run(call.run())

    assert call.status == 413


def test_oversized_rate_limiter_reset_does_not_reset_everything(gateway, fake_postgres, monkeypatch):
    """The handler treats an unreadable body as empty, and empty means reset all."""
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])
    resets = []

    async def record_reset(*args):
        resets.append(args)
        return {}

    monkeypatch.setattr(gateway.rate_limiter, "reset", record_reset)
    monkeypatch.setattr(gateway.backend_manager, "reset", record_reset)

    call = AsgiCall(gateway.app, "POST", "/admin/rate-limiter/reset", token=ADMIN_KEY, chunks=[b"x" * 800] * 2)
    asyncio.run(call.run())

    assert call.status == 413
    assert resets == []


def test_rate_limiter_reset_accepts_raw_key_or_id(gateway, client, fake_postgres, monkeypatch):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])
    target_id = fake_postgres.add_key(RAW_KEY)
    targets = []

    async def record_reset(api_key, bucket):
        targets.append(api_key)
        return {}

    monkeypatch.setattr(gateway.rate_limiter, "reset", record_reset)
    for reference in (RAW_KEY, target_id):
        response = client.post("/admin/rate-limiter/reset", json={"api_key": reference}, headers=bearer(ADMIN_KEY))
        assert response.status_code == 200

    assert targets == [target_id, target_id]


def test_malformed_json_from_valid_key_keeps_fastapi_error_shape(client, fake_postgres):
    fake_postgres.add_key(RAW_KEY)

    response = client.post("/v1/completions", content=b"{not json", headers=bearer(RAW_KEY))

    assert response.status_code == 422
    assert response.json()["detail"][0]["loc"] == ["body"]


def test_invalid_field_from_valid_key_keeps_fastapi_error_shape(client, fake_postgres):
    fake_postgres.add_key(RAW_KEY)

    response = client.post("/v1/completions", json={"model": "test-model"}, headers=bearer(RAW_KEY))

    assert response.status_code == 422
    detail = response.json()["detail"][0]
    assert detail["loc"] == ["body", "prompt"]
    assert detail["type"] == "missing"


def test_json_nested_too_deeply_is_a_validation_error(client, gateway, fake_postgres, monkeypatch):
    fake_postgres.add_key(RAW_KEY)
    monkeypatch.setattr(gateway.config, "MAX_REQUEST_BODY_BYTES", 10 * 1024 * 1024)
    depth = 1024 * 1024

    response = client.post("/v1/completions", content=b"[" * depth + b"]" * depth, headers=bearer(RAW_KEY))

    assert response.status_code == 422


def test_openapi_schema_still_documents_request_bodies(client):
    schema = client.get("/openapi.json").json()

    for path, field in (
        ("/v1/chat/completions", "messages"),
        ("/v1/completions", "prompt"),
        ("/v1/embeddings", "input"),
    ):
        body = schema["paths"][path]["post"]["requestBody"]["content"]["application/json"]["schema"]
        assert field in body["properties"]
    assert "$defs" not in json.dumps(schema["paths"]["/v1/chat/completions"]["post"]["requestBody"])


def test_swagger_and_redoc_are_disabled(client):
    assert client.get("/docs").status_code == 404
    assert client.get("/redoc").status_code == 404
