"""S19, S5, S6 and S1 against the gateway: hashed keys, revocation, no raw keys
in responses, and the Redis password. Real SQL is in test_postgres_migration.py."""

import asyncio
import json
import logging

import pytest

from conftest import ADMIN_KEY, METRICS_KEY, RAW_KEY, bearer

COMPLETION = {"model": "test-model", "prompt": "say hi"}


def cached_config(**overrides):
    return json.dumps({"name": "cached", "scopes": ["inference"], "requests_per_minute": 1000,
                       "tokens_per_day": 1000000, "tokens_per_minute": 1000000, **overrides})


# --- authentication ---------------------------------------------------------


def test_key_is_looked_up_by_id_and_cached_by_id(client, gateway, fake_redis, fake_postgres):
    key_id = fake_postgres.add_key(RAW_KEY)

    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 200

    assert f"apikey:{key_id}" in fake_redis.data
    assert not any(RAW_KEY in key for key in fake_redis.data), "raw key must not appear in any Redis key"


def test_rate_limit_keys_and_usage_use_the_id(client, fake_redis, fake_postgres):
    key_id = fake_postgres.add_key(RAW_KEY)

    client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY))

    assert any(key.startswith(f"ratelimit:{key_id}:") for key in fake_redis.data)
    assert fake_postgres.usage[0][0] == key_id


def test_stored_key_id_is_not_a_credential(client, fake_redis, fake_postgres):
    key_id = fake_postgres.add_key(RAW_KEY)
    fake_redis.data[f"apikey:{key_id}"] = cached_config()

    response = client.post("/v1/completions", json=COMPLETION, headers=bearer(key_id))

    assert response.status_code == 401


def test_unknown_key_rejected(client):
    response = client.post("/v1/completions", json=COMPLETION, headers=bearer("sk-mynodeone-nope"))

    assert response.status_code == 401


def test_auth_works_from_cache_when_postgres_has_no_row(client, gateway, fake_redis):
    """The cached copy is what keeps auth up through a Postgres restart."""
    key_id = gateway.hash_api_key(RAW_KEY)
    fake_redis.data[f"apikey:{key_id}"] = cached_config()

    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 200


# --- Redis entries left by the previous version -------------------------------


def test_legacy_redis_entry_keeps_working_after_startup_copy(client, gateway, fake_redis):
    fake_redis.data[f"apikey:{RAW_KEY}"] = cached_config()

    asyncio.run(gateway.redis_client.migrate_legacy_keys(delete_plaintext=False))

    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 200
    assert f"apikey:{RAW_KEY}" in fake_redis.data, "an old pod in a rolling update still reads this"


def test_legacy_redis_copy_does_not_overwrite_the_id_entry(gateway, fake_redis):
    key_id = gateway.hash_api_key(RAW_KEY)
    fake_redis.data[f"apikey:{RAW_KEY}"] = cached_config(name="stale")
    fake_redis.data[f"apikey:{key_id}"] = cached_config(name="current")

    asyncio.run(gateway.redis_client.migrate_legacy_keys(delete_plaintext=False))

    assert json.loads(fake_redis.data[f"apikey:{key_id}"])["name"] == "current"


def test_sync_deletes_plaintext_redis_entries(gateway, fake_redis):
    key_id = gateway.hash_api_key(RAW_KEY)
    fake_redis.data[f"apikey:{RAW_KEY}"] = cached_config()
    fake_redis.data[f"ratelimit:{RAW_KEY}:vllm:rpm"] = "3"
    fake_redis.data[f"ratelimit:{key_id}:vllm:rpm"] = "4"

    for _ in range(2):  # safe to repeat
        asyncio.run(gateway.redis_client.migrate_legacy_keys(delete_plaintext=True))

    assert not any(RAW_KEY in key for key in fake_redis.data)
    assert fake_redis.data[f"apikey:{key_id}"]
    assert fake_redis.data[f"ratelimit:{key_id}:vllm:rpm"] == "4"


# --- admin API ----------------------------------------------------------------


