"""S19 and S5 against a real PostgreSQL: upgrading plaintext rows and the warm loop."""

import asyncio
import json
import logging

import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from conftest import METRICS_KEY, RAW_KEY

KEY_ID_PREFIX = "sha256:"


@pytest.fixture
def run(db, gateway, monkeypatch):
    """Run a scenario with a real PostgresClient installed as the gateway's client."""
    monkeypatch.setattr(gateway.config, "POSTGRES_HOST", db.socket_dir)
    monkeypatch.setattr(gateway.config, "POSTGRES_USER", "postgres")
    monkeypatch.setattr(gateway.config, "POSTGRES_DB", "postgres")
    monkeypatch.setattr(gateway.config, "POSTGRES_PASSWORD", "")

    def runner(scenario):
        async def wrapped():
            client = gateway.PostgresClient()
            await client.connect()
            monkeypatch.setattr(gateway, "postgres_client", client)
            try:
                return await scenario(client)
            finally:
                await client.close()
        return asyncio.run(wrapped())
    return runner


async def _nothing(client):
    return None


def insert_key(db, api_key, name="legacy", revoked=False, scopes="{inference}"):
    db.sql(f"INSERT INTO api_keys (api_key, name, scopes, revoked, tokens_per_day) "
           f"VALUES ('{api_key}', '{name}', '{scopes}', {revoked}, 777);")


def insert_usage(db, api_key, input_tokens, output_tokens, requests=1, hour=5):
    db.sql(f"INSERT INTO usage_logs (api_key, date, hour, input_tokens, output_tokens, requests) "
           f"VALUES ('{api_key}', CURRENT_DATE, {hour}, {input_tokens}, {output_tokens}, {requests});")


def all_stored_values(db):
    keys = db.rows("SELECT * FROM api_keys")
    usage = db.rows("SELECT * FROM usage_logs")
    return json.dumps([keys, usage], default=str)


def test_startup_migrates_plaintext_rows_and_keeps_the_key_working(db, run, gateway):
    insert_key(db, RAW_KEY, scopes="{inference,metrics}")
    insert_usage(db, RAW_KEY, 10, 20, requests=3)
    key_id = gateway.hash_api_key(RAW_KEY)

    config = run(lambda client: client.get_api_key_config(key_id))

    assert config["name"] == "legacy"
    assert config["scopes"] == ["inference", "metrics"]
    assert config["tokens_per_day"] == 777
    assert config["key_prefix"] == RAW_KEY[:20]
    assert RAW_KEY not in all_stored_values(db), "no raw key may remain in any column"
    usage = db.rows("SELECT api_key, input_tokens, output_tokens, requests FROM usage_logs")
    assert usage == [{"api_key": key_id, "input_tokens": 10, "output_tokens": 20, "requests": 3}]


def test_migration_is_safe_to_repeat(db, run, gateway):
    insert_key(db, RAW_KEY)
    insert_usage(db, RAW_KEY, 10, 20)

    async def scenario(client):
        assert await client.migrate_plaintext_keys() == 0
        assert await client.migrate_plaintext_keys() == 0
    run(scenario)
    run(_nothing)  # a restart

    assert db.rows("SELECT input_tokens, output_tokens FROM usage_logs") == [{"input_tokens": 10, "output_tokens": 20}]
    assert len(db.rows("SELECT 1 FROM api_keys")) == 1


def test_usage_under_both_identities_is_merged(db, run, gateway):
    """An old pod keeps writing raw-key usage during a rolling update."""
    run(_nothing)
    key_id = gateway.hash_api_key(RAW_KEY)
    insert_key(db, key_id)
    insert_usage(db, key_id, 100, 200, requests=2)
    insert_key(db, RAW_KEY)
    insert_usage(db, RAW_KEY, 1, 2, requests=1)
    insert_usage(db, RAW_KEY, 5, 5, requests=1, hour=6)

    run(_nothing)

    usage = db.rows("SELECT hour, input_tokens, output_tokens, requests FROM usage_logs ORDER BY hour")
    assert usage == [
        {"hour": 5, "input_tokens": 101, "output_tokens": 202, "requests": 3},
        {"hour": 6, "input_tokens": 5, "output_tokens": 5, "requests": 1},
    ]
    assert RAW_KEY not in all_stored_values(db)


def test_usage_without_a_key_row_is_still_hashed(db, run, gateway):
    insert_usage(db, RAW_KEY, 1, 2)

    run(_nothing)

    assert db.rows("SELECT api_key FROM usage_logs") == [{"api_key": gateway.hash_api_key(RAW_KEY)}]
    assert db.rows("SELECT * FROM api_keys") == []


def test_revoked_state_survives_migration(db, run, gateway):
    insert_key(db, RAW_KEY, revoked=True)
    key_id = gateway.hash_api_key(RAW_KEY)

    assert run(lambda client: client.get_api_key_config(key_id)) is None

    assert db.rows("SELECT revoked FROM api_keys") == [{"revoked": True}]


def test_reinserting_a_revoked_key_as_plaintext_does_not_revive_it(db, run, gateway):
    run(_nothing)
    key_id = gateway.hash_api_key(RAW_KEY)
    insert_key(db, key_id, revoked=True)
    insert_key(db, RAW_KEY, revoked=False)

    assert run(lambda client: client.get_api_key_config(key_id)) is None

    assert db.rows("SELECT api_key, revoked FROM api_keys") == [{"api_key": key_id, "revoked": True}]


def test_rows_with_the_id_are_left_alone(db, run, gateway):
    run(_nothing)
    key_id = gateway.hash_api_key(RAW_KEY)
    db.sql(f"INSERT INTO api_keys (api_key, key_prefix, name) VALUES ('{key_id}', 'sk-prefix', 'hashed');")

    async def scenario(client):
        return await client.migrate_plaintext_keys()

    assert run(scenario) == 0
    assert db.rows("SELECT api_key, key_prefix, name FROM api_keys") == [
        {"api_key": key_id, "key_prefix": "sk-prefix", "name": "hashed"}
    ]


