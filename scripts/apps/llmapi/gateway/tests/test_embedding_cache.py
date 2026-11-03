"""R17: cached embeddings must belong to the model now serving, and to this request's positions."""

import asyncio
import json

import httpx
import pytest

from conftest import RAW_KEY, bearer


@pytest.fixture
def key(fake_postgres):
    return fake_postgres.add_key(RAW_KEY)


def serve(gateway, backend_model_id="model-a"):
    gateway.model_registry.register_model("test-embed", "embedding", "ready", {"backend_model_id": backend_model_id})


def embed(client, inputs):
    response = client.post("/v1/embeddings", json={"model": "test-embed", "input": inputs}, headers=bearer(RAW_KEY))
    assert response.status_code == 200, response.text
    return response.json()["data"]


@pytest.fixture
def vectors(backend):
    """Each text gets its own vector, so a wrong pairing shows up."""
    backend.embed = lambda text: [float(ord(text[0]))]
    return backend


def forwarded_inputs(backend):
    return [body["input"] for path, body in backend.requests if path == "/v1/embeddings"]


def test_same_model_is_served_from_the_cache(client, gateway, vectors, key):
    serve(gateway)

    first = embed(client, ["alpha"])
    second = embed(client, ["alpha"])

    assert second == first
    assert forwarded_inputs(vectors) == [["alpha"]]


def test_a_model_swap_invalidates_the_cache(client, gateway, vectors, key):
    serve(gateway, "model-a")
    assert embed(client, ["alpha"])[0]["embedding"] == [97.0]

    # Same gateway-side name, different model behind it, with different vectors.
    serve(gateway, "model-b")
    vectors.embed = lambda text: [-1.0]

    assert embed(client, ["alpha"])[0]["embedding"] == [-1.0]
    assert forwarded_inputs(vectors) == [["alpha"], ["alpha"]]

    # Swapping back finds that model's own vectors, as they're still right for it.
    serve(gateway, "model-a")
    assert embed(client, ["alpha"])[0]["embedding"] == [97.0]


def test_unknown_backend_model_bypasses_the_cache(client, gateway, vectors, key, fake_redis):
    serve(gateway, None)

    embed(client, ["alpha"])
    embed(client, ["alpha"])

    assert forwarded_inputs(vectors) == [["alpha"], ["alpha"]]
    assert not [key for key in fake_redis.data if key.startswith("cache:")]


def test_cached_items_take_this_requests_positions(client, gateway, vectors, key):
    serve(gateway)
    embed(client, ["alpha"])
    embed(client, ["beta"])

    data = embed(client, ["beta", "alpha", "beta"])

    assert [item["index"] for item in data] == [0, 1, 2]
    assert [item["embedding"] for item in data] == [[98.0], [97.0], [98.0]]
    assert len(forwarded_inputs(vectors)) == 2


def test_mix_of_hits_and_misses_keeps_input_order(client, gateway, vectors, key):
    serve(gateway)
    embed(client, ["beta", "delta"])

    data = embed(client, ["alpha", "beta", "gamma", "delta"])

    assert forwarded_inputs(vectors)[-1] == ["alpha", "gamma"]
    assert [item["index"] for item in data] == [0, 1, 2, 3]
    assert [item["embedding"] for item in data] == [[97.0], [98.0], [103.0], [100.0]]


def test_backend_returning_the_wrong_count_is_an_error_and_is_not_cached(client, gateway, backend, key, fake_redis):
    serve(gateway)
    real_handle = backend.handle

    def one_short(request):
        response = real_handle(request)
        body = json.loads(response.content)
        body["data"] = body["data"][:-1]
        return httpx.Response(200, json=body)

    gateway.backend_manager.http_client = httpx.AsyncClient(transport=httpx.MockTransport(one_short))

    response = client.post("/v1/embeddings", json={"model": "test-embed", "input": ["a", "b"]}, headers=bearer(RAW_KEY))

    assert response.status_code == 502
    assert not [key for key in fake_redis.data if key.startswith("cache:")]


LLAMA_MODELS = {
    "object": "list",
    "data": [{"id": "/models/nomic.gguf", "object": "model", "meta": {"n_embd": 768, "size": 123}}],
}


def discover(gateway, models_response):
    """Run discovery with an embedding backend answering health and /v1/models."""
    def handle(request):
        if request.url.host == "embedding.test" and request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok"})
        if request.url.host == "embedding.test" and request.url.path == "/v1/models":
            return models_response()
        return httpx.Response(404)

    gateway.backend_manager.http_client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
    asyncio.run(gateway.backend_manager.discover_models())
    return gateway.model_registry.get_model("embedding")


@pytest.fixture
def embedding_backend(gateway, monkeypatch):
    monkeypatch.setattr(gateway.config, "EMBEDDING_URL", "http://embedding.test")
    monkeypatch.delenv("EMBEDDING_MODEL_FILE", raising=False)
    monkeypatch.setenv("EMBEDDING_MODEL_NAME", "embedding")


def test_discovery_records_what_the_backend_is_serving(gateway, embedding_backend):
    model = discover(gateway, lambda: httpx.Response(200, json=LLAMA_MODELS))

    identity = json.loads(model["info"]["backend_model_id"])
    assert identity["id"] == "/models/nomic.gguf"
    assert identity["meta"]["n_embd"] == 768


def test_discovery_sees_a_new_model_with_the_same_file_name(gateway, embedding_backend):
    before = discover(gateway, lambda: httpx.Response(200, json=LLAMA_MODELS))["info"]["backend_model_id"]

    swapped = {"data": [{"id": "/models/nomic.gguf", "meta": {"n_embd": 1024, "size": 456}}]}
    after = discover(gateway, lambda: httpx.Response(200, json=swapped))["info"]["backend_model_id"]

    assert before != after


