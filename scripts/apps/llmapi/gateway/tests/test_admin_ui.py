"""S21 app side and the DOM XSS item: security headers, CSP, and self-contained pages.
test_admin_browser.py checks the same pages in a real browser, when one is available."""

import base64
import hashlib
import re

import pytest

import main
from conftest import RAW_KEY, bearer

PAGES = {"/admin": main.ADMIN_LOGIN_HTML, "/admin/dashboard": main.ADMIN_HTML}
ALL_HTML = main.ADMIN_LOGIN_HTML + main.ADMIN_HTML


def csp_directives(header):
    return {part.split()[0]: part.split()[1:] for part in header.split(";") if part.strip()}


@pytest.mark.parametrize("path", ["/admin", "/admin/dashboard", "/health", "/admin/assets/admin.css", "/no-such-path"])
def test_security_headers_on_every_response(client, path):
    headers = client.get(path).headers

    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["strict-transport-security"].startswith("max-age=")
    assert "frame-ancestors 'none'" in headers["content-security-policy"]


def test_security_headers_on_rejected_requests(client, gateway, monkeypatch):
    monkeypatch.setattr(gateway.config, "MAX_REQUEST_BODY_BYTES", 10)

    too_large = client.post("/v1/completions", content=b"x" * 11)
    unauthorized = client.get("/admin/keys", headers=bearer("sk-mynodeone-nope"))

    for response in (too_large, unauthorized):
        assert response.headers["x-content-type-options"] == "nosniff"
        assert "content-security-policy" in response.headers


def test_api_responses_get_a_locked_down_csp(client):
    directives = csp_directives(client.get("/health").headers["content-security-policy"])

    assert directives["default-src"] == ["'none'"]


@pytest.mark.parametrize("path", PAGES)
def test_page_csp_allows_only_this_pages_inline_scripts(client, path):
    response = client.get(path)
    directives = csp_directives(response.headers["content-security-policy"])

    scripts = re.findall(r"<script>(.*?)</script>", response.text, re.DOTALL)
    assert scripts, "the page has an inline script"
    expected = {
        "'sha256-" + base64.b64encode(hashlib.sha256(script.encode()).digest()).decode() + "'"
        for script in scripts
    }
    assert set(directives["script-src"]) == {"'self'"} | expected
    assert "'unsafe-inline'" not in directives["script-src"]
    assert "'unsafe-eval'" not in directives["script-src"]
    assert directives["default-src"] == ["'none'"]
    assert directives["connect-src"] == ["'self'"]
    assert directives["base-uri"] == ["'none'"]
    assert directives["form-action"] == ["'self'"]


@pytest.mark.parametrize("html", PAGES.values(), ids=PAGES.keys())
def test_pages_load_nothing_from_third_parties(html):
    assert "cdn.tailwindcss.com" not in html
    assert "unpkg.com" not in html
    for tag in re.findall(r"<(?:script|link|img|iframe)\b[^>]*>", html):
        url = re.search(r'(?:src|href)="([^"]*)"', tag)
        if url:
            assert url.group(1).startswith("/"), tag


@pytest.mark.parametrize("html", PAGES.values(), ids=PAGES.keys())
def test_pages_have_no_inline_event_handlers(html):
    """The CSP would block them, silently breaking the button."""
    assert not re.findall(r"""<[^>]*\son[a-z]+\s*=""", html)


def test_every_data_action_has_a_handler():
    actions = set(re.findall(r'data-action="([A-Za-z]+)"', main.ADMIN_HTML))
    block = re.search(r"const CLICK_ACTIONS = \{(.*?)\n\s*\};", main.ADMIN_HTML, re.DOTALL).group(1)
    handlers = set(re.findall(r"\b([A-Za-z]+)\b(?=\s*[,:])", block))

    assert actions
    assert actions <= handlers, actions - handlers


def _classes_used():
    tokens = set()
    expression = r"\$\{[^}]*\}"
    templates = re.findall(r'class="((?:[^"$]|' + expression + r')*)"', ALL_HTML)
    templates += re.findall(r"\.className\s*=\s*`([^`]*)`", ALL_HTML)
    templates += re.findall(r"\.className\s*=\s*'([^']*)'", ALL_HTML)
    for template in templates:
        for value in re.findall(expression, template):
            # Quoted branches of a ternary, not the values it compares against.
            for quoted in re.findall(r"'([^']*)'", re.sub(r"[=!]==?\s*'[^']*'", "", value)):
                tokens.update(quoted.split())
        tokens.update(re.sub(expression, " ", template).split())
    tokens.update(re.findall(r"classList\.(?:add|remove|toggle)\('([^']+)'", ALL_HTML))
    return tokens


def test_stylesheet_covers_every_class_the_pages_use(client):
    css = client.get("/admin/assets/admin.css").text
    tokens = _classes_used()
    assert len(tokens) > 100, "the scan found the classes"

    missing = {token for token in tokens if "." + re.sub(r"([:/.])", r"\\\1", token) not in css}

    assert not missing, f"regenerate _ADMIN_CSS (see the comment above it): {sorted(missing)}"


def test_every_icon_the_pages_use_is_embedded(client):
    icons_js = client.get("/admin/assets/icons.js").text
    used = set(re.findall(r'data-lucide="([a-z0-9-]+)"', ALL_HTML))
    assert used

    missing = {name for name in used if f'"{name}":' not in icons_js}

    assert not missing, missing


def test_assets_have_types_that_survive_nosniff(client):
    assert client.get("/admin/assets/admin.css").headers["content-type"].startswith("text/css")
    assert client.get("/admin/assets/icons.js").headers["content-type"].startswith("text/javascript")


def test_icon_runtime_does_not_parse_html(client):
    assert "innerHTML" not in client.get("/admin/assets/icons.js").text


@pytest.mark.parametrize("field", [
    "k.name", "k.key", "k.key_id", "k.key_prefix", "k.api_key", "k.api_key_preview",
    "m.id", "m.backend", "m.status", "ds.model", "ds.error",
])
def test_stored_values_are_escaped_before_reaching_inner_html(field):
    assert "${" + field + "}" not in main.ADMIN_HTML


def test_dashboard_offers_no_way_to_show_full_keys():
    for leftover in ("toggleKeyVisibility", "maskKey", "data-key=", "k.key)"):
        assert leftover not in main.ADMIN_HTML


def test_key_list_response_matches_what_the_dashboard_reads(client, fake_postgres):
    fake_postgres.add_key(RAW_KEY, scopes=["admin"])

    key = client.get("/admin/keys", headers=bearer(RAW_KEY)).json()["keys"][0]

    assert {"key_id", "key_prefix", "name"} <= set(key)
    assert "key" not in key
