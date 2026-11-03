"""S19 and S5 for manage-keys.sh, run for real against a real PostgreSQL.

kubectl is a stub placed first on PATH. It routes psql to the local test database
and runs the script's Redis command in a local shell with a fake redis-cli, so the
exact shell snippet the script would send into the pod is what executes.
"""

import os
import re
import stat
import subprocess
from pathlib import Path

import pytest

from conftest import PRE_HASHING_SCHEMA, RAW_KEY
import main

SCRIPT = Path(__file__).resolve().parents[2] / "manage-keys.sh"
LEGACY_KEY = "sk-mynodeone-" + "d4" * 16
REDIS_PASSWORD = "redis-s3cret"

KUBECTL_STUB = r"""#!/bin/bash
case "$1" in
    get)
        [ "$2" = namespace ] && exit 0
        if [ "$2" = secret ]; then
            [ -n "${FAKE_REDIS_PASSWORD:-}" ] || exit 1
            printf '%s' "$FAKE_REDIS_PASSWORD" | base64
            exit 0
        fi
        exit 1
        ;;
    exec)
        target=""
        while [ "$1" != "--" ]; do
            case "$1" in deploy/*) target="$1" ;; esac
            shift
        done
        shift
        case "$target" in
            deploy/llmapi-postgres)
                shift 5  # psql -U llmapi -d llmapi
                exec "$FAKE_PG_BIN/psql" -h "$FAKE_PG_HOST" -U postgres -d postgres -v ON_ERROR_STOP=1 "$@" </dev/null
                ;;
            deploy/redis)
                PATH="$FAKE_POD_BIN:$PATH" exec "$@"
                ;;
        esac
        ;;
esac
exit 1
"""

REDIS_CLI_STUB = r"""#!/bin/bash
case "${FAKE_REDIS_MODE:-ok}" in
    down) echo "Could not connect to Redis" >&2; exit 1 ;;
    noauth) echo "NOAUTH Authentication required."; exit 0 ;;
esac
printf 'auth=%s args=%s\n' "${REDISCLI_AUTH:-<none>}" "$*" >> "$FAKE_REDIS_LOG"
echo 1
"""


