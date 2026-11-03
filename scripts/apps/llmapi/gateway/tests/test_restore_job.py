"""The script in scripts/backup/llmapi-postgres-restore-job.yaml, run as written, against a
real PostgreSQL and a real dump. Only the connection settings differ from the Job's."""

import os
import subprocess
from pathlib import Path

import pytest

MANIFEST = Path(__file__).resolve().parents[4] / "backup" / "llmapi-postgres-restore-job.yaml"
SCRATCH = "llmapi_restore_test"


def job_script():
    lines = MANIFEST.read_text().splitlines()
    start = lines.index("        args:") + 2
    indent = len(lines[start]) - len(lines[start].lstrip())
    script = []
    for line in lines[start:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        script.append(line[indent:])
    return "\n".join(script) + "\n"


@pytest.fixture
def restore(db, tmp_path):
    env = {
        **os.environ,
        "PATH": f"{db.bin_dir}:{os.environ['PATH']}",
        "PGHOST": db.socket_dir,
        "PGUSER": "postgres",
        "BACKUP_DIR": str(tmp_path),
    }
    db.sql(f"DROP DATABASE IF EXISTS {SCRATCH};")
    db.sql("CREATE TABLE restore_probe (id int PRIMARY KEY, label text); INSERT INTO restore_probe VALUES (1, 'kept');")
    subprocess.run(
        ["pg_dump", "--format=custom", "--dbname=postgres", f"--file={tmp_path}/test.dump", "--table=restore_probe"],
        check=True, env=env, capture_output=True, timeout=60,
    )
    db.sql("DROP TABLE restore_probe;")

    def run(target=SCRATCH, overwrite="no", dump="test.dump"):
        return subprocess.run(
            ["sh", "-c", job_script()],
            env={**env, "DUMP_FILE": dump, "TARGET_DB": target, "OVERWRITE_LIVE": overwrite},
            capture_output=True, text=True, timeout=60,
        )

    def query(sql):
        return subprocess.run(
            ["psql", "-At", "-d", SCRATCH, "-c", sql], env=env, capture_output=True, text=True, timeout=60,
        ).stdout.strip()

    run.query = query
    yield run
    db.sql(f"DROP DATABASE IF EXISTS {SCRATCH};")


def test_scratch_restore_creates_the_database_and_the_data_is_queryable(restore):
    result = restore()

    assert result.returncode == 0, result.stderr
    assert restore.query("SELECT label FROM restore_probe") == "kept"


def test_restoring_into_the_scratch_database_again_works(restore):
    assert restore().returncode == 0
    result = restore()

    assert result.returncode == 0, result.stderr
    assert restore.query("SELECT count(*) FROM restore_probe") == "1"


def test_overwriting_the_live_database_needs_the_explicit_flag(restore):
    result = restore(target="llmapi")

    assert result.returncode == 1
    assert "OVERWRITE_LIVE=yes" in result.stderr


def test_placeholders_left_in_are_refused(restore):
    assert restore(dump="DUMP_FILE_PLACEHOLDER").returncode == 1


def test_unsafe_database_name_is_refused(restore):
    assert restore(target="x;drop").returncode == 1


def test_missing_dump_fails(restore):
    assert restore(dump="not-there.dump").returncode != 0
