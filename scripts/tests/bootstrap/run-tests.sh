#!/bin/bash
###############################################################################
# Tests for the cluster bootstrap, the backup and sudo scripts, and the monitoring
# config. They run the real scripts against stubs and temp dirs: no root, no cluster,
# and nothing outside the temp dirs is touched.
#
#   bash scripts/tests/bootstrap/run-tests.sh [name-filter]
#
# Needs python3 with PyYAML. chart_test also needs helm and the network, and promql_test
# needs promtool or the promql-parser package. Whatever a test can't run without makes
# it skip, and say why. In CI (CI=true) a skip is a failure, so coverage can't silently
# disappear from there.
###############################################################################

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"
PYTHON="${PYTHON:-python3}"
PASSED=()
FAILED=()
SKIPPED=()

for name in key_retention_test audit_sim audit_check_test backup_sudo_test helm_install_test edge_checksum_test flannel_monitor_test velero_alerts_test worker_test chart_test promql_test versions_test lint; do
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        continue
    fi
    echo "=== $name"
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$HERE/$name.py"
    case $? in
        0) PASSED+=("$name") ;;
        77) SKIPPED+=("$name") ;;
        *) FAILED+=("$name") ;;
    esac
    echo
done

echo "bootstrap: ${#PASSED[@]} passed, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"
if ((${#SKIPPED[@]})); then
    echo "skipped: ${SKIPPED[*]}"
    if [[ -n "${CI:-}" ]]; then
        echo "CI requires every test to run"
        exit 1
    fi
fi
if ((${#FAILED[@]})); then
    echo "failed: ${FAILED[*]}"
    exit 1
fi
