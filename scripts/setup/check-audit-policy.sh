#!/bin/bash

###############################################################################
# Checks whether a Kubernetes audit policy can write Secret bodies to the audit log.
# This only reads the policy, and changes nothing.
#
#   check-audit-policy.sh [POLICY]     Default: /etc/rancher/k3s/audit-policy.yaml
#
# Exit codes:
#   0  Secrets are only logged as metadata, or not at all
#   1  A Request or RequestResponse rule can match Secrets. Prints how to fix it.
#   2  Could not tell: unreadable, or YAML this parser doesn't handle
#
# Rules apply in order and the first match wins, so a rule only leaks if nothing above
# it catches Secrets first. A rule limited to some users or verbs doesn't count as
# safe in either direction: it can leak for those users, and it can't shield the
# rules below it from everyone else.
#
# Uses awk because PyYAML isn't guaranteed on a node. Anything it doesn't recognise is
# exit 2, never "safe".
###############################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFE_POLICY="$(cd "$SCRIPT_DIR/../.." && pwd)/manifests/security/audit-policy.yaml"
POLICY="${1:-/etc/rancher/k3s/audit-policy.yaml}"

if [ ! -r "$POLICY" ]; then
    echo "[WARN] Could not read the audit policy, so it was not checked: $POLICY" >&2
    exit 2
fi