@pytest.mark.parametrize("response", [
    lambda: httpx.Response(500),
    lambda: httpx.Response(200, json={"data": []}),
    lambda: httpx.Response(200, text="not json"),
], ids=["error", "empty", "not-json"])
def test_discovery_without_an_answer_leaves_the_identity_unknown(gateway, embedding_backend, response):
    model = discover(gateway, response)

    assert model["info"]["backend_model_id"] is None


## An admin changes the model

def admin_changes_model(gateway):
    gateway.backend_manager.note_embedding_model_change()


def discovery_reads(gateway, read_id):
    """What the discovery loop does with the id it just read from the backend."""
    settled = gateway.backend_manager._settled_embedding_model_id(read_id)
    gateway.model_registry.register_model("test-embed", "embedding", "ready", {"backend_model_id": settled})


def cache_entries(fake_redis):
    return sorted(key for key in fake_redis.data if key.startswith("cache:"))


def test_the_cache_is_off_from_the_moment_of_the_change(client, gateway, vectors, key, fake_redis):
    serve(gateway, "model-a")
    embed(client, ["alpha"])
    entries = cache_entries(fake_redis)

    admin_changes_model(gateway)
    vectors.embed = lambda text: [-1.0]

    # The new model already answers, and discovery hasn't run yet. Before the fix this
    # returned the old vector, and stored the new one under the old model's id.
    assert embed(client, ["alpha"])[0]["embedding"] == [-1.0]
    assert embed(client, ["beta"])[0]["embedding"] == [-1.0]
    assert cache_entries(fake_redis) == entries


def test_discovery_reading_the_old_model_does_not_end_the_hold(client, gateway, vectors, key, fake_redis):
    serve(gateway, "model-a")
    admin_changes_model(gateway)

    discovery_reads(gateway, "model-a")
    embed(client, ["alpha"])

    assert cache_entries(fake_redis) == []


def test_one_read_of_a_new_id_is_not_enough_two_are(client, gateway, vectors, key, fake_redis):
    serve(gateway, "model-a")
    admin_changes_model(gateway)

    discovery_reads(gateway, "model-b")
    embed(client, ["alpha"])
    assert cache_entries(fake_redis) == [], "both pods can be behind the Service at this point"

    discovery_reads(gateway, "model-b")
    embed(client, ["alpha"])
    embed(client, ["alpha"])
    assert len(cache_entries(fake_redis)) == 1
    assert len(forwarded_inputs(vectors)) == 2


def test_flapping_ids_during_the_rollout_start_the_count_again(gateway):
    serve(gateway, "model-a")
    admin_changes_model(gateway)
    settled = gateway.backend_manager._settled_embedding_model_id

    assert settled("model-b") is None
    assert settled("model-a") is None
    assert settled("model-b") is None
    assert settled("model-b") == "model-b"
    assert settled("model-c") == "model-c", "the hold is over, so discovery is back to normal"


def test_choosing_the_model_already_running_ends_at_the_time_limit(gateway, monkeypatch):
    serve(gateway, "model-a")
    admin_changes_model(gateway)
    settled = gateway.backend_manager._settled_embedding_model_id
    assert settled("model-a") is None

    monkeypatch.setattr(gateway, "EMBEDDING_MODEL_CHANGE_HOLD_SECONDS", 0)
    admin_changes_model(gateway)

    assert settled("model-a") == "model-a"


def test_a_model_change_during_a_backend_call_is_not_cached_under_the_old_id(gateway, vectors, key, fake_redis):
    serve(gateway, "model-a")
    real_handle = vectors.handle

    def change_while_answering(request):
        admin_changes_model(gateway)
        return real_handle(request)

    gateway.backend_manager.http_client = httpx.AsyncClient(transport=httpx.MockTransport(change_while_answering))

    async def call():
        transport = httpx.ASGITransport(gateway.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as http:
            return await http.post(
                "/v1/embeddings", json={"model": "test-embed", "input": ["alpha"]}, headers=bearer(RAW_KEY),
            )

    assert asyncio.run(call()).status_code == 200
    assert cache_entries(fake_redis) == []


def test_the_admin_handler_starts_the_hold_before_the_pod_restarts(client, gateway, fake_postgres, monkeypatch):
    """The real handler, with the Kubernetes API faked at its edge."""
    fake_postgres.add_key(RAW_KEY, scopes=["admin"])
    serve(gateway, "model-a")
    seen_at_restart = []

    class Object:
        def __init__(self, **attrs):
            self.__dict__.update(attrs)

    config_map = Object(data={})
    deployment = Object(spec=Object(template=Object(metadata=Object(annotations=None))))

    async def k8s_clients():
        return (
            Object(read_namespaced_config_map="read-cm", patch_namespaced_config_map="patch-cm"),
            Object(read_namespaced_deployment="read-deploy", patch_namespaced_deployment="patch-deploy"),
        )

    async def k8s_call(function, *args):
        if function == "patch-deploy":
            seen_at_restart.append(gateway.model_registry.get_model("test-embed")["info"]["backend_model_id"])
        return {"read-cm": config_map, "read-deploy": deployment}.get(function)

    monkeypatch.setattr(gateway, "_k8s_clients", k8s_clients)
    monkeypatch.setattr(gateway, "_k8s_call", k8s_call)

    response = client.post(
        "/admin/backend/embedding",
        json={"model_url": "https://huggingface.co/org/repo/resolve/main/model.gguf"},
        headers=bearer(RAW_KEY),
    )

    assert response.status_code == 200, response.text
    assert seen_at_restart == [None]
