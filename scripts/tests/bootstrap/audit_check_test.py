#!/usr/bin/env python3
"""check-audit-policy.sh and the two scripts that call it, against policy fixtures only.
Nothing here reads the machine's real policy."""
import os, pathlib, stat, subprocess, sys, tempfile, textwrap
repo = str(pathlib.Path(__file__).resolve().parents[3])
script = repo + "/scripts/setup/check-audit-policy.sh"
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok

if not os.path.exists(script):
    print("FAIL", script, "does not exist")
    sys.exit(1)

base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
HEAD = "apiVersion: audit.k8s.io/v1\nkind: Policy\n"

def run_policy(text):
    p = os.path.join(base, "policy.yaml")
    open(p, "w").write(text)
    return subprocess.run(["bash", script, p], capture_output=True, text=True)

SAFE, UNSAFE, UNKNOWN = 0, 1, 2
cases = [
    ("the policy that shipped in base", UNSAFE, """
rules:
  # Log admin actions
  - level: RequestResponse
    users: ["system:admin", "admin"]
  # Log secret access
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods"]
  - level: Metadata
"""),
    ("Metadata for Secrets first shadows a later catch-all", SAFE, """
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: RequestResponse
"""),
    ("None for Secrets first shadows it too", SAFE, """
rules:
  - level: None
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: RequestResponse
"""),
    ("a catch-all at Metadata stops the walk", SAFE, """
rules:
  - level: Metadata
  - level: RequestResponse
"""),
    ("Metadata limited to a user doesn't shield anyone else", UNSAFE, """
rules:
  - level: Metadata
    users: [alice]
    resources:
      - group: ""
        resources: ["secrets"]
  - level: RequestResponse
"""),
    ("Metadata limited to some verbs doesn't either", UNSAFE, """
rules:
  - level: Metadata
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["secrets"]
  - level: Request
"""),
    ("Metadata limited to some names doesn't either", UNSAFE, """
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
        resourceNames: ["one"]
  - level: RequestResponse
"""),
    ("RequestResponse scoped to an apps resource is fine", SAFE, """
rules:
  - level: RequestResponse
    resources:
      - group: apps
        resources: ["deployments"]
  - level: Metadata
"""),
    ("RequestResponse on another core resource is fine", SAFE, """
rules:
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods"]
"""),
    ("nonResourceURLs only can't match a Secret", SAFE, """
rules:
  - level: RequestResponse
    nonResourceURLs: ["/healthz*"]
  - level: Metadata
"""),
    ("no rule matches Secrets at all", SAFE, """
rules:
  - level: Request
    resources:
      - group: apps
"""),
    ("Request on Secrets", UNSAFE, """
rules:
  - level: Request
    resources:
      - group: ""
        resources: ["secrets"]
"""),
    ("RequestResponse scoped to Secrets by a user", UNSAFE, """
rules:
  - level: RequestResponse
    users: ["admin"]
    resources:
      - group: ""
        resources: ["secrets"]
"""),
    ("verbs limit doesn't make Request safe", UNSAFE, """
rules:
  - level: Request
    verbs: ["create"]
    resources:
      - group: ""
        resources: ["secrets"]
"""),
    ("wildcard resource in the core group", UNSAFE, """
rules:
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["*"]
"""),
    ("core group with no resources list means all of it", UNSAFE, """
rules:
  - level: Request
    resources:
      - group: ""
"""),
    ("a missing group is the core group", UNSAFE, """
rules:
  - level: Request
    resources:
      - resources: ["secrets"]
"""),
    ("wildcard group", UNSAFE, """
rules:
  - level: Request
    resources:
      - group: "*"
        resources: ["secrets"]
"""),
    ("an apps wildcard doesn't reach Secrets", SAFE, """
rules:
  - level: Request
    resources:
      - group: apps
        resources: ["*"]
"""),
    ("empty resources list means everything", UNSAFE, """
rules:
  - level: Request
    resources: []
"""),
    ("block lists, unindented, with quotes and comments", UNSAFE, """
rules:
- level: 'RequestResponse'   # a comment
  users:
  - admin
  resources:
  - group: ''
    resources:
    - pods
    - "secrets"
"""),
    ("a dash on its own line", UNSAFE, """
rules:
  -
    level: Request
    resources:
      -
        group: ""
        resources:
          - secrets
"""),
    ("a second group entry is the one that matches", UNSAFE, """
rules:
  - level: Request
    resources:
      - group: apps
        resources: ["deployments"]
      - group: ""
        resources: ["pods", "secrets"]
"""),
    ("a commented-out dangerous rule", SAFE, """
rules:
  # - level: RequestResponse
  - level: Metadata
"""),
    ("# inside quotes isn't a comment", SAFE, """
rules:
  - level: Metadata
    users: ["a#b"]
    resources:
      - group: apps
  - level: Metadata
"""),
    ("keys after rules are still read", SAFE, """
rules:
  - level: Metadata
omitStages:
  - RequestReceived
"""),
    ("no rules at all", UNKNOWN, "rules:\n"),
    ("no rules key", UNKNOWN, "metadata: {}\n"),
    ("not a policy", UNKNOWN, "hello\n"),
    ("a rule with no level", UNKNOWN, """
rules:
  - users: ["a"]
"""),
    ("a misspelled level", UNKNOWN, """
rules:
  - level: Metadta
"""),
    ("an unknown rule key", UNKNOWN, """
rules:
  - level: Metadata
    sometimes: true
"""),
    ("flow mappings", UNKNOWN, """
rules:
  - level: Metadata
    resources: [{group: "", resources: ["secrets"]}]
"""),
    ("a flow rules list", UNKNOWN, """
rules: [{level: RequestResponse}]
"""),
    ("anchors and aliases", UNKNOWN, """
rules:
  - level: &lvl RequestResponse
  - level: *lvl
"""),
    ("tabs", UNKNOWN, "rules:\n\t- level: Metadata\n"),
    ("two documents", UNKNOWN, "rules:\n  - level: Metadata\n---\nrules:\n  - level: RequestResponse\n"),
]
for name, want, text in cases:
    r = run_policy(HEAD + text.lstrip("\n"))
    check("%s: exit %d" % (name, want), r.returncode == want, "got %d: %s%s" % (r.returncode, r.stdout, r.stderr))