parser=$(cat <<'AWK'
function error(msg) { if (err == "") err = msg " (line " NR ")" }
function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
function unquote(s) {
    s = trim(s)
    if (length(s) >= 2 && (s ~ /^".*"$/ || s ~ /^\047.*\047$/)) s = substr(s, 2, length(s) - 2)
    return s
}
# Removes a comment: a # outside quotes, at the start or after a space.
function decomment(s,   i, c, q, out) {
    q = ""; out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = "" }
        else if (c == "\"" || c == "\047") q = c
        else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
        out = out c
    }
    return out
}
# Loads a value into items[]. An empty value means a block list follows.
function parse_list(v,   parts, n, i, item) {
    item_count = 0
    v = trim(v)
    if (v == "") return 1
    if (v !~ /^\[.*\]$/ || v ~ /[{}]/) { error("not a list this parser handles: " v); return 0 }
    v = substr(v, 2, length(v) - 2)
    n = split(v, parts, ",")
    for (i = 1; i <= n; i++) {
        item = unquote(parts[i])
        if (item != "") items[++item_count] = item
    }
    return 1
}
function covers_secrets(r) { return r == "secrets" || r ~ /^secrets\// || r ~ /^\*/ }
function close_entry() {
    if (!in_entry) return
    if ((entry_group == "" || entry_group == "*") && (entry_res_count == 0 || entry_res_covers)) {
        rule_res_covers = 1
        if (entry_names) rule_scoped = 1
    }
    in_entry = 0
}
function close_rule(   covers) {
    if (!in_rule) return
    close_entry()
    in_rule = 0
    rule_count++
    if (rule_level !~ /^(None|Metadata|Request|RequestResponse)$/) {
        error("rule " rule_count " has no valid level")
        return
    }
    if (decided != "") return
    covers = rule_res_count > 0 ? rule_res_covers : !rule_nonres
    if (!covers) return
    if (rule_level == "Request" || rule_level == "RequestResponse") {
        decided = "unsafe"
        unsafe_rule = rule_count
        unsafe_level = rule_level
    } else if (!rule_scoped) {
        decided = "safe"
    }
}
function start_rule() {
    close_rule()
    in_rule = 1; rule_level = ""; rule_scoped = 0; rule_nonres = 0
    rule_res_count = 0; rule_res_covers = 0; rule_key_ind = -1; list_key = ""
}
function start_entry() {
    close_entry()
    in_entry = 1; entry_group = ""; entry_res_count = 0; entry_res_covers = 0
    entry_names = 0; entry_key_ind = -1; entry_list = ""
}
function note_list_items(key, count,   i) {
    if (key == "users" || key == "userGroups" || key == "verbs" || key == "namespaces") {
        if (count > 0) rule_scoped = 1
    } else if (key == "nonResourceURLs") {
        if (count > 0) rule_nonres = 1
    }
}
function rule_key(text,   key, value, sep) {
    sep = index(text, ":")
    if (sep == 0) { error("expected a key: " text); return }
    key = trim(substr(text, 1, sep - 1))
    value = trim(substr(text, sep + 1))
    list_key = ""
    in_resources = 0
    if (key == "level") {
        rule_level = unquote(value)
    } else if (key == "users" || key == "userGroups" || key == "verbs" || key == "namespaces" || key == "nonResourceURLs" || key == "omitStages") {
        if (parse_list(value)) {
            note_list_items(key, item_count)
            if (value == "") list_key = key
        }
    } else if (key == "omitManagedFields") {
        # Doesn't affect what's logged about Secrets.
    } else if (key == "resources") {
        if (value == "") in_resources = 1
        else if (value != "[]") error("a flow-style resources list isn't handled")
    } else {
        error("unknown rule key: " key)
    }
}
function entry_key(text,   key, value, sep, i) {
    sep = index(text, ":")
    if (sep == 0) { error("expected a key: " text); return }
    key = trim(substr(text, 1, sep - 1))
    value = trim(substr(text, sep + 1))
    entry_list = ""
    if (key == "group") {
        entry_group = unquote(value)
    } else if (key == "resources" || key == "resourceNames") {
        if (!parse_list(value)) return
        if (value == "") entry_list = key
        else for (i = 1; i <= item_count; i++) entry_item(key, items[i])
    } else {
        error("unknown resources key: " key)
    }
}
function entry_item(key, value) {
    if (key == "resources") {
        entry_res_count++
        if (covers_secrets(value)) entry_res_covers = 1
    } else {
        entry_names = 1
    }
}
function top_key(text,   key, value, sep) {
    sep = index(text, ":")
    if (sep == 0) { error("expected a key: " text); return }
    key = trim(substr(text, 1, sep - 1))
    value = trim(substr(text, sep + 1))
    if (key == "rules") {
        if (seen_rules) { error("rules appears twice"); return }
        seen_rules = 1
        if (value != "") { error("a flow-style rules list isn't handled"); return }
        in_rules = 1
        item_ind = -1
    } else if (key != "apiVersion" && key != "kind" && key != "metadata" && key != "omitStages" && key != "omitManagedFields") {
        error("unknown top-level key: " key)
    }
}
# A key on the same line as its dash: returns the text, and sets dash_key_ind.
function after_dash(text, ind,   rest) {
    rest = substr(text, 2)
    match(rest, /^ */)
    dash_key_ind = ind + 1 + RLENGTH
    return substr(rest, RLENGTH + 1)
}
BEGIN { top_ind = -1; docs = 0 }
{
    line = decomment($0)
    sub(/[ \t\r]+$/, "", line)
    if (line == "") next
    match(line, /^[ \t]*/)
    lead = substr(line, 1, RLENGTH)
    if (lead ~ /\t/) { error("a tab in the indentation"); next }
    ind = RLENGTH
    text = substr(line, ind + 1)

    if (text == "---" || text == "...") {
        if (text == "---" && seen_rules) error("more than one YAML document")
        next
    }
    if (text ~ /(^|: |- )[&*!|>]/ || text ~ /^<</) { error("YAML anchors, tags and block scalars aren't handled"); next }

    if (in_rules && ind <= top_ind && text !~ /^-( |$)/) {
        close_rule()
        in_rules = 0
    }
    if (!in_rules) {
        if (top_ind < 0) top_ind = ind
        if (ind == top_ind) top_key(text)
        next
    }

    # A new rule: a dash at the rules list's own indent
    if (text ~ /^-( |$)/ && (item_ind < 0 || ind == item_ind)) {
        item_ind = ind
        start_rule()
        text = after_dash(text, ind)
        if (text != "") { rule_key_ind = dash_key_ind; rule_key(text) }
        next
    }
    if (!in_rule) { error("unexpected text under rules: " text); next }
    if (rule_key_ind < 0) rule_key_ind = ind

    # Inside the rule's resources list
    if (in_resources && ind >= rule_key_ind) {
        if (text ~ /^-( |$)/ && (!in_entry || ind == entry_dash_ind)) {
            start_entry()
            entry_dash_ind = ind
            rule_res_count++
            text = after_dash(text, ind)
            if (text != "") { entry_key_ind = dash_key_ind; entry_key(text) }
            next
        }
        if (in_entry && ind > entry_dash_ind) {
            if (entry_key_ind < 0) entry_key_ind = ind
            if (text ~ /^-( |$)/ && entry_list != "" && ind >= entry_key_ind) {
                entry_item(entry_list, unquote(substr(text, 2)))
                next
            }
            if (ind == entry_key_ind && text !~ /^-( |$)/) { entry_key(text); next }
            error("unexpected indentation in resources: " text)
            next
        }
        if (ind > rule_key_ind) { error("unexpected indentation in resources: " text); next }
    }

    if (list_key != "" && ind >= rule_key_ind && text ~ /^-( |$)/) {
        note_list_items(list_key, 1)
        next
    }
    if (ind == rule_key_ind) {
        close_entry()
        rule_key(text)
        next
    }
    error("unexpected indentation in a rule: " text)
}
END {
    close_rule()
    if (rule_count == 0 && err == "") err = "no rules found"
    if (decided == "unsafe") print "unsafe\t" unsafe_rule "\t" unsafe_level
    else if (err != "") print "unknown\t" err
    else print "safe"
}
AWK
)

