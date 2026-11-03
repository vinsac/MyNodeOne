"""lib/install-helpers.sh against a real PostgreSQL: the installer never stores a raw key.

kubectl is a stub that routes psql to the local test database and logs its arguments, so
what's checked is the exact SQL the helper sends, and what any process could see of it.
"""

import asyncio
import os
import subprocess
from pathlib import Path

import pytest
from fastapi.security import HTTPAuthorizationCredentials

from conftest import RAW_KEY
from test_manage_keys import KUBECTL_STUB, write_executable
import main

HELPERS = Path(__file__).resolve().parents[2] / "lib" / "install-helpers.sh"
ENSURE_KEY = r"""
source "$HELPERS"
status=0
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_FILE" || status=$?
printf 'status=%s\nstate=%s\n' "$status" "$ENSURED_KEY_STATE"
"""


class Installer:
    def __init__(self, db, tmp_path):
        self.db = db
        self.argv_log = tmp_path / "kubectl-argv.log"
        self.key_file = tmp_path / "keys" / "admin"
        host_bin = tmp_path / "host-bin"
        host_bin.mkdir()
        logged = KUBECTL_STUB.replace("#!/bin/bash\n", '#!/bin/bash\necho "$*" >>"$FAKE_ARGV_LOG"\n', 1)
        write_executable(host_bin / "kubectl", logged)
        self.env = {
            **os.environ,
            "PATH": f"{host_bin}:{os.environ['PATH']}",
            "FAKE_PG_BIN": db.bin_dir,
            "FAKE_PG_HOST": db.socket_dir,
            "FAKE_ARGV_LOG": str(self.argv_log),
            "HELPERS": str(HELPERS),
            "KEY_FILE": str(self.key_file),
            "NAMESPACE": "llmapi",
            "API_KEY_RETRY_SLEEP": "0",
            "API_KEY_SCHEMA_ATTEMPTS": "2",
        }

    def ensure_key(self):
        result = subprocess.run(
            ["bash", "-c", ENSURE_KEY], capture_output=True, text=True, timeout=60, env=self.env
        )
        self.output = result.stdout + result.stderr
        return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

    def argv(self):
        return self.argv_log.read_text() if self.argv_log.exists() else ""


@pytest.fixture
def installer(db, tmp_path):
    return Installer(db, tmp_path)


@pytest.fixture
def gateway_schema(db, gateway, monkeypatch):
    """Creates and migrates the tables with the gateway's own code, as its startup does."""
    monkeypatch.setattr(gateway.config, "POSTGRES_HOST", db.socket_dir)
    monkeypatch.setattr(gateway.config, "POSTGRES_USER", "postgres")
    monkeypatch.setattr(gateway.config, "POSTGRES_DB", "postgres")
    monkeypatch.setattr(gateway.config, "POSTGRES_PASSWORD", "")

    def run(scenario=None):
        async def wrapped():
            client = gateway.PostgresClient()
            await client.connect()
            monkeypatch.setattr(gateway, "postgres_client", client)
            try:
                if scenario:
                    return await scenario(client)
            finally:
                await client.close()
        return asyncio.run(wrapped())
    return run


def drop_tables(db):
    db.sql("DROP TABLE IF EXISTS api_keys, usage_logs CASCADE;")


def test_fresh_install_stores_only_the_hash(installer, db, gateway_schema):
    drop_tables(db)
    gateway_schema()

    assert installer.ensure_key() == {"status": "0", "state": "new"}

    raw_key = installer.key_file.read_text().strip()
    rows = db.rows("SELECT api_key, key_prefix, name, scopes FROM api_keys")
    assert rows == [{
        "api_key": main.hash_api_key(raw_key),
        "key_prefix": main.api_key_display_prefix(raw_key),
        "name": "admin-ui",
        "scopes": ["admin"],
    }]
    assert raw_key not in str(rows)


def test_raw_key_stays_out_of_argv_and_output(installer, db, gateway_schema):
    drop_tables(db)
    gateway_schema()

    installer.ensure_key()

    raw_key = installer.key_file.read_text().strip()
    assert "INSERT INTO api_keys" in installer.argv()
    assert raw_key not in installer.argv()
    assert raw_key not in installer.output
    assert oct(installer.key_file.stat().st_mode & 0o777) == "0o600"


