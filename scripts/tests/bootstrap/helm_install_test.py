#!/usr/bin/env python3
"""helm_install_safe, cut from the bootstrap, against a stub helm and kubectl. The stub
kubectl always reports Running pods, which is what a re-run sees before an upgrade."""
import os, pathlib, re, subprocess, sys, tempfile
repo = str(pathlib.Path(__file__).resolve().parents[3])
boot = repo + "/scripts/installation/bootstrap-control-plane.sh"
source = open(boot).read()
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok

def function(name, text=source):
    m = re.search(r"^%s\(\) \{.*?^\}" % re.escape(name), text, re.S | re.M)
    return m.group(0) if m else ""

base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
def stub(d, name, body):
    p = os.path.join(d, name)
    open(p, "w").write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)

REAL_SLEEP = subprocess.run(["bash", "-c", "command -v sleep"], capture_output=True, text=True).stdout.strip()

def run(name, helm_seconds=0, helm_rc=0, status="deployed", args='--set "a=b c"'):
    t = os.path.join(base, name); os.makedirs(t)
    log = t + "/helm.log"
    # Records every call and any signal. A slow helm is the case that used to get killed.
    stub(t, "helm", '''
if [ "$1" = status ]; then echo "STATUS: %s"; exit 0; fi
for a in "$@"; do printf '[%%s]' "$a" >> "%s"; done; echo >> "%s"
trap 'echo SIGTERM >> "%s"; exit 143' TERM
%s %s & wait $!
echo finished >> "%s"
exit %d
''' % (status, log, log, log, REAL_SLEEP, helm_seconds, log, helm_rc))
    stub(t, "kubectl", 'echo "app-0  1/1  Running  0  5m"; echo "bad-0  0/1  ImagePullBackOff  0  1m"')
    # Time goes fast for the function's own polling, and not for the helm stub.
    stub(t, "sleep", "%s 0.05" % REAL_SLEEP)
    prog = 'set -euo pipefail\nlog_info() { echo "INFO $*"; }; log_success() { echo "OK $*"; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERROR $*"; }\n' \
        + function("helm_install_safe") + '\nrc=0; helm_install_safe rel chart/x ns %s || rc=$?; echo "RC=$rc"\n' % args
    r = subprocess.run(["bash", "-c", prog], env=dict(os.environ, PATH=t + ":/usr/bin:/bin", TMPDIR=t), capture_output=True, text=True, timeout=120)
    return r, open(log).read() if os.path.exists(log) else ""

check("the wrapper still exists", function("helm_install_safe") != "")

# The reviewer's case: an upgrade still running when the old pods are Running
r, log = run("slow", helm_seconds=3)
check("slow upgrade: helm isn't killed", "SIGTERM" not in log and "finished" in log, log + r.stdout)
check("slow upgrade: its success is reported", "RC=0" in r.stdout, r.stdout + r.stderr)

r, log = run("failed", helm_seconds=2, helm_rc=7)
check("failed upgrade with Running pods: helm's exit code comes back", "RC=7" in r.stdout, r.stdout + r.stderr)
check("failed upgrade: helm got to finish", "SIGTERM" not in log and "finished" in log, log)
check("failed upgrade: says so", "helm exited with code 7" in r.stdout, r.stdout)
check("failed upgrade: shows pods that aren't ready", "ImagePullBackOff" in r.stdout, r.stdout)
check("failed upgrade: no claim of success", "installed successfully" not in r.stdout, r.stdout)

r, log = run("pending", helm_rc=1, status="pending-upgrade")
check("stuck release: says how to get out of it", "helm rollback rel -n ns" in r.stdout, r.stdout)

r, log = run("args")
call = log.splitlines()[0]
check("uses upgrade --install with wait and a timeout", "[upgrade][--install][rel][chart/x][--namespace][ns][--wait][--timeout][10m]" in call, call)
check("an argument with a space stays one argument", "[--set][a=b c]" in call, call)
fn = function("helm_install_safe")
check("no predictable temp log", "/tmp/" not in fn, fn)
check("no kill", not re.search(r"^\s*kill\b", fn, re.M), fn)

# The callers: Running pods are not a way out of a failed install
mon = function("install_monitoring") or source
check("kube-prometheus-stack caller doesn't look for Running pods", 'grep -q "Running"' not in function("install_monitoring"), "")

argo = function("install_argocd")
fail_branch = argo[argo.index("helm_install_safe"):] if "helm_install_safe" in argo else ""
check("ArgoCD: the manifest fallback is only for no release", "helm status argocd" in fail_branch and fail_branch.index("helm status argocd") < fail_branch.index("kubectl apply"), fail_branch[:400])

# A failure the install continued past still has to show up at the end
m = re.search(r"^main\(\) \{.*?^\}", source, re.S | re.M)
main = m.group(0)
check("main exits non-zero when a component failed", re.search(r'FAILED_COMPONENTS\[@\]\}" -gt 0.*?exit 1', main, re.S) is not None, "")
t = os.path.join(base, "component"); os.makedirs(t)
prog = "set -euo pipefail\ndeclare -a FAILED_COMPONENTS=()\n" + function("component_failed") + '\ncomponent_failed a; component_failed b; component_failed a; echo "${FAILED_COMPONENTS[*]}"\n'
r = subprocess.run(["bash", "-c", prog], capture_output=True, text=True)
check("failed components are listed once each", r.stdout.strip() == "a b", r.stdout + r.stderr)

# --- answering no twice about credentials must not stop the install (backup timer comes after)
t = os.path.join(base, "creds"); os.makedirs(t)
stub(t, "kubectl", "exit 1")
prog = "set -euo pipefail\nlog_info() { echo \"INFO $*\"; }; log_success() { echo \"OK $*\"; }; log_warn() { echo \"WARN $*\"; }; log_error() { echo \"ERROR $*\"; }\n" \
    + 'SCRIPT_DIR=/x; PROJECT_ROOT=/x; ACTUAL_HOME=%s; ACTUAL_USER=me; TAILSCALE_IP=1.2.3.4; CLUSTER_DOMAIN=c; ARGOCD_PASSWORD=p; GRAFANA_PASSWORD=p; UNATTENDED=0\n' % t \
    + "delete_credential_files() { echo DELETED; }\n" \
    + function("display_credentials") + "\ndisplay_credentials\necho REACHED_END\n"
r = subprocess.run(["bash", "-c", prog], input="n\nn\nn\nn\nn\n", env=dict(os.environ, PATH=t + ":/usr/bin:/bin"), capture_output=True, text=True, timeout=60)
check("credentials answered no twice: keeps going", r.returncode == 0 and "REACHED_END" in r.stdout, r.stdout[-400:] + r.stderr[-400:])
check("credentials answered no twice: warns, doesn't delete", "security risk" in r.stdout + r.stderr and "DELETED" not in r.stdout, r.stdout[-400:])

subprocess.run(["rm", "-rf", base])
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
