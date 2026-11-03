"""The deployment and the gateway agree: env vars, packaged files, probes and Secrets.

The installer's gateway-config is the ConfigMap a cluster actually gets. manifests/gateway.yaml
is reference only. Reads manifests as text, as PyYAML isn't a dependency of these tests.
"""

import ast
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

import pytest

import main

APP_DIR = Path(__file__).resolve().parents[2]
GATEWAY_DIR = APP_DIR / "gateway"
MAIN_PY = GATEWAY_DIR / "main.py"
DEPLOYMENT = APP_DIR / "manifests" / "gateway-deployment.yaml"
REFERENCE_CONFIG = APP_DIR / "manifests" / "gateway.yaml"
INSTALLER = APP_DIR / "install-llmapi.sh"
DOCKERFILE = GATEWAY_DIR / "Dockerfile"

# Read without a usable default, but the gateway runs without them. Each needs a reason.
OPTIONAL_WITHOUT_DEFAULT = {
    "KUBERNETES_SERVICE_HOST": "set by Kubernetes in every pod; only chooses in-cluster config",
    "VLLM_MODEL_ID": "last fallback for showing the model name; MODEL_NAME is tried next",
    "EMBEDDING_MODEL_FILE": "only improves the embedding model's display name",
}

# In gateway/ but not part of the running gateway.
NOT_PACKAGED = re.compile(r"^(Dockerfile|pytest\.ini|requirements(-dev)?\.txt|requirements-dev\.lock|\..*)$")
NOT_PACKAGED_DIRS = {"tests", "__pycache__", "static"}  # static/ has its own ConfigMap.


def required_env_vars(source):
    """Env vars the source reads with no default, or an empty one. Non-literal names fail."""
    required = set()

    def is_call(node, *names):
        return isinstance(node, ast.Call) and ast.unparse(node.func) in names

    for node in ast.walk(ast.parse(source)):
        if is_call(node, "os.getenv", "os.environ.get"):
            args = node.args
        elif isinstance(node, ast.Subscript) and ast.unparse(node.value) == "os.environ":
            if isinstance(node.ctx, ast.Load):
                args = [node.slice]
            else:
                continue
        else:
            continue
        name = args[0]
        assert isinstance(name, ast.Constant), f"line {node.lineno}: env var name must be a literal"
        default = args[1] if len(args) > 1 else None
        if default is None or (isinstance(default, ast.Constant) and default.value in ("", None)):
            required.add(name.value)
    return required


def gateway_config_keys(text, start=r"name: gateway-config"):
    """Top-level data keys of the gateway-config ConfigMap in an installer or manifest."""
    match = re.search(start + r".*?^data:\n(.*?)(?:^EOF$|^---$|\Z)", text, re.S | re.M)
    assert match, "gateway-config not found"
    return dict(re.findall(r'^  ([A-Z][A-Z0-9_]*): "?([^"\n]*)"?$', match.group(1), re.M))


def gateway_container_env(text):
    """Env var name to its block, for the gateway container's env: list."""
    section = text[text.index("- name: gateway\n"):]
    env = section[section.index("        env:\n"):section.index("        envFrom:\n")]
    blocks = re.split(r"^        - name: ", env, flags=re.M)[1:]
    return {block.split("\n", 1)[0]: block for block in blocks}


@pytest.fixture(scope="module")
def install_config():
    return gateway_config_keys(INSTALLER.read_text())


@pytest.fixture(scope="module")
def reference_config():
    return gateway_config_keys(REFERENCE_CONFIG.read_text())


@pytest.fixture(scope="module")
def container_env():
    return gateway_container_env(DEPLOYMENT.read_text())


# --- env vars ----------------------------------------------------------------


@pytest.mark.parametrize("source, expected", [
    ('os.getenv("NEW_VAR")', {"NEW_VAR"}),
    ('os.getenv("NEW_VAR", "")', {"NEW_VAR"}),
    ('os.getenv("NEW_VAR", None)', {"NEW_VAR"}),
    ('os.environ.get("NEW_VAR")', {"NEW_VAR"}),
    ('os.environ["NEW_VAR"]', {"NEW_VAR"}),
    ('os.getenv("NEW_VAR", "x")', set()),
    ('int(os.getenv("NEW_VAR", "0"))', set()),
    ('os.environ["NEW_VAR"] = "x"', set()),
])
def test_the_env_scan_finds_required_reads(source, expected):
    assert required_env_vars(source) == expected


def test_the_env_scan_refuses_a_name_it_cant_read():
    with pytest.raises(AssertionError, match="must be a literal"):
        required_env_vars("os.getenv(name)")


def test_every_required_env_var_is_set(install_config, container_env):
    provided = set(install_config) | set(container_env) | set(OPTIONAL_WITHOUT_DEFAULT)

    missing = required_env_vars(MAIN_PY.read_text()) - provided

    assert not missing, f"main.py reads these with no default, and the deployment doesn't set them: {missing}"


def test_the_optional_list_has_no_leftovers():
    assert set(OPTIONAL_WITHOUT_DEFAULT) <= required_env_vars(MAIN_PY.read_text())


def test_explicit_body_limit_matches_the_gateway_default(install_config, reference_config):
    assert 'os.getenv("MAX_REQUEST_BODY_BYTES"' in MAIN_PY.read_text()
    assert int(install_config["MAX_REQUEST_BODY_BYTES"]) == main.config.MAX_REQUEST_BODY_BYTES
    assert int(reference_config["MAX_REQUEST_BODY_BYTES"]) == main.config.MAX_REQUEST_BODY_BYTES