verdict=$(LC_ALL=C awk "$parser" "$POLICY")
status=$?
if [ "$status" -ne 0 ] || [ -z "$verdict" ]; then
    echo "[WARN] Could not check the audit policy: $POLICY" >&2
    exit 2
fi

IFS=$'\t' read -r result detail level <<< "$verdict"
case "$result" in
    safe)
        echo "[OK] Audit policy logs Secrets as metadata only: $POLICY"
        exit 0
        ;;
    unknown)
        echo "[WARN] Could not verify the audit policy, so assume it may log Secret bodies: $POLICY" >&2
        echo "[WARN] Reason: $detail" >&2
        echo "[WARN] Compare it with $SAFE_POLICY" >&2
        exit 2
        ;;
esac

cat >&2 <<EOF

[WARN] ================================================================================
[WARN] THE AUDIT POLICY CAN WRITE SECRET VALUES TO THE AUDIT LOG
[WARN] $POLICY: rule $detail logs at level $level, and it matches Secrets.
[WARN] Anyone who can read the audit log, or a copy of it, can read those values.
[WARN] Nothing was changed. Replacing the policy restarts the API server, so it's left
[WARN] to you, in a maintenance window. Run these on the control plane:
[WARN]
[WARN]   1. Back up the current policy:
[WARN]      sudo cp -a $POLICY $POLICY.bak
[WARN]   2. Install the safe policy:
[WARN]      sudo install -m 644 $SAFE_POLICY $POLICY
[WARN]   3. Restart k3s, which restarts the API server:
[WARN]      sudo systemctl restart k3s
[WARN]   4. Purge the logs written under the old policy, including rotated ones:
[WARN]      sudo find /var/log -maxdepth 1 -name 'k3s-audit-*' -delete
[WARN]      sudo truncate -s 0 /var/log/k3s-audit.log
[WARN]      Also delete any copies shipped elsewhere, such as a log server.
[WARN]   5. Rotate any credentials that may be in those logs: every Secret created, changed
[WARN]      or read by a user that rule matches, for as long as the policy was in place.
[WARN] ================================================================================

EOF
exit 1
