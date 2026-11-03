"""Fakes for Redis, Postgres and the inference backends.

The gateway's own RedisClient, RateLimiter, BackendManager and ModelRegistry run
for real. Only what they talk to is replaced: the redis-py client, the Postgres
client (tests that need real SQL use a real server, see test_postgres_migration.py)
and the HTTP transport to the backends.

Run from anywhere with:  pytest scripts/apps/llmapi/gateway/tests
"""

import asyncio
import fnmatch
import json
import sys
from collections import deque
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import asyncpg
import httpx
import pytest
from starlette.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import main  # noqa: E402


class FakePipeline:
    def __init__(self, redis, transaction):
        self._redis = redis
        self._transaction = transaction
        self._ops = []

    def __getattr__(self, name):
        def queue(*args, **kwargs):
            self._ops.append((name, args, kwargs))
            return self
        return queue

    async def execute(self):
        self._redis.pipelines.append((self._transaction, [name for name, _, _ in self._ops]))
        return [await getattr(self._redis, name)(*args, **kwargs) for name, args, kwargs in self._ops]


class FakeRedis:
    """The subset of redis.asyncio.Redis that RedisClient uses."""

    def __init__(self):
        self.data = {}
        self.ttls = {}
        self.pipelines = []  # (is a MULTI/EXEC transaction, command names) per execute()

    async def ping(self):
        return True

    async def aclose(self):
        pass

    async def close(self):
        pass

    async def get(self, key):
        return self.data.get(key)

    async def set(self, key, value, nx=False, ex=None):
        if nx and key in self.data:
            return None
        self.data[key] = value
        return True

    async def delete(self, *keys):
        return sum(1 for key in keys if self.data.pop(key, None) is not None)

    async def ttl(self, key):
        return self.ttls.get(key, -1)

    async def expire(self, key, seconds):
        self.ttls[key] = seconds
        return True

    async def incrby(self, key, amount):
        self.data[key] = str(int(self.data.get(key, 0)) + amount)
        return int(self.data[key])

    async def incr(self, key):
        return await self.incrby(key, 1)

    def pipeline(self, transaction=True):
        return FakePipeline(self, transaction)

    async def scan_iter(self, match="*", count=None):
        for key in list(self.data):
            if fnmatch.fnmatchcase(key, match):
                yield key


class FakePostgres:
    """In-memory stand-in for PostgresClient, keyed by key id like the real one."""

    def __init__(self):
        self.keys = {}
        self.revoked = set()
        self.usage = []
        self.quota_ok = True
        self.available = True

    def add_key(self, raw_key, scopes=("inference",), name="test", **overrides):
        key_id = main.hash_api_key(raw_key)
        self.keys[key_id] = {
            "key_prefix": main.api_key_display_prefix(raw_key),
            "name": name,
            "scopes": list(scopes),
            "requests_per_minute": 1000,
            "tokens_per_day": 1000000,
            "tokens_per_minute": 1000000,
            "created_at": "2026-01-01T00:00:00",
            **overrides,
        }
        return key_id

    async def get_api_key_config(self, api_key):
        if not self.available:
            raise main.StoreUnavailable("postgres is down")
        if api_key in self.revoked:
            return None
        return self.keys.get(api_key)

    async def set_api_key_config(self, api_key, config_data):
        self.keys[api_key] = config_data

    async def delete_api_key(self, api_key):
        self.revoked.add(api_key)

    async def migrate_plaintext_key(self, raw_key):
        if not self.available:
            raise main.StoreUnavailable("postgres is down")
        return None

    async def migrate_plaintext_keys(self):
        return 0

    async def list_api_keys(self, prefix="sk-mynodeone-"):
        if not self.available:
            raise main.StoreUnavailable("postgres is down")
        return [
            {"key_id": key_id, **config}
            for key_id, config in self.keys.items()
            if key_id not in self.revoked
        ]

    async def get_key_revocation_states(self):
        if not self.available:
            raise main.StoreUnavailable("postgres is down")
        return {key_id: key_id in self.revoked for key_id in self.keys}

    async def check_token_quota(self, api_key, tokens_per_day):
        return self.quota_ok or not self.available

    async def add_token_usage(self, api_key, input_tokens, output_tokens):
        if not self.available:
            return
        self.usage.append((api_key, input_tokens, output_tokens))

    async def get_token_usage(self, api_key):
        if not self.available:
            raise main.StoreUnavailable("postgres is down")
        return 0, 0

    async def get_all_keys_stats(self, hours=96):
        if not self.available:
            raise main.StoreUnavailable("postgres is down")
        return {"window_hours": hours, "summary": {}, "by_key": [], "hourly": []}


