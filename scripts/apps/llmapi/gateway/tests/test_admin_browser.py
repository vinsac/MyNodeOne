"""The admin pages in a real browser, against the gateway on 127.0.0.1 with fakes.

This is what catches a CSP that blocks the pages' own scripts or styles, a broken
click handler, or stored markup that executes. Skips without playwright and Chrome.
"""

import shutil
import socket
import threading
import time

import pytest
import uvicorn

from conftest import ADMIN_KEY, RAW_KEY

sync_api = pytest.importorskip("playwright.sync_api")

XSS_NAME = """<img src=x onerror="window.__xss=1">'"><script>window.__xss=2</script>"""


@pytest.fixture
def server_url(gateway):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(gateway.app, host="127.0.0.1", port=port, lifespan="off", log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    while not server.started:
        time.sleep(0.01)
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join(timeout=5)


@pytest.fixture
def page(server_url):
    if not shutil.which("google-chrome"):
        pytest.skip("Chrome is not installed")
    with sync_api.sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome", headless=True)
        page = browser.new_page()
        page.problems = []
        page.foreign_requests = []
        page.on("console", lambda m: page.problems.append(m.text) if "Content Security Policy" in m.text else None)
        page.on("pageerror", lambda e: page.problems.append(str(e)))
        # Everything off-origin is recorded and blocked, so a miss can't reach the network.
        def route(route_request):
            if route_request.request.url.startswith(server_url):
                route_request.continue_()
            else:
                page.foreign_requests.append(route_request.request.url)
                route_request.abort()
        page.route("**/*", route)
        yield page
        browser.close()


def log_in(page, server_url, key=ADMIN_KEY):
    page.goto(f"{server_url}/admin")
    page.fill("#api-key", key)
    page.click("button[type=submit]")
    page.wait_for_url("**/admin/dashboard")
    page.wait_for_selector("#keys-list [data-action=revokeKey]")


def test_login_page_is_styled_and_has_icons_under_its_csp(page, server_url):
    page.goto(f"{server_url}/admin")

    assert page.evaluate("getComputedStyle(document.body).backgroundColor") == "rgb(17, 24, 39)"
    icon = page.wait_for_selector("svg.lucide-brain")
    assert icon.bounding_box()["width"] == 64, "w-16 sizes the icon"
    assert page.evaluate("document.querySelectorAll('i[data-lucide]').length") == 0
    assert page.problems == []
    assert page.foreign_requests == []


def test_login_form_rejects_a_bad_key_inline(page, server_url):
    page.goto(f"{server_url}/admin")
    page.fill("#api-key", "not-a-key")
    page.click("button[type=submit]")

    assert "Invalid API key format" in page.wait_for_selector("#error-message").text_content()
    assert page.url.endswith("/admin")


def test_dashboard_works_under_its_csp(page, server_url, fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin", "inference"], name="admin")

    log_in(page, server_url)

    assert page.evaluate("getComputedStyle(document.body).backgroundColor") == "rgb(17, 24, 39)"
    assert page.evaluate("document.querySelectorAll('i[data-lucide]').length") == 0
    assert page.evaluate("document.querySelectorAll('svg.lucide').length") > 10
    assert page.problems == []
    assert page.foreign_requests == []


def test_stored_markup_in_a_key_name_does_not_execute(page, server_url, fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin", "inference"], name="admin")
    fake_postgres.add_key(RAW_KEY, name=XSS_NAME)

    log_in(page, server_url)
    page.wait_for_function("() => document.getElementById('keys-list').textContent.includes('onerror')")

    assert page.evaluate("window.__xss") is None
    assert page.evaluate("document.querySelectorAll('#keys-list img, #keys-list script').length") == 0
    assert XSS_NAME in page.text_content("#keys-list"), "shown as plain text"
    assert page.foreign_requests == []


def test_markup_in_a_key_id_can_not_break_out_of_the_action_attribute(page, server_url, fake_postgres, gateway):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin", "inference"], name="admin")
    fake_postgres.keys["x' onmouseover='window.__xss=3"] = {
        **fake_postgres.keys[gateway.hash_api_key(ADMIN_KEY)], "name": "hostile id", "key_prefix": None,
    }

    log_in(page, server_url)
    page.wait_for_function("() => document.getElementById('keys-list').textContent.includes('hostile id')")

    assert page.evaluate("document.querySelectorAll('#keys-list [onmouseover]').length") == 0


def test_revoke_button_reaches_the_api_through_the_click_dispatcher(page, server_url, fake_postgres, gateway):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin", "inference"], name="admin")
    target_id = fake_postgres.add_key(RAW_KEY, name="target")
    page.on("dialog", lambda dialog: dialog.accept())

    log_in(page, server_url)
    # The icon inside the button is what a person actually clicks on.
    page.click(f'[data-action=revokeKey][data-arg="{target_id}"] svg')
    page.wait_for_function("() => !document.getElementById('keys-list').textContent.includes('target')")

    assert target_id in fake_postgres.revoked
    assert page.problems == []


def test_key_list_shows_no_raw_key_and_the_markup_has_none_either(page, server_url, fake_postgres):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin", "inference"], name="admin")
    fake_postgres.add_key(RAW_KEY, name="visible")

    log_in(page, server_url)
    page.wait_for_function("() => document.getElementById('keys-list').textContent.includes('visible')")

    html = page.inner_html("#keys-list")
    assert RAW_KEY[:20] + "..." in html
    assert RAW_KEY not in html
    assert ADMIN_KEY not in html
