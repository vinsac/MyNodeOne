"""R13: a client that stops reading a stream must not hold its slots forever.

The first test is the reproduction: a real uvicorn on loopback and a real TCP
client that stops reading, so the backpressure is uvicorn's own flow control and
not a simulation of it.
"""

import asyncio
import contextlib
import json
import socket
import time

import pytest
import uvicorn

from conftest import AsgiCall, RAW_KEY, total_inflight

STREAM_REQUEST = {"model": "test-model", "prompt": "hi", "stream": True}


def big_event(size=65536):
    return b'data: {"choices":[{"text":"' + b"x" * size + b'"}]}\n\n'


@pytest.fixture
def key_id(fake_postgres):
    return fake_postgres.add_key(RAW_KEY)


@contextlib.asynccontextmanager
async def serving(app):
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=0, lifespan="off", log_level="critical"))
    task = asyncio.create_task(server.serve())
    try:
        while not server.started:
            await asyncio.sleep(0.01)
        yield server.servers[0].sockets[0].getsockname()[1]
    finally:
        server.should_exit = True
        server.force_exit = True
        await task


async def open_stalling_client(port):
    """Start a streaming request, read only the start of the answer, then stop reading."""
    loop = asyncio.get_running_loop()
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    sock.setblocking(False)
    await loop.sock_connect(sock, ("127.0.0.1", port))
    body = json.dumps(STREAM_REQUEST).encode()
    await loop.sock_sendall(sock, (
        b"POST /v1/completions HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\n"
        + f"Authorization: Bearer {RAW_KEY}\r\nContent-Length: {len(body)}\r\n\r\n".encode()
        + body
    ))
    assert (await asyncio.wait_for(loop.sock_recv(sock, 1024), 5)).startswith(b"HTTP/1.1 200")
    return sock


async def wait_until_backpressured(backend, quiet=0.5, limit=30):
    """Return once the backend stops being read, meaning the send side is blocked."""
    deadline = time.monotonic() + limit
    last = -1
    while time.monotonic() < deadline:
        await asyncio.sleep(quiet)
        if backend.chunks_produced == last:
            return
        last = backend.chunks_produced
    raise AssertionError("the stream never hit backpressure")


def test_stalled_reader_on_real_uvicorn_gets_its_slots_back(gateway, backend, fake_postgres, key_id, monkeypatch):
    monkeypatch.setattr(gateway.config, "STREAM_CLIENT_STALL_TIMEOUT_SECONDS", 1.5, raising=False)
    backend.stream_chunks = [big_event()]
    backend.after_chunks = "drip"

    async def scenario():
        async with serving(gateway.app) as port:
            sock = await open_stalling_client(port)
            try:
                await wait_until_backpressured(backend)
                deadline = time.monotonic() + 5
                while total_inflight(gateway) and time.monotonic() < deadline:
                    await asyncio.sleep(0.05)
                held = total_inflight(gateway)
                # If the client does come back, the response ends visibly incomplete.
                loop = asyncio.get_running_loop()
                tail = b""
                while data := await asyncio.wait_for(loop.sock_recv(sock, 65536), 5):
                    tail = (tail + data)[-16:]
                return held, tail
            finally:
                sock.close()

    held_after, tail = asyncio.run(scenario())

    assert not tail.endswith(b"0\r\n\r\n"), "a cut stream must not look complete"
    assert backend.chunks_produced > 1
    assert held_after == 0, f"{held_after} lease(s) still held by a client that stopped reading"
    assert backend.stream_closed, "the backend request must be closed so the GPU stops generating"
    assert [entry[0] for entry in fake_postgres.usage] == [key_id]


def test_slow_but_progressing_reader_on_real_uvicorn_gets_the_whole_stream(gateway, backend, fake_postgres, key_id, monkeypatch):
    """Far slower than the backend, and slower overall than the limit, but always reading."""
    # The small receive buffer takes about 10 reads per event, so each send waits about
    # 0.15s here: far enough under the limit that a busy machine can't look like a stall.
    monkeypatch.setattr(gateway.config, "STREAM_CLIENT_STALL_TIMEOUT_SECONDS", 2.0)
    event = big_event()
    backend.stream_chunks = [event] * 40

    async def scenario():
        async with serving(gateway.app) as port:
            loop = asyncio.get_running_loop()
            sock = await open_stalling_client(port)
            received = 0
            started = time.monotonic()
            try:
                while True:
                    await asyncio.sleep(0.01)
                    data = await asyncio.wait_for(loop.sock_recv(sock, 65536), 5)
                    if not data:
                        break
                    received += len(data)
                    if data.endswith(b"0\r\n\r\n"):
                        break
            finally:
                sock.close()
            return received, time.monotonic() - started

    received, elapsed = asyncio.run(scenario())

    assert elapsed > 2.0, "the test must outlast the limit to show anything"
    assert received >= len(event) * 40 - 1024
    assert total_inflight(gateway) == 0