class _BackendStream(httpx.AsyncByteStream):
    def __init__(self, backend):
        self.backend = backend

    async def __aiter__(self):
        for chunk in self.backend.stream_chunks:
            self.backend.chunks_produced += 1
            yield chunk
        if self.backend.after_chunks == "hang":
            await asyncio.Event().wait()
        while self.backend.after_chunks == "drip":
            await asyncio.sleep(0.005)
            self.backend.chunks_produced += 1
            yield self.backend.stream_chunks[-1]

    async def aclose(self):
        self.backend.stream_closed = True


class FakeBackend:
    """Answers the gateway's backend calls and records them."""

    def __init__(self):
        self.requests = []
        self.stream_chunks = [
            b'data: {"choices":[{"delta":{"content":"one"},"text":"one"}]}\n\n',
            b'data: {"choices":[{"delta":{"content":"two"},"text":"two"}]}\n\n',
        ]
        self.after_chunks = "finish"  # or "hang", or "drip" (keep producing)
        self.stream_closed = False
        self.chunks_produced = 0
        self.embed = lambda text: [0.1, 0.2]
        self.stream_error = None  # (status, body) to answer streaming requests with

    def handle(self, request):
        body = json.loads(request.content)
        self.requests.append((request.url.path, body))
        if body.get("stream") and self.stream_error:
            return httpx.Response(self.stream_error[0], text=self.stream_error[1])
        if body.get("stream"):
            return httpx.Response(200, stream=_BackendStream(self), headers={"content-type": "text/event-stream"})
        if request.url.path == "/v1/embeddings":
            inputs = body["input"] if isinstance(body["input"], list) else [body["input"]]
            return httpx.Response(200, json={
                "data": [{"embedding": self.embed(text), "index": i} for i, text in enumerate(inputs)],
                "usage": {"prompt_tokens": 3, "total_tokens": 3},
            })
        return httpx.Response(200, json={
            "choices": [{"text": "hello", "message": {"role": "assistant", "content": "hello"}}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12},
        })


@pytest.fixture
def fake_redis():
    return FakeRedis()


@pytest.fixture
def fake_postgres():
    return FakePostgres()


@pytest.fixture
def backend():
    return FakeBackend()


@pytest.fixture
def gateway(monkeypatch, fake_redis, fake_postgres, backend):
    """The gateway module wired to the fakes, with one vLLM and one embedding backend."""
    redis_client = main.RedisClient()
    redis_client.client = fake_redis
    monkeypatch.setattr(main, "redis_client", redis_client)
    monkeypatch.setattr(main, "postgres_client", fake_postgres)
    monkeypatch.setattr(main, "rate_limiter", main.RateLimiter())

    registry = main.ModelRegistry()
    registry.register_model("test-model", "vllm")
    registry.register_model("test-embed", "embedding")
    monkeypatch.setattr(main, "model_registry", registry)

    manager = main.BackendManager()
    manager.http_client = httpx.AsyncClient(transport=httpx.MockTransport(backend.handle))
    manager._register_slot("vllm", "http://vllm.test", 4)
    manager._register_slot("embedding", "http://embedding.test", 4)
    manager.backend_health = {key: True for key in manager.backend_health}
    monkeypatch.setattr(main, "backend_manager", manager)
    return main


@pytest.fixture
def client(gateway):
    # Not used as a context manager, so the lifespan (real connections) doesn't run.
    return TestClient(gateway.app)


# The tables as the previous gateway version created them, before key_prefix.
PRE_HASHING_SCHEMA = """
    DROP TABLE IF EXISTS api_keys, usage_logs CASCADE;
    CREATE TABLE api_keys (
        api_key VARCHAR(255) PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        scopes TEXT[] NOT NULL DEFAULT '{inference}',
        requests_per_minute INTEGER NOT NULL DEFAULT 60,
        tokens_per_day INTEGER NOT NULL DEFAULT 100000,
        tokens_per_minute INTEGER NOT NULL DEFAULT 200000,
        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
        revoked BOOLEAN NOT NULL DEFAULT FALSE
    );
    CREATE TABLE usage_logs (
        id BIGSERIAL PRIMARY KEY,
        api_key VARCHAR(255) NOT NULL,
        date DATE NOT NULL,
        hour INTEGER NOT NULL CHECK (hour >= 0 AND hour < 24),
        input_tokens BIGINT NOT NULL DEFAULT 0,
        output_tokens BIGINT NOT NULL DEFAULT 0,
        requests INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
        UNIQUE(api_key, date, hour)
    );
"""


