"""R12: a Redis or Postgres outage must fail fast, and auth must fail closed.

The hanging fakes never return, and some ignore cancellation, as a hung server can
make a client do. Where it matters the real redis and asyncpg clients are pointed
at a socket that accepts connections and never answers, and at a closed port.
"""

import asyncio
import socket
import time

import asyncpg
import httpx
import pytest

import main
from conftest import FakeRedis, RAW_KEY, bearer, total_inflight

CHAT = {"model": "test-model", "messages": [{"role": "user", "content": "say hi"}]}
COMPLETION = {"model": "test-model", "prompt": "say hi"}
EMBEDDING = {"model": "test-embed", "input": ["hello"]}

OP_LIMIT = 0.1
RECONNECT_LIMIT = 0.2
# What a request may cost in the worst case, with room for a slow CI machine.
FAST = 1.0
# For tests that tell "waited for a limit" from "didn't wait at all": the limit, and
# the most that not waiting may appear to take on a busy machine. Scheduler noise has
# reached 0.163s here, so a shorter limit can't separate the two.
LONG_LIMIT = 1.0
NO_WAIT = 0.5


@pytest.fixture(autouse=True)
def short_limits(monkeypatch):
    for name, value in {
        "REDIS_CONNECT_TIMEOUT_SECONDS": OP_LIMIT,
        "REDIS_OP_TIMEOUT_SECONDS": OP_LIMIT,
        "REDIS_BULK_OP_TIMEOUT_SECONDS": OP_LIMIT * 2,
        "POSTGRES_CONNECT_TIMEOUT_SECONDS": OP_LIMIT,
        "POSTGRES_RECONNECT_TIMEOUT_SECONDS": RECONNECT_LIMIT,
        "POSTGRES_OP_TIMEOUT_SECONDS": OP_LIMIT,
        "POSTGRES_BULK_OP_TIMEOUT_SECONDS": OP_LIMIT * 2,
    }.items():
        monkeypatch.setattr(main.config, name, value)


async def hang():
    await asyncio.Event().wait()


class Stubborn:
    """An operation that keeps going when cancelled, until told to stop."""

    def __init__(self):
        self.release = asyncio.Event()

    async def run(self):
        while not self.release.is_set():
            try:
                await self.release.wait()
            except asyncio.CancelledError:
                pass


class HangingRedis(FakeRedis):
    async def get(self, key):
        await hang()

    async def ping(self):
        await hang()

    def pipeline(self, transaction=True):
        raise AssertionError("not expected in this test")


class RefusingRedis(FakeRedis):
    async def get(self, key):
        raise ConnectionRefusedError("refused")

    async def ping(self):
        raise ConnectionRefusedError("refused")


class HangingPool:
    def __init__(self):
        self.terminated = False

    def acquire(self):
        return self

    async def __aenter__(self):
        await hang()

    async def __aexit__(self, *exc):
        pass

    def terminate(self):
        self.terminated = True


class Timed:
    def __enter__(self):
        self.started = time.monotonic()
        return self

    def __exit__(self, *exc):
        self.elapsed = time.monotonic() - self.started


@pytest.fixture
def silent_port():
    """Accepts connections and never answers."""
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(64)
        yield listener.getsockname()[1]


@pytest.fixture
def closed_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def redis_with(fake, monkeypatch, *, reconnect_to=None):
    client = main.RedisClient()
    client.client = fake
    monkeypatch.setattr(client, "_new_client", lambda: reconnect_to or HangingRedis())
    return client


# --- _bounded --------------------------------------------------------------


def test_bounded_returns_the_result_and_raises_its_errors():
    async def scenario():
        async def value():
            return 1

        async def error():
            raise ValueError("x")

        assert await main._bounded(value(), 1) == 1
        with pytest.raises(ValueError):
            await main._bounded(error(), 1)

    asyncio.run(scenario())


def test_bounded_returns_on_time_even_if_the_operation_ignores_cancellation():
    async def scenario():
        stubborn = Stubborn()
        task_count = len(asyncio.all_tasks())
        with Timed() as timed:
            with pytest.raises(asyncio.TimeoutError):
                await main._bounded(stubborn.run(), 0.05)
        assert timed.elapsed < 0.5
        assert len(asyncio.all_tasks()) == task_count + 1  # still running, not awaited
        stubborn.release.set()

    asyncio.run(scenario())