def write_executable(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class ManageKeys:
    def __init__(self, db, tmp_path):
        self.db = db
        self.redis_log = tmp_path / "redis.log"
        self.redis_log.touch()
        host_bin = tmp_path / "host-bin"
        pod_bin = tmp_path / "pod-bin"
        host_bin.mkdir()
        pod_bin.mkdir()
        write_executable(host_bin / "kubectl", KUBECTL_STUB)
        write_executable(pod_bin / "redis-cli", REDIS_CLI_STUB)
        self.env = {
            **os.environ,
            "PATH": f"{host_bin}:{os.environ['PATH']}",
            "FAKE_PG_BIN": db.bin_dir,
            "FAKE_PG_HOST": db.socket_dir,
            "FAKE_POD_BIN": str(pod_bin),
            "FAKE_REDIS_LOG": str(self.redis_log),
            "FAKE_REDIS_PASSWORD": REDIS_PASSWORD,
        }

    def __call__(self, *args, stdin="", **extra_env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            input=stdin, capture_output=True, text=True, timeout=60,
            env={**self.env, **extra_env},
        )

    def redis_calls(self):
        return self.redis_log.read_text().splitlines()

    def add_hashed(self, raw_key, name="hashed-key"):
        self.db.sql(
            f"INSERT INTO api_keys (api_key, key_prefix, name) "
            f"VALUES ('{main.hash_api_key(raw_key)}', '{main.api_key_display_prefix(raw_key)}', '{name}');"
        )
        return main.hash_api_key(raw_key)


@pytest.fixture
def cli(db, tmp_path):
    db.sql("ALTER TABLE api_keys ADD COLUMN key_prefix VARCHAR(32);")
    return ManageKeys(db, tmp_path)


def raw_key_in(output):
    return re.search(r"Key:\s+(sk-mynodeone-[0-9a-f]{32})\b", output).group(1)


# --- create and list ----------------------------------------------------------


def test_create_stores_only_the_hash_and_prints_the_key_once(cli, db):
    result = cli("create", "--name", "my-app", "--scopes", "inference,metrics")

    assert result.returncode == 0, result.stdout + result.stderr
    raw_key = raw_key_in(result.stdout)
    rows = db.rows("SELECT api_key, key_prefix, name, scopes FROM api_keys")
    assert rows == [{
        "api_key": main.hash_api_key(raw_key),
        "key_prefix": raw_key[:20],
        "name": "my-app",
        "scopes": ["inference", "metrics"],
    }]
    assert raw_key not in str(rows)
    assert main.hash_api_key(raw_key) in result.stdout


def test_create_output_matches_the_gateways_hash_and_prefix_functions(cli, db):
    raw_key = raw_key_in(cli("create", "--name", "app").stdout)

    row = db.rows("SELECT api_key, key_prefix FROM api_keys")[0]

    assert row["api_key"] == main.hash_api_key(raw_key)
    assert row["key_prefix"] == main.api_key_display_prefix(raw_key)


def test_name_with_a_quote_is_stored_literally(cli, db):
    hostile = "O'Brien'); DROP TABLE api_keys; --"

    assert cli("create", "--name", hostile).returncode == 0

    assert db.rows("SELECT name FROM api_keys") == [{"name": hostile}]


def test_create_reports_a_database_failure(cli, db):
    db.sql("ALTER TABLE api_keys ADD CONSTRAINT refuse_inserts CHECK (false) NOT VALID;")

    result = cli("create", "--name", "x")

    assert result.returncode == 1
    assert "failed to store" in result.stdout
    assert "sk-mynodeone-" not in result.stdout, "must not hand out a key that wasn't stored"


def test_list_shows_prefixes_and_never_raw_keys(cli, db):
    cli.add_hashed(RAW_KEY)
    db.sql(f"INSERT INTO api_keys (api_key, name) VALUES ('{LEGACY_KEY}', 'pending');")

    output = cli("list").stdout

    assert RAW_KEY[:20] + "..." in output
    assert LEGACY_KEY[:20] + "..." in output
    assert RAW_KEY not in output
    assert LEGACY_KEY not in output


def test_list_full_shows_key_ids_and_never_raw_keys(cli, db):
    key_id = cli.add_hashed(RAW_KEY)
    db.sql(f"INSERT INTO api_keys (api_key, name) VALUES ('{LEGACY_KEY}', 'pending');")

    output = cli("list", "--full").stdout

    assert key_id in output
    assert "pending migration" in output
    assert RAW_KEY not in output
    assert LEGACY_KEY not in output


def test_list_omits_revoked_keys(cli, db):
    key_id = cli.add_hashed(RAW_KEY)
    db.sql(f"UPDATE api_keys SET revoked = TRUE WHERE api_key = '{key_id}';")

    assert RAW_KEY[:20] not in cli("list").stdout


# --- commands taking a key ----------------------------------------------------


@pytest.mark.parametrize("reference", ["raw", "id", "prefix", "prefix..."])
def test_show_finds_a_key_by_any_reference(cli, reference):
    key_id = cli.add_hashed(RAW_KEY)
    typed = {"raw": RAW_KEY, "id": key_id, "prefix": RAW_KEY[:20], "prefix...": RAW_KEY[:20] + "..."}[reference]

    result = cli("show", typed)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "hashed-key" in result.stdout
    assert RAW_KEY not in result.stdout


def test_show_of_a_row_awaiting_migration_hides_the_raw_key(cli, db):
    db.sql(f"INSERT INTO api_keys (api_key, name) VALUES ('{LEGACY_KEY}', 'pending');")

    result = cli("show", LEGACY_KEY)

    assert result.returncode == 0
    assert "pending" in result.stdout
    assert LEGACY_KEY not in result.stdout


def test_ambiguous_prefix_is_refused(cli, db):
    cli.add_hashed(RAW_KEY)
    other = RAW_KEY[:20] + "ffff"
    cli.add_hashed(other)
    db.sql(f"UPDATE api_keys SET key_prefix = '{RAW_KEY[:20]}';")

    result = cli("revoke", RAW_KEY[:20], stdin="y\n")

    assert result.returncode == 1
    assert "more than one key" in result.stdout
    assert db.rows("SELECT 1 FROM api_keys WHERE revoked") == []


@pytest.mark.parametrize("command", ["show", "revoke", "usage", "update"])
def test_key_reference_cannot_inject_sql(cli, db, command):
    key_id = cli.add_hashed(RAW_KEY)
    hostile = "x'; UPDATE api_keys SET revoked = TRUE; --"

    args = [command, hostile] + (["--name", "n"] if command == "update" else [])
    result = cli(*args, stdin="y\n")

    assert result.returncode == 1
    assert "invalid API key format" in result.stdout
    assert db.rows(f"SELECT revoked FROM api_keys WHERE api_key = '{key_id}'") == [{"revoked": False}]


@pytest.mark.parametrize("command", ["show", "revoke", "usage", "update"])
def test_missing_key_argument_is_a_usage_error(cli, command):
    result = cli(command)

    assert result.returncode == 1
    assert "API key required" in result.stdout


def test_unknown_key_is_reported(cli):
    result = cli("show", "sk-mynodeone-doesnotexist")

    assert result.returncode == 1
    assert "not found" in result.stdout


def test_usage_reads_usage_recorded_under_the_id(cli, db):
    key_id = cli.add_hashed(RAW_KEY)
    db.sql(f"INSERT INTO usage_logs (api_key, date, hour, input_tokens, output_tokens, requests) "
           f"VALUES ('{key_id}', CURRENT_DATE, 3, 11, 22, 4);")

    result = cli("usage", RAW_KEY[:20] + "...")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Input tokens:    11" in result.stdout
    assert "Output tokens:   22" in result.stdout
    assert RAW_KEY not in result.stdout


def test_update_changes_the_row_and_evicts_the_cache(cli, db):
    key_id = cli.add_hashed(RAW_KEY)

    result = cli("update", key_id, "--name", "it's new", "--scopes", "metrics")

    assert result.returncode == 0, result.stdout + result.stderr
    assert db.rows("SELECT name, scopes FROM api_keys") == [{"name": "it's new", "scopes": ["metrics"]}]
    assert cli.redis_calls() == [f"auth={REDIS_PASSWORD} args=DEL apikey:{key_id}"]


def test_update_succeeds_with_a_warning_when_redis_is_down(cli, db):
    key_id = cli.add_hashed(RAW_KEY)

    result = cli("update", key_id, "--name", "new", FAKE_REDIS_MODE="down")

    assert result.returncode == 0
    assert "within 5 minutes" in result.stdout
    assert db.rows("SELECT name FROM api_keys") == [{"name": "new"}]


# --- revoke -------------------------------------------------------------------


def test_revoke_marks_the_row_and_evicts_the_cache(cli, db):
    key_id = cli.add_hashed(RAW_KEY)

    result = cli("revoke", key_id, stdin="y\n")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Revoked" in result.stdout
    assert db.rows("SELECT revoked FROM api_keys") == [{"revoked": True}]
    assert cli.redis_calls() == [f"auth={REDIS_PASSWORD} args=DEL apikey:{key_id}"]


def test_revoke_can_be_cancelled(cli, db):
    key_id = cli.add_hashed(RAW_KEY)

    assert cli("revoke", key_id, stdin="n\n").returncode == 0

    assert db.rows("SELECT revoked FROM api_keys") == [{"revoked": False}]
    assert cli.redis_calls() == []


def test_revoke_by_raw_key_also_removes_a_pre_upgrade_cache_entry(cli):
    key_id = cli.add_hashed(RAW_KEY)

    assert cli("revoke", RAW_KEY, stdin="y\n").returncode == 0

    assert cli.redis_calls() == [f"auth={REDIS_PASSWORD} args=DEL apikey:{key_id} apikey:{RAW_KEY}"]


def test_revoke_of_a_row_awaiting_migration_covers_both_cache_entries(cli, db):
    db.sql(f"INSERT INTO api_keys (api_key, name) VALUES ('{LEGACY_KEY}', 'pending');")

    result = cli("revoke", LEGACY_KEY[:20] + "...", stdin="y\n")

    assert result.returncode == 0, result.stdout + result.stderr
    assert LEGACY_KEY not in result.stdout
    args = cli.redis_calls()[0].split("args=DEL ")[1].split()
    assert set(args) == {f"apikey:{LEGACY_KEY}", f"apikey:{main.hash_api_key(LEGACY_KEY)}"}
    assert db.rows("SELECT revoked FROM api_keys") == [{"revoked": True}]


def test_revoke_works_on_a_redis_without_auth(cli):
    key_id = cli.add_hashed(RAW_KEY)

    result = cli("revoke", key_id, stdin="y\n", FAKE_REDIS_PASSWORD="")

    assert result.returncode == 0, result.stdout + result.stderr
    assert cli.redis_calls() == [f"auth=<none> args=DEL apikey:{key_id}"]


def test_redis_password_stays_out_of_the_command_line(cli):
    key_id = cli.add_hashed(RAW_KEY)

    cli("revoke", key_id, stdin="y\n")

    args = cli.redis_calls()[0].split("args=")[1]
    assert REDIS_PASSWORD not in args


@pytest.mark.parametrize("mode", ["down", "noauth"])
def test_revoke_fails_loudly_when_the_cache_cannot_be_evicted(cli, db, mode):
    key_id = cli.add_hashed(RAW_KEY)

    result = cli("revoke", key_id, stdin="y\n", FAKE_REDIS_MODE=mode)

    assert result.returncode == 1
    assert "could not remove the key from the Redis cache" in result.stdout
    assert "within 5 minutes" in result.stdout
    assert db.rows("SELECT revoked FROM api_keys") == [{"revoked": True}], "still revoked at the source"


def test_revoked_key_cannot_be_revoked_again(cli, db):
    key_id = cli.add_hashed(RAW_KEY)
    db.sql(f"UPDATE api_keys SET revoked = TRUE WHERE api_key = '{key_id}';")

    result = cli("revoke", key_id, stdin="y\n")

    assert result.returncode == 1
    assert "already revoked" in result.stdout


# --- deployment order ---------------------------------------------------------


def test_commands_refuse_to_run_before_the_gateway_has_migrated(cli, db):
    db.sql(PRE_HASHING_SCHEMA)
    db.sql(f"INSERT INTO api_keys (api_key, name) VALUES ('{LEGACY_KEY}', 'legacy');")

    for args in (("create", "--name", "x"), ("list",), ("show", LEGACY_KEY)):
        result = cli(*args)
        assert result.returncode == 1
        assert "Deploy the updated gateway first" in result.stdout

    assert db.rows("SELECT api_key FROM api_keys") == [{"api_key": LEGACY_KEY}]


def test_help_works_without_touching_the_database(cli, db):
    db.sql("ALTER TABLE api_keys DROP COLUMN key_prefix;")

    result = cli("help")

    assert result.returncode == 0
    assert "Usage:" in result.stdout