class PgDatabase:
    """A real PostgreSQL on a Unix socket, reset to the pre-hashing schema."""

    def __init__(self, server):
        self.server = server
        self.socket_dir = parse_qs(urlsplit(server.get_uri()).query)["host"][0]
        self.bin_dir = str(Path(pgserver_module().__file__).parent / "pginstall" / "bin")

    def sql(self, statement):
        return self.server.psql(statement)

    def rows(self, query):
        async def fetch():
            conn = await asyncpg.connect(host=self.socket_dir, user="postgres", database="postgres")
            try:
                return [dict(row) for row in await conn.fetch(query)]
            finally:
                await conn.close()
        return asyncio.run(fetch())


def pgserver_module():
    return pytest.importorskip("pgserver")


@pytest.fixture(scope="session")
def pg_server(tmp_path_factory):
    # Skips the tests that use it when pgserver (test-only, optional) isn't installed.
    server = pgserver_module().get_server(tmp_path_factory.mktemp("pgdata"), cleanup_mode="stop")
    yield server
    server.cleanup()


@pytest.fixture
def db(pg_server):
    pg_server.psql(PRE_HASHING_SCHEMA)
    return PgDatabase(pg_server)


RAW_KEY = "sk-mynodeone-" + "a1" * 16
METRICS_KEY = "sk-mynodeone-" + "b2" * 16
ADMIN_KEY = "sk-mynodeone-" + "c3" * 16


def bearer(raw_key):
    return {"Authorization": f"Bearer {raw_key}"}


def total_inflight(gateway):
    """Leases held across backends and per-key pools. Must return to 0."""
    backend_leases = sum(slot.inflight for slot in gateway.backend_manager.slots.values())
    key_leases = sum(slot.inflight for slot in gateway.rate_limiter.pools.values())
    return backend_leases + key_leases


class AsgiCall:
    """Drives the app directly, for control TestClient can't give: when each body
    chunk is delivered, whether the app read it at all, and when the client leaves."""

    def __init__(self, app, method, path, *, token=None, chunks=(b"",), headers=(), spec_version="2.3",
                 disconnect_after_chunks=None):
        self.app = app
        self.scope = {
            "type": "http",
            "asgi": {"version": "3.0", "spec_version": spec_version},
            "http_version": "1.1",
            "method": method,
            "path": path,
            "raw_path": path.encode(),
            "query_string": b"",
            "root_path": "",
            "scheme": "http",
            "server": ("127.0.0.1", 8000),
            "client": ("127.0.0.1", 12345),
            "headers": [
                (b"content-type", b"application/json"),
                *([(b"authorization", f"Bearer {token}".encode())] if token else []),
                *headers,
            ],
        }
        self._pending = deque(
            {"type": "http.request", "body": chunk, "more_body": index < len(chunks) - 1}
            for index, chunk in enumerate(chunks)
        )
        self._disconnect_after = disconnect_after_chunks
        self._disconnected = asyncio.Event()
        self.body_messages_read = 0
        self.status = None
        self.response_headers = {}
        self.body = b""
        self._body_chunks_sent = 0

    def disconnect(self):
        self._disconnected.set()

    async def _receive(self):
        if self._pending:
            self.body_messages_read += 1
            return self._pending.popleft()
        await self._disconnected.wait()
        return {"type": "http.disconnect"}

    async def _send(self, message):
        if message["type"] == "http.response.start":
            self.status = message["status"]
            self.response_headers = {name.decode(): value.decode() for name, value in message["headers"]}
        elif message["type"] == "http.response.body" and message.get("body"):
            self.body += message["body"]
            self._body_chunks_sent += 1
            if self._disconnect_after and self._body_chunks_sent >= self._disconnect_after:
                self.disconnect()

    async def run(self, timeout=5):
        await asyncio.wait_for(self.app(self.scope, self._receive, self._send), timeout)
        return self
