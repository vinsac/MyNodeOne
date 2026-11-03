#!/bin/bash
# The NetworkPolicy allows the traffic the pods need and nothing else. This evaluates the
# rules against the manifests in Python: no CNI enforces anything here. See
# check_networkpolicy.py.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox

if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "PyYAML is needed to run this test"
    exit 2
fi

CHECK="$LLMAPI_DIR/tests/check_networkpolicy.py"
POLICY="$LLMAPI_DIR/manifests/networkpolicy.yaml"

python3 "$CHECK"
STATUS=$?
assert_equals "the policies in the repo pass" "$STATUS" 0

# Usage: broken_policy <description> <python expression over docs, returning the new list>
# A check that can't fail proves nothing, so each of these has to be caught.
broken_policy() {
    python3 - "$POLICY" "$SANDBOX/broken.yaml" "$2" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as f:
    docs = [d for d in yaml.safe_load_all(f) if d]
named = {d["metadata"]["name"]: d for d in docs}
docs = eval(sys.argv[3], {"docs": docs, "named": named})
with open(sys.argv[2], "w") as f:
    yaml.safe_dump_all(docs, f)
PY
    python3 "$CHECK" --networkpolicy "$SANDBOX/broken.yaml" >"$SANDBOX/broken.out" 2>&1
    if [ $? -eq 1 ]; then pass "caught: $1"; else fail "not caught: $1" "$(cat "$SANDBOX/broken.out")"; fi
}

broken_policy "no rule for the backup jobs" \
    '[d for d in docs if d["metadata"]["name"] != "postgres-allow-backup"]'
broken_policy "backup rule on the wrong port" \
    '[named["postgres-allow-backup"]["spec"]["ingress"][0]["ports"][0].update(port=5433) or d for d in docs]'
broken_policy "backup rule with the wrong label" \
    '[named["postgres-allow-backup"]["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"].update(app="other") or d for d in docs]'
broken_policy "Postgres open to any source" \
    '[named["postgres-allow-backup"]["spec"]["ingress"][0].pop("from") and d for d in docs]'
broken_policy "no default deny" \
    '[d for d in docs if d["metadata"]["name"] != "default-deny-ingress"]'
broken_policy "gateway rule limited to pods, which would cut the public path" \
    '[named["gateway-allow-http"]["spec"]["ingress"][0].update({"from": [{"podSelector": {}}]}) or d for d in docs]'
broken_policy "an egress policy" \
    'docs + [{"kind": "NetworkPolicy", "metadata": {"name": "e", "namespace": "llmapi"}, "spec": {"podSelector": {}, "policyTypes": ["Egress"]}}]'

finish
