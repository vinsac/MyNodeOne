"""R6: rate windows must roll, whatever the traffic looks like."""

import asyncio
import re
import types

import pytest

import main
from conftest import FakeRedis, RAW_KEY, bearer

COMPLETION = {"model": "test-model", "prompt": "say hi"}

MINUTE_START = 1_800_000_000.0  # A whole minute: 1_800_000_000 / 60 = 30_000_000
KEY = "sha256:" + "ab" * 32


class Clock:
    def __init__(self):
        self.now = MINUTE_START

    def advance(self, seconds):
        self.now += seconds


class ExpiringRedis(FakeRedis):
    """FakeRedis whose keys really expire, on the test's clock.

    A rearmed TTL on a key that never gets a chance to expire is the bug, so the
    fake must let that happen rather than ignoring TTLs.
    """

    def __init__(self, clock):
        super().__init__()
        self.clock = clock
        self.expiry = {}

    def _purge(self):
        for key, at in list(self.expiry.items()):
            if at <= self.clock.now:
                self.data.pop(key, None)
                del self.expiry[key]

    async def get(self, key):
        self._purge()
        return await super().get(key)

    async def incrby(self, key, amount):
        self._purge()
        return await super().incrby(key, amount)

    async def expire(self, key, seconds):
        self.expiry[key] = self.clock.now + seconds
        return await super().expire(key, seconds)

    async def ttl(self, key):
        return round(self.expiry[key] - self.clock.now) if key in self.expiry else -1


@pytest.fixture
def clock(monkeypatch):
    clock = Clock()
    real_time = main.time
    monkeypatch.setattr(main, "time", types.SimpleNamespace(
        time=lambda: clock.now, monotonic=real_time.monotonic, perf_counter=real_time.perf_counter,
    ))
    return clock


@pytest.fixture
def store(clock):
    redis_client = main.RedisClient()
    redis_client.client = ExpiringRedis(clock)
    return redis_client


def test_steady_traffic_under_the_limit_is_never_rejected(store, clock):
    """3 requests a minute against a limit of 10. With the expiry rearmed on each
    request the count never reset, so this was rejected from about the 10th."""
    async def scenario():
        for _ in range(90):  # 30 minutes
            allowed, _retry_after = await store.check_rate_limit_with_info(KEY, 10)
            assert allowed
            clock.advance(20)

    asyncio.run(scenario())


def test_steady_token_use_under_the_limit_is_never_rejected(store, clock):
    async def scenario():
        for _ in range(90):
            allowed, _retry_after = await store.check_tpm_limit(KEY, 100, 1000)
            assert allowed
            await store.add_tpm_usage(KEY, 100)
            clock.advance(20)

    asyncio.run(scenario())


def test_rpm_rejects_at_the_limit_then_recovers_at_the_next_minute(store, clock):
    async def scenario():
        for _ in range(3):
            assert (await store.check_rate_limit_with_info(KEY, 3))[0]
        clock.advance(15)
        allowed, retry_after = await store.check_rate_limit_with_info(KEY, 3)
        assert not allowed
        assert retry_after == 45

        clock.advance(44)
        assert not (await store.check_rate_limit_with_info(KEY, 3))[0]
        clock.advance(1)
        assert (await store.check_rate_limit_with_info(KEY, 3))[0]

    asyncio.run(scenario())


def test_tpm_rejects_at_the_limit_then_recovers_at_the_next_minute(store, clock):
    async def scenario():
        assert (await store.check_tpm_limit(KEY, 90, 100))[0]
        clock.advance(10)
        allowed, retry_after = await store.check_tpm_limit(KEY, 20, 100)
        assert not allowed
        assert retry_after == 50

        clock.advance(50)
        assert (await store.check_tpm_limit(KEY, 20, 100))[0]

    asyncio.run(scenario())


def test_output_tokens_count_against_the_window_they_finish_in(store, clock):
    async def scenario():
        assert (await store.check_tpm_limit(KEY, 10, 100))[0]
        clock.advance(60)
        await store.add_tpm_usage(KEY, 95)
        assert not (await store.check_tpm_limit(KEY, 10, 100))[0]

    asyncio.run(scenario())


def test_retry_after_is_at_least_one_second(store, clock):
    async def scenario():
        await store.check_rate_limit_with_info(KEY, 1)
        clock.advance(59.5)
        allowed, retry_after = await store.check_rate_limit_with_info(KEY, 1)
        assert not allowed
        assert retry_after == 1

    asyncio.run(scenario())


def test_rate_limit_info_reports_the_current_window(store, clock):
    async def scenario():
        await store.check_rate_limit_with_info(KEY, 10)
        clock.advance(20)
        assert await store.get_rate_limit_info(KEY) == (1, 40)
        clock.advance(40)
        assert await store.get_rate_limit_info(KEY) == (0, 60)

    asyncio.run(scenario())


def test_each_charge_sets_its_expiry_in_one_transaction(store, clock):
    """So a crash between the two can't leave a key that never expires."""
    async def scenario():
        await store.check_rate_limit_with_info(KEY, 10)
        await store.check_tpm_limit(KEY, 5, 100)
        await store.add_tpm_usage(KEY, 5)

    asyncio.run(scenario())

    assert store.client.pipelines == [
        (True, ["incrby", "expire"]),
        (True, ["incrby", "expire"]),
        (True, ["incrby", "expire"]),
    ]


def test_no_key_is_left_without_an_expiry_and_old_windows_go_away(store, clock):
    async def scenario():
        for bucket in (None, "vllm", "embedding"):
            await store.check_rate_limit_with_info(KEY, 10, bucket=bucket)
            await store.check_tpm_limit(KEY, 5, 100, bucket=bucket)
        assert store.client.data
        assert store.client.expiry.keys() == store.client.data.keys()

        clock.advance(main.RedisClient.RATE_KEY_TTL_SECONDS + 1)
        store.client._purge()
        assert store.client.data == {}

    asyncio.run(scenario())


def test_keys_name_the_hashed_key_bucket_metric_and_minute(store, clock):
    asyncio.run(store.check_rate_limit_with_info(KEY, 10, bucket="vllm"))

    assert list(store.client.data) == [f"ratelimit:{KEY}:vllm:rpm:30000000"]
    assert re.fullmatch(r"ratelimit:sha256:[0-9a-f]{64}:vllm:rpm:\d+", next(iter(store.client.data)))


def test_http_429_then_served_at_the_next_minute(client, clock, fake_postgres, backend):
    fake_postgres.add_key(RAW_KEY, requests_per_minute=2)

    def post():
        return client.post("/v1/completions", json=COMPLETION, headers=bearer(RAW_KEY))

    assert post().status_code == 200
    assert post().status_code == 200
    clock.advance(30)
    rejected = post()
    assert rejected.status_code == 429
    assert rejected.headers["retry-after"] == "30"
    assert len(backend.requests) == 2

    clock.advance(30)
    assert post().status_code == 200