def test_bounded_passes_cancellation_on():
    async def scenario():
        cancelled = asyncio.Event()

        async def operation():
            try:
                await hang()
            finally:
                cancelled.set()

        task = asyncio.create_task(main._bounded(operation(), 30))
        await asyncio.sleep(0.01)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await asyncio.wait_for(cancelled.wait(), 1)

    asyncio.run(scenario())


# --- Redis -----------------------------------------------------------------


def test_hung_redis_costs_one_op_limit_then_nothing(monkeypatch):
    monkeypatch.setattr(main.config, "REDIS_OP_TIMEOUT_SECONDS", LONG_LIMIT)
    monkeypatch.setattr(main.config, "REDIS_CONNECT_TIMEOUT_SECONDS", LONG_LIMIT)
    client = redis_with(HangingRedis(), monkeypatch)

    async def scenario():
        with Timed() as first:
            assert await client.get_value("x") is None
        assert client.client is None

        # The next caller makes the one reconnect attempt, also limited.
        with Timed() as second:
            assert await client.get_value("x") is None

        # Then there's nothing to wait for until the backoff has passed.
        with Timed() as third:
            results = await asyncio.gather(*(client.get_value("x") for _ in range(50)))
        return first.elapsed, second.elapsed, third.elapsed, results

    first, second, third, results = asyncio.run(scenario())

    assert first < LONG_LIMIT + NO_WAIT
    assert second < LONG_LIMIT + NO_WAIT
    assert third < NO_WAIT
    assert results == [None] * 50


def test_concurrent_callers_during_a_redis_hang_all_answer_within_the_limit(monkeypatch):
    client = redis_with(HangingRedis(), monkeypatch)

    async def scenario():
        with Timed() as timed:
            await asyncio.gather(*(client.get_value("x") for _ in range(200)))
        return timed.elapsed

    assert asyncio.run(scenario()) < FAST


def test_only_one_redis_reconnect_at_a_time(monkeypatch):
    client = main.RedisClient()
    created = []

    def new_client():
        created.append(1)
        return HangingRedis()

    monkeypatch.setattr(client, "_new_client", new_client)

    async def scenario():
        await asyncio.gather(*(client.get_value("x") for _ in range(50)))

    asyncio.run(scenario())

    assert len(created) == 1


def test_redis_reconnect_backs_off_and_recovers(monkeypatch):
    monkeypatch.setattr(main._ReconnectGate, "INITIAL_BACKOFF_SECONDS", NO_WAIT)
    monkeypatch.setattr(main.config, "STORE_RECONNECT_MAX_BACKOFF_SECONDS", LONG_LIMIT)
    client = main.RedisClient()
    created = []
    healthy = FakeRedis()
    healthy.data["x"] = "value"
    next_client = [RefusingRedis()]

    def new_client():
        created.append(1)
        return next_client[0]

    monkeypatch.setattr(client, "_new_client", new_client)

    async def scenario():
        assert await client.get_value("x") is None
        assert len(created) == 1
        assert await client.get_value("x") is None
        assert len(created) == 1, "within the backoff"

        await asyncio.sleep(NO_WAIT + 0.01)
        assert await client.get_value("x") is None
        assert len(created) == 2

        next_client[0] = healthy
        await asyncio.sleep(LONG_LIMIT + 0.01)  # The backoff doubled
        assert await client.get_value("x") == "value"
        assert client.client is healthy

    asyncio.run(scenario())


def test_cancelled_reconnect_doesnt_block_later_ones(monkeypatch):
    monkeypatch.setattr(main._ReconnectGate, "INITIAL_BACKOFF_SECONDS", 0.01)
    client = main.RedisClient()
    monkeypatch.setattr(client, "_new_client", HangingRedis)

    async def scenario():
        task = asyncio.create_task(client.get_value("x"))
        await asyncio.sleep(0.01)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        await asyncio.sleep(0.02)
        assert client._reconnect_gate.try_begin()

    asyncio.run(scenario())


def test_slow_bulk_redis_scan_doesnt_mark_redis_down(monkeypatch):
    client = redis_with(FakeRedis(), monkeypatch)
    healthy = client.client

    async def slow_scan():
        await hang()

    async def scenario():
        with Timed() as timed:
            assert await client._safe(slow_scan, default="x", timeout=0.05) == "x"
        return timed.elapsed

    assert asyncio.run(scenario()) < 0.5
    assert client.client is healthy