r = subprocess.run(["bash", script, repo + "/manifests/security/audit-policy.yaml"], capture_output=True, text=True)
check("the repo's policy is safe", r.returncode == 0, r.stdout + r.stderr)
r = subprocess.run(["bash", script, base + "/missing.yaml"], capture_output=True, text=True)
check("an unreadable policy can't be verified", r.returncode == 2, r.stdout + r.stderr)

# The warning has to be something the operator can act on
r = run_policy(HEAD + 'rules:\n  - level: RequestResponse\n    users: ["admin"]\n')
msg = r.stderr
for piece in ("rule 1 logs at level RequestResponse", "sudo cp -a", "sudo install -m 644 " + repo + "/manifests/security/audit-policy.yaml",
              "sudo systemctl restart k3s", "k3s-audit-*", "truncate -s 0 /var/log/k3s-audit.log", "Rotate"):
    check("warning has: " + piece, piece in msg, msg)

# It reads and doesn't write
p = os.path.join(base, "policy.yaml")
before = (open(p).read(), os.stat(p).st_mtime_ns)
d = os.path.join(base, "ro"); os.makedirs(d)
open(d + "/p.yaml", "w").write(open(p).read())
os.chmod(d + "/p.yaml", 0o444); os.chmod(d, 0o555)
r = subprocess.run(["bash", script, d + "/p.yaml"], capture_output=True, text=True)
check("works on a read-only file and directory", r.returncode == 1, r.stderr)
os.chmod(d, 0o755)

# --- the callers. Functions are cut from the real scripts, with paths into a temp dir.
def function(path, name):
    out, on = [], False
    for line in open(path):
        if line.startswith(name + "() {"):
            on = True
        if on:
            out.append(line)
            if line.startswith("}"):
                return "".join(out)
    return ""

def bootstrap_run(policy_text):
    t = tempfile.mkdtemp(dir=base)
    open(t + "/audit-policy.yaml", "w").write(policy_text)
    os.chmod(t + "/audit-policy.yaml", 0o640)
    before = os.stat(t + "/audit-policy.yaml").st_mtime_ns
    bindir = t + "/bin"; os.makedirs(bindir)
    for tool in ("systemctl", "install", "cp", "k3s"):
        open(bindir + "/" + tool, "w").write('#!/bin/bash\necho "%s $*" >> "%s/calls.log"\n' % (tool, t))
        os.chmod(bindir + "/" + tool, 0o755)
    prog = 'set -euo pipefail\n' \
        'log_info() { echo "INFO $*"; }; log_success() { echo "OK $*"; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERROR $*"; }\n' \
        'K3S_CONFIG_DIR="%s"; PROJECT_ROOT="%s"\n%s\nprepare_audit_config\necho REACHED_END\n' % (
            t, repo, function(repo + "/scripts/installation/bootstrap-control-plane.sh", "prepare_audit_config"))
    r = subprocess.run(["bash", "-c", prog], env=dict(os.environ, PATH=bindir + ":/usr/bin:/bin"), capture_output=True, text=True)
    return r, t, before

UNSAFE_POLICY = HEAD + 'rules:\n  - level: RequestResponse\n    users: ["admin"]\n'
r, t, before = bootstrap_run(UNSAFE_POLICY)
out = r.stdout + r.stderr
check("bootstrap re-run: unsafe policy warns loudly", "CAN WRITE SECRET VALUES" in out, out)
check("bootstrap re-run: unsafe policy doesn't stop the run", r.returncode == 0 and "REACHED_END" in r.stdout, out)
check("bootstrap re-run: policy file untouched", open(t + "/audit-policy.yaml").read() == UNSAFE_POLICY and os.stat(t + "/audit-policy.yaml").st_mtime_ns == before)
check("bootstrap re-run: nothing restarted or installed", not os.path.exists(t + "/calls.log"))

r, t, _ = bootstrap_run(HEAD + "rules:\n  - level: Metadata\n")
check("bootstrap re-run: safe policy stays quiet", "SECRET VALUES" not in r.stdout + r.stderr and r.returncode == 0, r.stdout + r.stderr)

fn = function(repo + "/scripts/setup/enable-security-hardening.sh", "enable_audit_logging")
t = tempfile.mkdtemp(dir=base)
open(t + "/check-audit-policy.sh", "w").write('echo "CHECK_CALLED $*"; exit 1\n')
prog = 'set -euo pipefail\nlog_info() { echo "INFO $*"; }; log_success() { echo "OK $*"; }; log_warn() { echo "WARN $*"; }\nSCRIPT_DIR="%s"\n%s\nenable_audit_logging\necho REACHED_END\n' % (t, fn)
r = subprocess.run(["bash", "-c", prog], capture_output=True, text=True)
check("hardening script runs the check, and carries on", "CHECK_CALLED" in r.stdout and "REACHED_END" in r.stdout and r.returncode == 0, r.stdout + r.stderr)

subprocess.run(["rm", "-rf", base])
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