def test_the_gateway_accepts_the_key_the_installer_made(installer, db, gateway, gateway_schema, fake_redis):
    drop_tables(db)
    gateway_schema()
    installer.ensure_key()
    raw_key = installer.key_file.read_text().strip()
    credentials = HTTPAuthorizationCredentials(scheme="Bearer", credentials=raw_key)

    async def authenticate(client):
        key_id = await gateway.get_api_key(credentials)
        return key_id, await client.get_api_key_config(key_id)

    key_id, key_config = gateway_schema(authenticate)

    assert key_id == main.hash_api_key(raw_key)
    assert key_config["scopes"] == ["admin"]


def test_no_tables_yet_creates_nothing_rather_than_failing_late(installer, db):
    drop_tables(db)

    assert installer.ensure_key() == {"status": "1", "state": "unknown"}

    assert not installer.key_file.exists()
    assert "INSERT" not in installer.argv()


def test_old_schema_without_the_hash_column_creates_nothing(installer, db):
    """The table of a gateway version from before hashing. A plaintext insert would fit."""
    assert installer.ensure_key() == {"status": "1", "state": "unknown"}

    assert db.rows("SELECT api_key FROM api_keys") == []
    assert "INSERT" not in installer.argv()


def test_rerun_after_the_gateway_came_up_creates_the_key(installer, db, gateway_schema):
    drop_tables(db)
    assert installer.ensure_key()["state"] == "unknown"

    gateway_schema()

    assert installer.ensure_key()["state"] == "new"
    assert len(db.rows("SELECT api_key FROM api_keys")) == 1


def test_rerun_with_a_hashed_key_and_no_local_file_doesnt_mint_or_guess(installer, db, gateway_schema):
    drop_tables(db)
    gateway_schema()
    installer.ensure_key()
    installer.key_file.unlink()

    assert installer.ensure_key()["state"] == "elsewhere"

    assert not installer.key_file.exists()
    assert len(db.rows("SELECT api_key FROM api_keys")) == 1


def test_plaintext_row_is_gone_once_the_gateway_has_migrated(installer, db, gateway_schema):
    """An upgrade: the older installer's row is hashed before the helper reads it."""
    db.sql(f"INSERT INTO api_keys (api_key, name, scopes) VALUES ('{RAW_KEY}', 'admin-ui', '{{admin}}');")
    gateway_schema()

    assert installer.ensure_key()["state"] == "elsewhere"

    rows = db.rows("SELECT api_key FROM api_keys")
    assert rows == [{"api_key": main.hash_api_key(RAW_KEY)}]


def test_rerun_with_the_files_key_active_reuses_it(installer, db, gateway_schema):
    drop_tables(db)
    gateway_schema()
    installer.ensure_key()

    assert installer.ensure_key()["state"] == "reused"
    assert installer.key_file.read_text().strip() not in installer.argv()


def test_key_file_left_from_an_earlier_install_isnt_used(installer, db, gateway_schema):
    drop_tables(db)
    gateway_schema()
    installer.ensure_key()
    current = installer.key_file.read_text()
    installer.key_file.write_text("sk-mynodeone-from-an-earlier-install\n")

    assert installer.ensure_key()["state"] == "stale"

    assert len(db.rows("SELECT api_key FROM api_keys")) == 1
    assert current not in installer.argv()
    assert installer.key_file.read_text() == "sk-mynodeone-from-an-earlier-install\n"
    assert "sk-mynodeone-from-an-earlier-install" not in installer.argv()


def test_key_file_of_a_revoked_key_isnt_used(installer, db, gateway_schema):
    drop_tables(db)
    gateway_schema()
    installer.ensure_key()
    db.sql("INSERT INTO api_keys (api_key, name, scopes) VALUES ('sha256:other', 'second-admin', '{admin}');")
    db.sql("UPDATE api_keys SET revoked = TRUE WHERE name = 'admin-ui';")

    assert installer.ensure_key()["state"] == "stale"