def test_lost_redis_connection_is_retried_once_on_a_new_client(monkeypatch):
    healthy = FakeRedis()
    healthy.data["x"] = "value"
    client = redis_with(RefusingRedis(), monkeypatch, reconnect_to=healthy)

    assert asyncio.run(client.get_value("x")) == "value"
    assert client.client is healthy


@pytest.mark.parametrize("port_fixture", ["silent_port", "closed_port"])
def test_real_redis_client_fails_fast(monkeypatch, request, port_fixture):
    port = request.getfixturevalue(port_fixture)
    monkeypatch.setattr(main.config, "REDIS_URL", f"redis://127.0.0.1:{port}/0")
    monkeypatch.setattr(main.config, "REDIS_PASSWORD", "")
    client = main.RedisClient()

    async def scenario():
        await client.connect()
        with Timed() as first:
            assert await client.get_value("x") is None
        with Timed() as later:
            assert await asyncio.gather(*(client.get_value("x") for _ in range(20))) == [None] * 20
        allowed, _ = await client.check_rate_limit_with_info("sha256:" + "a" * 64, 1)
        assert allowed, "rate limiting fails open"
        return first.elapsed, later.elapsed

    first, later = asyncio.run(scenario())

    assert first < FAST
    assert later < FAST


# --- Postgres --------------------------------------------------------------


def postgres_with(pool, monkeypatch, create_pool=None):
    client = main.PostgresClient()
    client.pool = pool

    async def no_schema():
        pass

    monkeypatch.setattr(client, "_init_schema", no_schema)
    if create_pool is not None:
        monkeypatch.setattr(main.asyncpg, "create_pool", create_pool)
    return client


def test_hung_postgres_is_a_prompt_store_unavailable(monkeypatch):
    monkeypatch.setattr(main.config, "POSTGRES_OP_TIMEOUT_SECONDS", LONG_LIMIT)
    monkeypatch.setattr(main.config, "POSTGRES_RECONNECT_TIMEOUT_SECONDS", LONG_LIMIT)
    pool = HangingPool()
    attempts = []

    async def create_pool(**kwargs):
        attempts.append(kwargs)
        await hang()

    client = postgres_with(pool, monkeypatch, create_pool)

    async def scenario():
        with Timed() as first:
            with pytest.raises(main.StoreUnavailable):
                await client.get_api_key_config("x")
        assert pool.terminated and client.pool is None
        assert attempts == [], "a timeout isn't retried"

        with Timed() as second:
            with pytest.raises(main.StoreUnavailable):
                await client.get_api_key_config("x")

        with Timed() as third:
            results = await asyncio.gather(
                *(client.get_api_key_config("x") for _ in range(50)), return_exceptions=True,
            )
        assert all(isinstance(result, main.StoreUnavailable) for result in results)
        return first.elapsed, second.elapsed, third.elapsed

    first, second, third = asyncio.run(scenario())

    assert first < LONG_LIMIT + NO_WAIT
    assert second < LONG_LIMIT + NO_WAIT
    assert third < NO_WAIT
    assert len(attempts) == 1


def test_concurrent_callers_during_a_postgres_hang_all_answer_within_the_limit(monkeypatch):
    async def create_pool(**kwargs):
        await hang()

    client = postgres_with(HangingPool(), monkeypatch, create_pool)

    async def scenario():
        with Timed() as timed:
            await asyncio.gather(*(client.get_api_key_config("x") for _ in range(100)), return_exceptions=True)
        return timed.elapsed

    assert asyncio.run(scenario()) < FAST


def test_postgres_query_ignoring_cancellation_doesnt_hold_up_the_request(monkeypatch):
    client = postgres_with(HangingPool(), monkeypatch)

    async def scenario():
        stubborn = Stubborn()

        async def query():
            await stubborn.run()

        with Timed() as timed:
            with pytest.raises(main.StoreUnavailable):
                await client._execute_with_retry(query)
        stubborn.release.set()
        return timed.elapsed

    assert asyncio.run(scenario()) < FAST


def test_only_one_postgres_reconnect_at_a_time_with_backoff(monkeypatch):
    attempts = []

    async def create_pool(**kwargs):
        attempts.append(kwargs)
        raise OSError("refused")

    monkeypatch.setattr(main._ReconnectGate, "INITIAL_BACKOFF_SECONDS", NO_WAIT)
    client = postgres_with(None, monkeypatch, create_pool)

    async def scenario():
        await asyncio.gather(*(client.get_api_key_config("x") for _ in range(50)), return_exceptions=True)
        assert len(attempts) == 1
        with pytest.raises(main.StoreUnavailable):
            await client.get_api_key_config("x")
        assert len(attempts) == 1, "within the backoff"
        await asyncio.sleep(NO_WAIT + 0.01)
        with pytest.raises(main.StoreUnavailable):
            await client.get_api_key_config("x")
        assert len(attempts) == 2

    asyncio.run(scenario())