@pytest.fixture
def admin(fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin", "inference"], name="admin")
    return bearer(ADMIN_KEY)


def test_admin_create_shows_raw_key_once_and_stores_only_the_id(client, gateway, admin, fake_postgres, fake_redis):
    created = client.post("/admin/keys", json={"name": "app", "scopes": ["inference"]}, headers=admin).json()

    raw_key = created["key"]
    assert raw_key.startswith("sk-mynodeone-")
    assert created["key_id"] == gateway.hash_api_key(raw_key)
    assert created["config"]["key_prefix"] == raw_key[:20]
    assert raw_key not in json.dumps(created["config"])
    assert raw_key not in json.dumps(fake_postgres.keys)
    assert not any(raw_key in key or raw_key in value for key, value in fake_redis.data.items())

    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(raw_key)).status_code == 200


def test_admin_key_list_has_no_raw_keys(client, admin, fake_postgres):
    key_id = fake_postgres.add_key(RAW_KEY)

    response = client.get("/admin/keys", headers=admin)

    assert response.status_code == 200
    assert RAW_KEY not in response.text
    assert ADMIN_KEY not in response.text
    listed = {entry["key_id"]: entry for entry in response.json()["keys"]}
    assert listed[key_id]["key_prefix"] == RAW_KEY[:20]


@pytest.mark.parametrize("reference", ["id", "raw"])
def test_revoke_takes_effect_immediately_through_the_cache(client, gateway, admin, fake_postgres, fake_redis, reference):
    key_id = fake_postgres.add_key(RAW_KEY)
    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 200
    assert f"apikey:{key_id}" in fake_redis.data

    target = key_id if reference == "id" else RAW_KEY
    response = client.delete(f"/admin/keys/{target}", headers=admin)

    assert response.status_code == 200
    assert response.json() == {"status": "revoked", "key_id": key_id}
    assert RAW_KEY not in response.text
    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 401


def test_admin_usage_has_no_raw_key(client, admin, fake_postgres):
    key_id = fake_postgres.add_key(RAW_KEY)

    response = client.get(f"/admin/usage/{key_id}", headers=admin)

    assert response.status_code == 200
    assert RAW_KEY not in response.text
    assert response.json()["api_key"] == RAW_KEY[:20] + "..."
    assert response.json()["key_id"] == key_id


# --- warm loop ----------------------------------------------------------------


def test_warm_loop_caches_active_and_removes_revoked_keys(gateway, fake_postgres, fake_redis):
    active = fake_postgres.add_key(RAW_KEY)
    revoked = fake_postgres.add_key(METRICS_KEY)
    fake_postgres.revoked.add(revoked)
    fake_redis.data[f"apikey:{revoked}"] = cached_config()

    asyncio.run(gateway.warm_redis_from_postgres())

    assert f"apikey:{active}" in fake_redis.data
    assert f"apikey:{revoked}" not in fake_redis.data


def test_warm_loop_removes_a_key_revoked_by_the_cli_so_it_stops_authenticating(
    client, gateway, fake_postgres, fake_redis
):
    """Revoking only in Postgres (old CLI, or Redis unreachable) left the key working forever."""
    key_id = fake_postgres.add_key(RAW_KEY)
    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 200
    fake_postgres.revoked.add(key_id)
    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 200

    asyncio.run(gateway.warm_redis_from_postgres())

    assert client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY)).status_code == 401


def test_warm_loop_removes_orphaned_cache_entries(gateway, fake_postgres, fake_redis):
    fake_postgres.add_key(RAW_KEY)
    orphan = gateway.hash_api_key("sk-mynodeone-deleted-from-postgres")
    fake_redis.data[f"apikey:{orphan}"] = cached_config()

    asyncio.run(gateway.warm_redis_from_postgres())

    assert f"apikey:{orphan}" not in fake_redis.data


def test_warm_loop_evicts_nothing_when_postgres_is_down(gateway, fake_postgres, fake_redis):
    key_id = gateway.hash_api_key(RAW_KEY)
    fake_redis.data[f"apikey:{key_id}"] = cached_config()
    fake_postgres.available = False

    asyncio.run(gateway.warm_redis_from_postgres())

    assert f"apikey:{key_id}" in fake_redis.data


def test_warm_loop_evicts_nothing_unknown_when_key_table_is_empty(gateway, fake_postgres, fake_redis):
    """A freshly restored or replaced database must not lock everyone out."""
    key_id = gateway.hash_api_key(RAW_KEY)
    fake_redis.data[f"apikey:{key_id}"] = cached_config()

    asyncio.run(gateway.warm_redis_from_postgres())

    assert f"apikey:{key_id}" in fake_redis.data