def test_concurrent_migrations_do_not_double_count_usage(db, run):
    run(_nothing)
    for hour in range(4):
        insert_usage(db, RAW_KEY, 10, 10, hour=hour)
    insert_key(db, RAW_KEY)

    async def scenario(client):
        await asyncio.gather(*(client.migrate_plaintext_keys() for _ in range(5)))
    run(scenario)

    assert db.rows("SELECT SUM(input_tokens)::int AS total FROM usage_logs") == [{"total": 40}]


def test_key_inserted_by_the_installer_after_startup_works_on_first_use(db, run, gateway):
    """install-llmapi.sh still inserts plaintext rows while the gateway is running."""
    async def scenario(client):
        insert_key(db, RAW_KEY)
        credentials = HTTPAuthorizationCredentials(scheme="Bearer", credentials=RAW_KEY)
        return await gateway.get_api_key(credentials)

    key_id = run(scenario)

    assert key_id == gateway.hash_api_key(RAW_KEY)
    assert RAW_KEY not in all_stored_values(db)
    assert f"apikey:{key_id}" in gateway.redis_client.client.data


def test_presenting_a_stored_id_fails_and_leaves_the_row_intact(db, run, gateway):
    insert_key(db, RAW_KEY)
    key_id = gateway.hash_api_key(RAW_KEY)

    async def scenario(client):
        credentials = HTTPAuthorizationCredentials(scheme="Bearer", credentials=key_id)
        with pytest.raises(HTTPException) as rejected:
            await gateway.get_api_key(credentials)
        return rejected.value.status_code

    assert run(scenario) == 401
    assert db.rows("SELECT api_key FROM api_keys") == [{"api_key": key_id}]
    assert not any(key_id in key for key in gateway.redis_client.client.data)


def test_list_returns_only_ids_and_never_a_row_awaiting_migration(db, run, gateway):
    insert_key(db, RAW_KEY)

    async def scenario(client):
        insert_key(db, METRICS_KEY)  # arrives after the startup migration
        return await client.list_api_keys()

    listed = run(scenario)

    assert [entry["key_id"] for entry in listed] == [gateway.hash_api_key(RAW_KEY)]
    assert "key" not in listed[0]
    assert METRICS_KEY not in json.dumps(listed, default=str)


def test_stats_preview_shows_only_the_prefix(db, run, gateway):
    insert_key(db, RAW_KEY)

    async def scenario(client):
        await client.add_token_usage(gateway.hash_api_key(RAW_KEY), 1, 2)
        return await client.get_all_keys_stats()

    stats = run(scenario)

    assert RAW_KEY not in json.dumps(stats, default=str)
    assert stats["by_key"][0]["api_key_preview"] == RAW_KEY[:20] + "..."


def test_set_config_keeps_the_prefix_when_a_caller_omits_it(db, run, gateway):
    insert_key(db, RAW_KEY)
    key_id = gateway.hash_api_key(RAW_KEY)

    async def scenario(client):
        config_data = await client.get_api_key_config(key_id)
        config_data.pop("key_prefix")
        await client.set_api_key_config(key_id, config_data)
        return await client.get_api_key_config(key_id)

    assert run(scenario)["key_prefix"] == RAW_KEY[:20]


def test_warm_loop_evicts_a_key_revoked_directly_in_postgres(db, run, gateway):
    insert_key(db, RAW_KEY)
    insert_key(db, METRICS_KEY)
    revoked_id = gateway.hash_api_key(RAW_KEY)
    active_id = gateway.hash_api_key(METRICS_KEY)
    cache = gateway.redis_client.client.data

    async def scenario(client):
        await gateway.warm_redis_from_postgres()
        assert f"apikey:{revoked_id}" in cache
        db.sql(f"UPDATE api_keys SET revoked = TRUE WHERE api_key = '{revoked_id}';")
        await gateway.warm_redis_from_postgres()

    run(scenario)

    assert f"apikey:{revoked_id}" not in cache
    assert f"apikey:{active_id}" in cache


def test_warm_loop_migrates_rows_inserted_since_startup(db, run, gateway):
    async def scenario(client):
        insert_key(db, RAW_KEY)
        await gateway.warm_redis_from_postgres()

    run(scenario)

    assert RAW_KEY not in all_stored_values(db)
    assert f"apikey:{gateway.hash_api_key(RAW_KEY)}" in gateway.redis_client.client.data


def test_a_failed_row_is_retried_later_and_its_key_is_not_logged(db, run, gateway, caplog):
    """A database error's text can quote the row, so only the error type is logged."""
    insert_key(db, RAW_KEY)
    db.sql("""
        CREATE FUNCTION fail_migration() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'refusing %', OLD.api_key; END;
        $$ LANGUAGE plpgsql;
        CREATE TRIGGER block_delete BEFORE DELETE ON api_keys
        FOR EACH ROW EXECUTE FUNCTION fail_migration();
    """)

    try:
        with caplog.at_level(logging.DEBUG):
            run(_nothing)

        assert RAW_KEY not in caplog.text
        assert "RaiseError" in caplog.text
        assert db.rows("SELECT api_key FROM api_keys") == [{"api_key": RAW_KEY}], "rolled back as a unit"
    finally:
        db.sql("DROP TRIGGER block_delete ON api_keys; DROP FUNCTION fail_migration();")

    run(_nothing)
    assert db.rows("SELECT api_key FROM api_keys") == [{"api_key": gateway.hash_api_key(RAW_KEY)}]