def test_reconnect_limits_are_passed_to_the_driver(monkeypatch):
    seen = {}

    async def create_pool(**kwargs):
        seen.update(kwargs)
        raise OSError("refused")

    client = postgres_with(None, monkeypatch, create_pool)

    with pytest.raises(main.StoreUnavailable):
        asyncio.run(client.get_api_key_config("x"))

    assert seen["timeout"] == main.config.POSTGRES_CONNECT_TIMEOUT_SECONDS


def test_sql_errors_are_not_mistaken_for_an_outage(monkeypatch):
    pool = HangingPool()
    client = postgres_with(pool, monkeypatch)

    async def bad_query():
        raise asyncpg.exceptions.UndefinedTableError("no such table")

    with pytest.raises(asyncpg.exceptions.UndefinedTableError):
        asyncio.run(client._execute_with_retry(bad_query))

    assert client.pool is pool and not pool.terminated


def test_slow_bulk_query_doesnt_mark_postgres_down(monkeypatch):
    pool = HangingPool()
    client = postgres_with(pool, monkeypatch)

    with pytest.raises(main.StoreUnavailable):
        asyncio.run(client._execute_with_retry(hang, timeout=0.05))

    assert client.pool is pool and not pool.terminated


def test_outage_answers_are_distinct_from_empty_answers(monkeypatch):
    async def create_pool(**kwargs):
        raise OSError("refused")

    client = postgres_with(None, monkeypatch, create_pool)

    async def scenario():
        with pytest.raises(main.StoreUnavailable):
            await client.get_api_key_config("x")
        client._reconnect_gate.succeeded()
        with pytest.raises(main.StoreUnavailable):
            await client.list_api_keys()
        client._reconnect_gate.succeeded()
        with pytest.raises(main.StoreUnavailable):
            await client.get_token_usage("x")
        client._reconnect_gate.succeeded()
        assert await client.check_token_quota("x", 10) is True, "the daily quota fails open"
        client._reconnect_gate.succeeded()
        await client.add_token_usage("x", 1, 1)  # Lost, not raised

    asyncio.run(scenario())


@pytest.mark.parametrize("port_fixture", ["silent_port", "closed_port"])
def test_real_asyncpg_fails_fast(monkeypatch, request, port_fixture):
    monkeypatch.setattr(main.config, "POSTGRES_HOST", "127.0.0.1")
    monkeypatch.setattr(main.config, "POSTGRES_PORT", request.getfixturevalue(port_fixture))
    monkeypatch.setattr(main.config, "POSTGRES_PASSWORD", "x")
    monkeypatch.setattr(main.config, "POSTGRES_CONNECT_TIMEOUT_SECONDS", LONG_LIMIT)
    monkeypatch.setattr(main.config, "POSTGRES_RECONNECT_TIMEOUT_SECONDS", LONG_LIMIT)
    client = main.PostgresClient()

    async def scenario():
        with Timed() as first:
            with pytest.raises(main.StoreUnavailable):
                await client.get_api_key_config("x")
        with Timed() as later:
            results = await asyncio.gather(*(client.get_api_key_config("x") for _ in range(20)), return_exceptions=True)
        assert all(isinstance(result, main.StoreUnavailable) for result in results)
        return first.elapsed, later.elapsed

    first, later = asyncio.run(scenario())

    assert first < LONG_LIMIT + NO_WAIT
    assert later < NO_WAIT


def test_real_postgres_recovers_after_losing_its_connections(gateway, db, monkeypatch):
    monkeypatch.setattr(main.config, "POSTGRES_HOST", db.socket_dir)
    monkeypatch.setattr(main.config, "POSTGRES_USER", "postgres")
    monkeypatch.setattr(main.config, "POSTGRES_DB", "postgres")
    monkeypatch.setattr(main.config, "POSTGRES_PASSWORD", "")
    monkeypatch.setattr(main.config, "POSTGRES_RECONNECT_TIMEOUT_SECONDS", 10)
    monkeypatch.setattr(main.config, "POSTGRES_OP_TIMEOUT_SECONDS", 10)
    monkeypatch.setattr(main.config, "POSTGRES_BULK_OP_TIMEOUT_SECONDS", 30)

    async def scenario():
        client = main.PostgresClient()
        await client.connect()
        try:
            old_pool = client.pool
            old_pool.terminate()  # As a Postgres restart would leave it
            assert await client.get_api_key_config("nobody") is None
            assert client.pool is not old_pool
        finally:
            await client.close()

    asyncio.run(scenario())