def test_eviction_leaves_keys_when_redis_is_unavailable(gateway, fake_postgres, fake_redis, monkeypatch):
    async def unavailable():
        return None

    monkeypatch.setattr(gateway.redis_client, "list_cached_key_ids", unavailable)
    asyncio.run(gateway._evict_stale_cached_keys())  # must not raise


# --- Redis password -----------------------------------------------------------


class _Captured:
    def __init__(self, calls):
        self.calls = calls

    def __call__(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return object()


@pytest.fixture
def from_url_calls(gateway, monkeypatch):
    calls = []
    monkeypatch.setattr(gateway.redis, "from_url", _Captured(calls))
    return calls


def test_redis_password_is_passed_separately_from_the_url(gateway, monkeypatch, from_url_calls):
    monkeypatch.setattr(gateway.config, "REDIS_URL", "redis://redis:6379/0")
    monkeypatch.setattr(gateway.config, "REDIS_PASSWORD", "s3cret-password")

    asyncio.run(gateway.RedisClient().connect())

    url, kwargs = from_url_calls[0]
    assert url == "redis://redis:6379/0"
    assert kwargs["password"] == "s3cret-password"
    assert kwargs["decode_responses"] is True


def test_redis_without_a_password_still_connects(gateway, monkeypatch, from_url_calls):
    monkeypatch.setattr(gateway.config, "REDIS_PASSWORD", "")

    asyncio.run(gateway.RedisClient().connect())

    assert "password" not in from_url_calls[0][1]


def test_reconnect_uses_the_password_too(gateway, monkeypatch, from_url_calls):
    monkeypatch.setattr(gateway.config, "REDIS_PASSWORD", "s3cret-password")
    client = gateway.RedisClient()

    assert client._new_client() is not None

    assert from_url_calls[0][1]["password"] == "s3cret-password"


def test_redis_connect_log_never_contains_credentials(gateway, monkeypatch, from_url_calls, caplog):
    monkeypatch.setattr(gateway.config, "REDIS_PASSWORD", "s3cret-password")
    monkeypatch.setattr(gateway.config, "REDIS_URL", "redis://user:url-password@redis:6379/0")

    with caplog.at_level(logging.DEBUG):
        asyncio.run(gateway.RedisClient().connect())

    assert "redis:6379/0" in caplog.text
    assert "s3cret-password" not in caplog.text
    assert "url-password" not in caplog.text
    assert "user:" not in caplog.text


# --- pure helpers -------------------------------------------------------------


def test_hash_and_prefix_helpers(gateway):
    key_id = gateway.hash_api_key(RAW_KEY)
    assert gateway.is_api_key_id(key_id)
    assert not gateway.is_api_key_id(RAW_KEY)
    assert not gateway.is_api_key_id("sha256:short")
    assert gateway.key_ref_to_id(key_id) == key_id
    assert gateway.key_ref_to_id(RAW_KEY) == key_id
    assert gateway.api_key_display_prefix(RAW_KEY) == RAW_KEY[:20]
    assert gateway.api_key_display_prefix("short-key") == "shor", "never more than half a short key"


@pytest.mark.parametrize("field", ["requests_per_minute", "tokens_per_day", "tokens_per_minute"])
@pytest.mark.parametrize("value", [3_000_000_000, 2_147_483_648, 10**30, 1e999])
def test_key_limit_too_large_for_the_column_is_a_400(client, fake_postgres, field, value):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])
    # json.dumps writes 1e999 as Infinity, which Python's json also reads back.
    response = client.post(
        "/admin/keys",
        content=json.dumps({"name": "app", field: value}),
        headers={**bearer(ADMIN_KEY), "content-type": "application/json"},
    )

    assert response.status_code == 400, response.text
    assert field in response.json()["detail"]


def test_key_limit_at_the_column_maximum_is_accepted(client, fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])

    response = client.post(
        "/admin/keys", json={"name": "app", "tokens_per_day": 2_147_483_647}, headers=bearer(ADMIN_KEY),
    )

    assert response.status_code == 200, response.text