class BlockableCall(AsgiCall):
    """An ASGI client whose send() can block, as uvicorn's does when the client isn't reading."""

    def __init__(self, *args, send_delay=0, block_on=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.send_delay = send_delay
        self.block_on = block_on
        self.messages_sent = 0
        self.blocked = asyncio.Event()

    async def _send(self, message):
        if self.block_on is not None and self.messages_sent == self.block_on:
            self.blocked.set()
            await asyncio.Event().wait()
        self.messages_sent += 1
        if self.send_delay:
            await asyncio.sleep(self.send_delay)
        await super()._send(message)


def stream_call(gateway, **kwargs):
    return BlockableCall(gateway.app, "POST", "/v1/completions", token=RAW_KEY,
                         chunks=[json.dumps(STREAM_REQUEST).encode()], **kwargs)


@pytest.mark.parametrize("spec_version", ["2.3", "2.4"])
@pytest.mark.parametrize("block_on,charged", [
    (0, False),  # http.response.start: the generator never ran, so only the response can release
    (2, True),   # second body chunk
])
def test_blocked_send_ends_the_stream_and_releases(
    gateway, backend, fake_postgres, key_id, monkeypatch, spec_version, block_on, charged,
):
    monkeypatch.setattr(gateway.config, "STREAM_CLIENT_STALL_TIMEOUT_SECONDS", 0.2)
    backend.after_chunks = "drip"

    call = stream_call(gateway, block_on=block_on, spec_version=spec_version)
    asyncio.run(call.run())

    assert total_inflight(gateway) == 0
    assert backend.stream_closed or not charged
    assert bool(fake_postgres.usage) == charged


@pytest.mark.parametrize("spec_version", ["2.3", "2.4"])
def test_slow_writes_within_the_limit_are_not_cut(
    gateway, backend, fake_postgres, key_id, monkeypatch, spec_version,
):
    # A write has room for scheduler noise, and ten of them still take longer than one limit.
    monkeypatch.setattr(gateway.config, "STREAM_CLIENT_STALL_TIMEOUT_SECONDS", 0.6)
    backend.stream_chunks = [big_event(16)] * 10

    call = stream_call(gateway, send_delay=0.1, spec_version=spec_version)
    asyncio.run(call.run())

    assert call.body.count(b'"choices"') == 10, "the limit is per write, and the whole stream took longer than that"
    assert fake_postgres.usage[0][2] == 10


def test_a_quiet_backend_is_not_a_stalled_client(gateway, backend, key_id, monkeypatch):
    """A long think before the next token leaves send() idle, and must not end the stream."""
    monkeypatch.setattr(gateway.config, "STREAM_CLIENT_STALL_TIMEOUT_SECONDS", 0.1)
    backend.after_chunks = "hang"

    async def scenario():
        call = stream_call(gateway)
        task = asyncio.create_task(call.run(timeout=30))
        await asyncio.sleep(0.5)
        running = not task.done()
        held = total_inflight(gateway)
        call.disconnect()
        await task
        return running, held, call

    running, held, call = asyncio.run(scenario())

    assert running and held == 2
    assert call.body.count(b'"choices"') == 2
    assert total_inflight(gateway) == 0


def test_max_duration_ends_a_stream_that_keeps_progressing(gateway, backend, fake_postgres, key_id, monkeypatch):
    monkeypatch.setattr(gateway.config, "STREAM_MAX_DURATION_SECONDS", 0.3)
    backend.after_chunks = "drip"

    call = stream_call(gateway)
    started = time.monotonic()
    asyncio.run(call.run())

    assert 0.25 < time.monotonic() - started < 3
    assert total_inflight(gateway) == 0
    assert backend.stream_closed
    assert [entry[0] for entry in fake_postgres.usage] == [key_id]


def test_zero_disables_the_stall_limit(gateway, backend, key_id, monkeypatch):
    monkeypatch.setattr(gateway.config, "STREAM_CLIENT_STALL_TIMEOUT_SECONDS", 0)
    monkeypatch.setattr(gateway.config, "STREAM_MAX_DURATION_SECONDS", 0)

    async def scenario():
        call = stream_call(gateway, block_on=1)
        task = asyncio.create_task(call.run(timeout=30))
        await asyncio.wait_for(call.blocked.wait(), 5)
        await asyncio.sleep(0.3)
        held = total_inflight(gateway)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        return held

    assert asyncio.run(scenario()) == 2
    assert total_inflight(gateway) == 0