# --- What a request sees ---------------------------------------------------


@pytest.fixture
def down_redis(gateway, monkeypatch):
    """Redis marked down, and every reconnect attempt refused."""
    client = main.RedisClient()
    monkeypatch.setattr(client, "_new_client", RefusingRedis)
    monkeypatch.setattr(main, "redis_client", client)
    return client


@pytest.fixture
def down_postgres(gateway, fake_postgres):
    fake_postgres.available = False
    return fake_postgres


async def post(gateway, path, body, key=RAW_KEY):
    transport = httpx.ASGITransport(gateway.app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as http:
        return await http.post(path, json=body, headers=bearer(key))


async def get(gateway, path, key=RAW_KEY):
    transport = httpx.ASGITransport(gateway.app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as http:
        return await http.get(path, headers=bearer(key))


def cache_key(gateway, fake_redis, fake_postgres, scopes=("inference",)):
    """Put a valid key in the Redis auth cache only."""
    available = fake_postgres.available
    fake_postgres.available = True
    key_id = fake_postgres.add_key(RAW_KEY, scopes=list(scopes))
    asyncio.run(main.RedisClient.set_api_key_config(gateway.redis_client, key_id, fake_postgres.keys[key_id]))
    fake_postgres.available = available
    return key_id


@pytest.mark.parametrize("path,body", [
    ("/v1/chat/completions", CHAT),
    ("/v1/completions", COMPLETION),
    ("/v1/embeddings", EMBEDDING),
])
def test_both_stores_down_is_a_503_and_nothing_is_authorized(gateway, down_redis, down_postgres, backend, path, body):
    down_postgres.add_key(RAW_KEY)  # Valid, but nothing can say so

    response = asyncio.run(post(gateway, path, body))

    assert response.status_code == 503
    assert response.headers["retry-after"] == "5"
    assert backend.requests == []
    assert total_inflight(gateway) == 0


@pytest.mark.parametrize("path", ["/v1/usage", "/admin/keys"])
def test_both_stores_down_other_endpoints_are_a_503_too(gateway, down_redis, down_postgres, path):
    down_postgres.add_key(RAW_KEY, scopes=["admin"])

    assert asyncio.run(get(gateway, path)).status_code == 503


def test_stats_outage_is_a_503_not_a_page_of_zeros(gateway, down_postgres, fake_redis):
    down_postgres.add_key(RAW_KEY, scopes=["admin"])
    down_postgres.available = True  # Long enough to authenticate; the stats query then fails.
    real_stats = down_postgres.get_all_keys_stats

    async def stats_after_postgres_went_down(hours=96):
        down_postgres.available = False
        return await real_stats(hours)

    down_postgres.get_all_keys_stats = stats_after_postgres_went_down

    response = asyncio.run(get(gateway, "/admin/stats"))

    assert response.status_code == 503
    assert response.headers["retry-after"] == "5"


def test_stats_client_raises_on_an_outage_instead_of_returning_zeros(monkeypatch):
    async def create_pool(**kwargs):
        raise OSError("refused")

    client = postgres_with(None, monkeypatch, create_pool)

    with pytest.raises(main.StoreUnavailable):
        asyncio.run(client.get_all_keys_stats())


def test_both_really_hung_is_a_prompt_503(gateway, backend, monkeypatch, silent_port):
    """The real clients, end to end, against servers that never answer."""
    monkeypatch.setattr(main.config, "REDIS_URL", f"redis://127.0.0.1:{silent_port}/0")
    monkeypatch.setattr(main.config, "REDIS_PASSWORD", "")
    monkeypatch.setattr(main.config, "POSTGRES_HOST", "127.0.0.1")
    monkeypatch.setattr(main.config, "POSTGRES_PORT", silent_port)
    monkeypatch.setattr(main, "redis_client", main.RedisClient())
    monkeypatch.setattr(main, "postgres_client", main.PostgresClient())

    async def scenario():
        await main.redis_client.connect()
        with Timed() as first:
            response = await post(gateway, "/v1/completions", COMPLETION)
        with Timed() as later:
            responses = await asyncio.gather(*(post(gateway, "/v1/completions", COMPLETION) for _ in range(20)))
        return first.elapsed, later.elapsed, response, responses

    first, later, response, responses = asyncio.run(scenario())

    assert response.status_code == 503
    assert {each.status_code for each in responses} == {503}
    assert first < 2
    assert later < 1
    assert backend.requests == []
    assert total_inflight(gateway) == 0


def test_postgres_down_cached_key_is_served_and_unrecorded(gateway, fake_redis, down_postgres, backend):
    cache_key(gateway, fake_redis, down_postgres)
    down_postgres.quota_ok = False  # Over quota, but the quota can't be read

    response = asyncio.run(post(gateway, "/v1/completions", COMPLETION))

    assert response.status_code == 200
    assert len(backend.requests) == 1
    assert down_postgres.usage == []
    assert total_inflight(gateway) == 0


def test_postgres_down_unknown_key_is_a_503_not_a_401(gateway, down_postgres, backend):
    response = asyncio.run(post(gateway, "/v1/completions", COMPLETION))

    assert response.status_code == 503
    assert backend.requests == []


def test_postgres_up_unknown_key_is_still_a_401(gateway, backend):
    response = asyncio.run(post(gateway, "/v1/completions", COMPLETION))

    assert response.status_code == 401
    assert backend.requests == []


def test_postgres_down_key_management_is_a_503(gateway, fake_redis, down_postgres):
    cache_key(gateway, fake_redis, down_postgres, scopes=["admin", "inference"])

    assert asyncio.run(get(gateway, "/admin/keys")).status_code == 503
    assert asyncio.run(get(gateway, "/v1/usage")).status_code == 503


def test_redis_down_authenticates_from_postgres_and_serves(gateway, down_redis, fake_postgres, backend):
    fake_postgres.add_key(RAW_KEY, requests_per_minute=1)

    async def scenario():
        with Timed() as timed:
            responses = [await post(gateway, "/v1/completions", COMPLETION) for _ in range(3)]
        return responses, timed.elapsed

    responses, elapsed = asyncio.run(scenario())

    assert [response.status_code for response in responses] == [200, 200, 200], "RPM fails open"
    assert len(fake_postgres.usage) == 3
    assert elapsed < FAST


def test_redis_down_revoked_key_is_still_refused(gateway, down_redis, fake_postgres, backend):
    key_id = fake_postgres.add_key(RAW_KEY)
    fake_postgres.revoked.add(key_id)

    response = asyncio.run(post(gateway, "/v1/completions", COMPLETION))

    assert response.status_code == 401
    assert backend.requests == []


def test_health_needs_neither_store(gateway, down_redis, down_postgres):
    assert asyncio.run(get(gateway, "/health")).status_code == 200


@pytest.mark.parametrize("path,body", [
    ("/v1/chat/completions", CHAT),
    ("/v1/completions", COMPLETION),
    ("/v1/embeddings", EMBEDDING),
])
def test_no_lease_is_held_while_waiting_on_postgres(gateway, fake_postgres, monkeypatch, path, body):
    fake_postgres.add_key(RAW_KEY)
    held = {}

    async def quota(api_key, tokens_per_day):
        held["quota"] = total_inflight(gateway)
        return True

    async def add_usage(api_key, input_tokens, output_tokens):
        held["usage"] = total_inflight(gateway)

    monkeypatch.setattr(fake_postgres, "check_token_quota", quota)
    monkeypatch.setattr(fake_postgres, "add_token_usage", add_usage)

    assert asyncio.run(post(gateway, path, body)).status_code == 200

    assert held == {"quota": 0, "usage": 0}


def test_quota_refusal_still_happens_and_takes_no_slot(gateway, fake_postgres, backend):
    fake_postgres.add_key(RAW_KEY)
    fake_postgres.quota_ok = False

    response = asyncio.run(post(gateway, "/v1/completions", COMPLETION))

    assert response.status_code == 429
    assert backend.requests == []
    assert total_inflight(gateway) == 0


def test_stream_slots_are_free_while_recording_usage(gateway, fake_postgres, backend):
    fake_postgres.add_key(RAW_KEY)
    held = []

    async def add_usage(api_key, input_tokens, output_tokens):
        held.append(total_inflight(gateway))

    fake_postgres.add_token_usage = add_usage

    response = asyncio.run(post(gateway, "/v1/completions", {**COMPLETION, "stream": True}))

    assert response.status_code == 200
    assert held == [0]