def test_explicit_gguf_hosts_match_the_gateway_default(install_config, reference_config):
    assert 'os.getenv("GGUF_MODEL_ALLOWED_HOSTS"' in MAIN_PY.read_text()
    assert set(install_config["GGUF_MODEL_ALLOWED_HOSTS"].split(",")) == main.config.GGUF_MODEL_ALLOWED_HOSTS
    assert set(reference_config["GGUF_MODEL_ALLOWED_HOSTS"].split(",")) == main.config.GGUF_MODEL_ALLOWED_HOSTS


@pytest.mark.parametrize("config", ["install_config", "reference_config"])
def test_redis_url_holds_no_credentials(config, request):
    # main.py logs REDIS_URL. The password arrives separately as REDIS_PASSWORD.
    url = request.getfixturevalue(config)["REDIS_URL"]

    assert url.startswith("redis://")
    assert "@" not in url


def test_redis_password_comes_from_the_redis_secret(container_env):
    block = container_env["REDIS_PASSWORD"]

    assert re.search(r"secretKeyRef:\s+name: llmapi-redis-auth\s+key: password\b", block)


def test_postgres_password_comes_from_its_secret(container_env):
    block = container_env["POSTGRES_PASSWORD"]

    assert re.search(r"secretKeyRef:\s+name: llmapi-db\s+key: postgres-password\b", block)


def test_namespace_comes_from_the_pod(container_env):
    assert "fieldPath: metadata.namespace" in container_env["NAMESPACE"]


def test_config_reaches_the_container():
    text = DEPLOYMENT.read_text()

    assert re.search(r"envFrom:\s+- configMapRef:\s+name: gateway-config\b", text)


# --- probes ------------------------------------------------------------------


def test_probes_use_routes_that_exist():
    paths = re.findall(r"path: (/\S*)", DEPLOYMENT.read_text())
    routes = {route.path for route in main.app.routes}

    assert paths, "no probes found"
    assert set(paths) <= routes, f"probe paths with no route: {set(paths) - routes}"
    assert not set(paths) & {"/docs", "/redoc", "/openapi.json"}


def test_interactive_docs_stay_disabled():
    assert main.app.docs_url is None
    assert main.app.redoc_url is None


# --- packaging ---------------------------------------------------------------


@pytest.fixture(scope="module")
def shipped(tmp_path_factory):
    """Key to path for what ship_gateway_code really passes to kubectl."""
    tmp = tmp_path_factory.mktemp("ship")
    log = tmp / "kubectl.log"
    stub = tmp / "kubectl"
    stub.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >>"$LOG"\nexit 0\n')
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    script = 'source "$APP/lib/install-helpers.sh"; source "$APP/lib/gateway-code.sh"; ship_gateway_code "$APP"'
    subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script], check=True, timeout=30,
        env={**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "LOG": str(log), "APP": str(APP_DIR)},
    )
    return dict(re.findall(r"^--from-file=([^=\n]+)=(.+)$", log.read_text(), re.M))


def test_package_holds_the_app_and_its_lockfile(shipped):
    assert shipped == {
        "main.py": str(GATEWAY_DIR / "main.py"),
        "requirements.lock": str(GATEWAY_DIR / "requirements.lock"),
    }


def test_every_packaged_key_is_used_by_the_pod(shipped):
    text = DEPLOYMENT.read_text()

    assert re.search(r"mountPath: /app/main\.py\s+subPath: main\.py", text)
    assert "-r /lock/requirements.lock" in text
    assert re.search(r"name: gateway-code\s+mountPath: /lock", text)
    assert set(shipped) == {"main.py", "requirements.lock"}


def test_every_file_in_the_gateway_directory_is_accounted_for(shipped):
    """A new runtime file fails here until it's packaged, or listed as not needed at runtime."""
    packaged = {Path(path).name for path in shipped.values()}

    unknown = [
        path.name for path in GATEWAY_DIR.iterdir()
        if path.name not in packaged
        and not (path.is_dir() and path.name in NOT_PACKAGED_DIRS)
        and not (path.is_file() and NOT_PACKAGED.match(path.name))
    ]

    assert not unknown, f"not in gateway-code and not known to be dev-only: {unknown}"


def test_tests_arent_packaged(shipped):
    assert not any("/tests/" in path for path in shipped.values())


def imported_top_level_modules():
    modules = set()
    for node in ast.walk(ast.parse(MAIN_PY.read_text())):
        if isinstance(node, ast.Import):
            modules |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.level == 0:
            modules.add(node.module.split(".")[0])
    return modules


def test_local_imports_are_packaged(shipped):
    local = {
        name for name in imported_top_level_modules()
        if (GATEWAY_DIR / f"{name}.py").exists() or (GATEWAY_DIR / name).is_dir()
    }

    # Only main.py is mounted at /app, so any local module would be missing in the pod.
    assert not local, f"main.py imports local modules the pod wouldn't have: {local}"


def test_third_party_imports_are_in_the_lockfile():
    lock = (GATEWAY_DIR / "requirements.lock").read_text().lower().replace("_", "-")
    third_party = imported_top_level_modules() - set(sys.stdlib_module_names)

    missing = [name for name in third_party if not re.search(rf"^{name.replace('_', '-')}==", lock, re.M)]

    assert third_party and not missing, f"imported but not pinned: {missing}"


def test_main_opens_no_relative_files():
    """Admin assets are embedded in main.py, and nothing else is mounted beside it."""
    opened = [
        ast.unparse(node) for node in ast.walk(ast.parse(MAIN_PY.read_text()))
        if isinstance(node, ast.Call) and ast.unparse(node.func) == "open"
        and node.args and isinstance(node.args[0], ast.Constant)
        and not str(node.args[0].value).startswith("/")
    ]

    assert not opened


def test_dockerfile_copies_what_gets_packaged(shipped):
    copied = set(re.findall(r"^COPY (\S+) ", DOCKERFILE.read_text(), re.M))

    assert copied == set(shipped)
