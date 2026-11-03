"""Traefik blocks /admin, /docs, /redoc and /openapi.json by PathPrefix, which is case
sensitive and doesn't see through an encoded slash. So these paths do reach the gateway,
and only the router keeps them from the admin handlers, the admin UI and the schema.

A real uvicorn on loopback with the h11 parser the lockfile installs, and a raw socket,
as HTTP clients normalize paths and uvicorn's decoding is part of what's being pinned.
"""

import asyncio
import contextlib
import json

import pytest
import uvicorn

from conftest import ADMIN_KEY

# Every one of these was confirmed to pass real Traefik 2.11 with the generated rule.
PASS_THE_EDGE = [
    "/ADMIN", "/Admin", "/Admin/keys", "/ADMIN/KEYS", "/ADMIN/dashboard", "/%41DMIN",
    "/%2fadmin", "/%2Fadmin", "/%2fadmin/", "/%2fadmin/keys", "/%2Fadmin/keys", "/%2fadmin%2fkeys",
    "/%2fadmin/dashboard", "/%2fadmin%2f", "/%252fadmin", "/%5cadmin", "/%5Cadmin/keys",
    "/%2e%2fadmin", "/%2e%2e%2fadmin", "/x%2f..%2fadmin", "/v1/%2e%2e%2fadmin",
    "/DOCS", "/Docs", "/%2fdocs", "/REDOC", "/%2fredoc",
    "/OPENAPI.JSON", "/OpenAPI.json", "/%2fopenapi.json", "/%2Fopenapi.json",
]


@contextlib.asynccontextmanager
async def serving(app):
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=0, http="h11", lifespan="off", log_level="critical"))
    task = asyncio.create_task(server.serve())
    try:
        while not server.started:
            await asyncio.sleep(0.01)
        yield server.servers[0].sockets[0].getsockname()[1]
    finally:
        server.should_exit = True
        server.force_exit = True
        await task


async def raw_request(port, method, target, *, key=None, body=b""):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    head = f"{method} {target} HTTP/1.1\r\nHost: test\r\nConnection: close\r\nContent-Length: {len(body)}\r\n"
    if key:
        head += f"Authorization: Bearer {key}\r\n"
    writer.write(head.encode() + b"\r\n" + body)
    await writer.drain()
    answer = await asyncio.wait_for(reader.read(), 5)
    writer.close()
    status = int(answer.split(b" ", 2)[1])
    return status, answer.partition(b"\r\n\r\n")[2]


def requests_through_uvicorn(app, calls):
    async def scenario():
        async with serving(app) as port:
            return [await raw_request(port, *call[:2], **call[2]) for call in calls]
    return asyncio.run(scenario())


@pytest.fixture
def admin_key(fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])
    return ADMIN_KEY


def test_paths_that_pass_the_edge_find_nothing_with_or_without_a_key(gateway, admin_key):
    calls = [("GET", path, {}) for path in PASS_THE_EDGE]
    calls += [("GET", path, {"key": admin_key}) for path in PASS_THE_EDGE]

    answers = requests_through_uvicorn(gateway.app, calls)

    for (_, path, _), (status, body) in zip(calls, answers):
        assert status == 404, path
        assert json.loads(body) == {"detail": "Not Found"}, path


@pytest.mark.parametrize("target", ["/ADMIN/keys", "/%2fadmin/keys", "/%2Fadmin%2fkeys"])
def test_creating_a_key_through_a_path_that_passes_the_edge_is_a_404(gateway, admin_key, fake_postgres, target):
    before = dict(fake_postgres.keys)

    [(status, _)] = requests_through_uvicorn(
        gateway.app, [("POST", target, {"key": admin_key, "body": b'{"name": "x"}'})],
    )

    assert status == 404
    assert fake_postgres.keys == before


def test_this_check_would_notice_the_real_paths(gateway, admin_key):
    """So the 404s above mean the router, not a broken harness. These real paths are served
    here because the test has no edge in front; Traefik blocks each of them."""
    [(page, html), (schema, _), (keys, _), (decoded_keys, _)] = requests_through_uvicorn(gateway.app, [
        ("GET", "/admin", {}),
        ("GET", "/openapi.json", {}),
        ("GET", "/admin/keys", {"key": admin_key}),
        ("GET", "/admin%2fkeys", {"key": admin_key}),
    ])

    assert (page, schema, keys, decoded_keys) == (200, 200, 200, 200)
    assert b"<html" in html.lower()
