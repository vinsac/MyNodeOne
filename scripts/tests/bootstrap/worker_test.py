#!/usr/bin/env python3
"""Worker kubeconfig handling, fetch role choice, flannel UFW check and apply-monitoring, all stubbed."""
import glob, os, pathlib, re, shutil, stat, subprocess, sys, tempfile
try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed")
    sys.exit(77)
repo = str(pathlib.Path(__file__).resolve().parents[3])
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok
def stub(d, name, body):
    p = os.path.join(d, name)
    open(p, "w").write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)
base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))

# ---------- configure_kubectl_worker
src = open(repo + "/scripts/nodes/add-worker-node.sh").read()
a = src.index("# Remove the setup-only kubeconfig when this script ends")
b = src.index("label_node() {\n")
func = src[a:b]

def worker(name, has_user_config=False, ssh_ok=True, kubectl_ok=True):
    t = os.path.join(base, "w_" + name)
    os.makedirs(t + "/bin"); os.makedirs(t + "/run"); os.makedirs(t + "/home/.kube")
    if has_user_config:
        open(t + "/home/.kube/config", "w").write("user config\n")
    log = t + "/calls.log"
    stub(t + "/bin", "sudo", 'echo "sudo $*" >> "%s"\nshift 2\n"$@"' % log)   # sudo -u USER cmd
    stub(t + "/bin", "ssh", 'echo "ssh $*" >> "%s"\n%s' % (log, 'echo "server: https://127.0.0.1:6443"; exit 0' if ssh_ok else 'exit 1'))
    stub(t + "/bin", "kubectl", 'echo "kubectl KUBECONFIG=$KUBECONFIG $*" >> "%s"\nexit %d' % (log, 0 if kubectl_ok else 1))
    stub(t + "/bin", "sleep", "exit 0")
    h = t + "/h.sh"
    body = func.replace("/run/mynodeone-setup-kubeconfig", t + "/run/mynodeone-setup-kubeconfig")
    body = body.replace("/var/lib/rancher/k3s/agent", t + "/agent")
    open(h, "w").write("#!/bin/bash\nset -euo pipefail\nlog_info(){ echo \"I $1\"; }\nlog_success(){ echo \"OK $1\"; }\nlog_warn(){ echo \"W $1\"; }\nlog_error(){ echo \"E $1\"; }\n"
        + body + '\nconfigure_kubectl_worker\n'
        'echo "EXPORTED=$KUBECONFIG"\n'
        'if [ -f "$KUBECONFIG" ]; then echo "MODE=$(stat -c %a "$KUBECONFIG")"; echo "CONTENT=$(cat "$KUBECONFIG" | head -c 200)"; fi\n')
    env = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", ACTUAL_HOME=t + "/home", ACTUAL_USER="tester",
               CONTROL_PLANE_IP="100.64.0.1", CONTROL_PLANE_SSH_USER="cp")
    env.pop("KUBECONFIG", None)
    return subprocess.run(["bash", h], env=env, capture_output=True, text=True), t

r, t = worker("fetch")
check("worker: fetch exits 0", r.returncode == 0, r.stdout + r.stderr)
check("worker: exports temp path", "EXPORTED=" + t + "/run/mynodeone-setup-kubeconfig." in r.stdout, r.stdout)
check("worker: temp mode 600", "MODE=600" in r.stdout, r.stdout)
check("worker: server rewritten to control plane IP", "https://100.64.0.1:6443" in r.stdout, r.stdout)
check("worker: temp removed on exit", not glob.glob(t + "/run/*"), glob.glob(t + "/run/*"))
check("worker: nothing written to user's .kube", not os.path.exists(t + "/home/.kube/config") and not glob.glob(t + "/home/.kube/*"))

r, t = worker("existing", has_user_config=True)
check("worker: existing working config kept and used", "EXPORTED=" + t + "/home/.kube/config" in r.stdout and open(t + "/home/.kube/config").read() == "user config\n", r.stdout)
check("worker: warns about kept credentials", "shred -u" in r.stdout, r.stdout)
check("worker: no temp created when config already works", not glob.glob(t + "/run/*"))

r, t = worker("nofetch", ssh_ok=False)
check("worker: ssh failure with no local certs returns failure and cleans up", r.returncode != 0 and not glob.glob(t + "/run/*"), r.stdout + r.stderr)
check("worker: nothing written to user's .kube after failure", not glob.glob(t + "/home/.kube/*"))

# fallback path using local certs
t = os.path.join(base, "w_fallback_pre")
r, t = worker("fallback0", ssh_ok=False)  # create the tree
os.makedirs(t + "/agent")
for f in ["server-ca.crt", "client-kubelet.crt", "client-kubelet.key"]:
    open(t + "/agent/" + f, "w").write("x")
env = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", ACTUAL_HOME=t + "/home", ACTUAL_USER="tester",
           CONTROL_PLANE_IP="100.64.0.1", CONTROL_PLANE_SSH_USER="cp")
env.pop("KUBECONFIG", None)
r = subprocess.run(["bash", t + "/h.sh"], env=env, capture_output=True, text=True)
check("worker: fallback uses temp file, cleans up", r.returncode == 0 and "certificate-authority-data" in r.stdout and not glob.glob(t + "/run/*"), r.stdout + r.stderr)
check("worker: fallback writes nothing to .kube", not glob.glob(t + "/home/.kube/*"))

# ---------- want_admin_kubeconfig
fsrc = open(repo + "/scripts/lib/fetch-cluster-info.sh").read()
a = fsrc.index("# Prints yes or no\nwant_admin_kubeconfig()")
b = fsrc.index("fetch_cluster_info() {")
fn = fsrc[a:b]
for role, typ, want in [("Management Workstation", "", "yes"), ("Worker Node", "", "no"), ("VPS Edge Node", "", "no"),
                        ("", "management", "yes"), ("", "worker", "no"), ("", "edge", "no"), ("", "", "no"), ("Something", "", "no")]:
    env = dict(os.environ, NODE_ROLE=role, NODE_TYPE=typ)
    r = subprocess.run(["bash", "-c", fn + "\nwant_admin_kubeconfig"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    check("fetch: NODE_ROLE=%r NODE_TYPE=%r -> %s" % (role, typ, want), r.stdout.strip() == want, r.stdout + r.stderr)

# Remote script with WANT_KUBECONFIG: extract the kubeconfig block and run it with a stub sudo
m = re.search(r'echo "===KUBECONFIG_START==="\nif \[ "\$\{WANT_KUBECONFIG:-no\}" = "yes" \]; then\n.*?\nfi\necho "===KUBECONFIG_END==="\n', fsrc, re.S)
check("fetch: quoted remote block found", bool(m))
t = os.path.join(base, "f"); os.makedirs(t + "/bin")
stub(t + "/bin", "sudo", 'echo "kubeconfig-from-$2"')
for want, expect_body in [("yes", True), ("no", False)]:
    env = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", WANT_KUBECONFIG=want)
    r = subprocess.run(["bash", "-c", m.group(0)], env=env, capture_output=True, text=True)
    body = r.stdout.replace("===KUBECONFIG_START===", "").replace("===KUBECONFIG_END===", "").strip()
    check("fetch: remote WANT_KUBECONFIG=%s %s" % (want, "sends config" if expect_body else "sends nothing"), bool(body) == expect_body, r.stdout)
r = subprocess.run(["bash", "-c", fsrc[fsrc.index("    local kubeconfig_b64=$(sed -n"):].split("\n")[0].replace("local ", "") + '\necho "ok[$kubeconfig_b64]"'],
                   env=dict(os.environ, temp_output="/dev/null"), capture_output=True, text=True)

# Empty marker block, under the script's own shell options, must not abort
t2 = t + "/out"; open(t2, "w").write("===KUBECONFIG_START===\n===KUBECONFIG_END===\n")
r = subprocess.run(["bash", "-c", 'set -euo pipefail\nf(){ local temp_output="$1"\nlocal kubeconfig_b64=$(sed -n \'/===KUBECONFIG_START===/,/===KUBECONFIG_END===/p\' "$temp_output" | grep -v "===" | tr -d \'\\r\\n\')\necho "after[$kubeconfig_b64]"; }\nf "$0"', t2], capture_output=True, text=True)
check("fetch: empty kubeconfig block does not abort under set -e", r.returncode == 0 and "after[]" in r.stdout, r.stdout + r.stderr)

# ---------- flannel check_ufw
fl = open(repo + "/scripts/validation/monitor-flannel-health.sh").read()
m = re.search(r'^(check_\w*ufw\w*)\(\) \{.*?^\}\n', fl, re.S | re.M)
check("flannel: UFW check function found", bool(m))
GOOD = "Status: active\nDefault: deny (incoming), allow (outgoing), allow (routed)\nAnywhere on tailscale0     ALLOW       Anywhere\n"
def flannel(status, name):
    t = os.path.join(base, "fl_" + name); os.makedirs(t + "/bin")
    open(t + "/s", "w").write(status)
    stub(t + "/bin", "ufw", 'cat "%s/s"' % t)
    stub(t + "/bin", "command", "exit 0")
    h = 'log_info(){ echo "I $1"; }\nlog_warn(){ echo "W $1"; }\nlog_success(){ echo "OK $1"; }\nlog_error(){ echo "E $1"; }\n' + m.group(0) + "\n" + m.group(1) + '\necho "rc=$?"'
    return subprocess.run(["bash", "-c", h], env=dict(os.environ, PATH=t + "/bin:/usr/bin:/bin"), capture_output=True, text=True)
r = flannel(GOOD, "good")
check("flannel: correct after 8472 rule removed", "rc=0" in r.stdout, r.stdout + r.stderr)
r = flannel(GOOD + "8472/udp    ALLOW   Anywhere\n", "old")
check("flannel: old open rule warns, not an error", "rc=0" in r.stdout and "ufw delete allow 8472/udp" in r.stdout, r.stdout)
r = flannel("Status: active\nDefault: deny (incoming), allow (outgoing), allow (routed)\n", "bad")
check("flannel: missing tailscale0 rule is an issue", "rc=1" in r.stdout, r.stdout)
check("flannel: no --fix advice", "--fix" not in fl)

# ---------- apply-monitoring-config
t = os.path.join(base, "am"); os.makedirs(t + "/bin")
log = t + "/calls.log"
for c in ["kubectl", "helm"]:
    stub(t + "/bin", c, 'printf "%s" "%s"; printf " [%%s]" "$@" >> "%s"; echo >> "%s"' % ("", "", log, log) if False else 'echo "%s $*" >> "%s"' % (c, log))
script = repo + "/scripts/monitoring/apply-monitoring-config.sh"
env = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", ALERTMANAGER_VALUES_FILE=t + "/none", KUBECONFIG="/dev/null")
r = subprocess.run(["bash", script], env=env, capture_output=True, text=True)
c = open(log).read()
check("apply: exit 0", r.returncode == 0, r.stdout + r.stderr)
check("apply: labels namespace first", c.splitlines()[0].startswith("kubectl label --overwrite namespace monitoring pod-security.kubernetes.io/enforce=privileged"), c)
check("apply: applies rules dir", "scripts/monitoring/prometheus-alerts/" in c)
check("apply: helm keeps chart version", "--version 65.8.0" in c, c)
check("apply: helm reuses values", "--reuse-values" in c, c)
check("apply: no destination, no extra values", "alertmanager-values" not in c and "No alert destination" in r.stdout, c)
check("apply: never uses install or kube-context", "helm install" not in c and "--kube-context" not in c, c)
os.unlink(log)
open(t + "/am.yaml", "w").write("alertmanager: {}\n")
r = subprocess.run(["bash", script], env=dict(env, ALERTMANAGER_VALUES_FILE=t + "/am.yaml"), capture_output=True, text=True)
check("apply: destination file passed last", ("-f " + t + "/am.yaml") in open(log).read(), open(log).read())
os.unlink(log)
r = subprocess.run(["bash", script, "--rules-only"], env=env, capture_output=True, text=True)
check("apply: --rules-only skips helm", "helm" not in open(log).read())

# ---------- configure-longhorn-backups does nothing without a target
t = os.path.join(base, "lh"); os.makedirs(t + "/bin"); log = t + "/calls.log"
stub(t + "/bin", "kubectl", 'echo "kubectl $*" >> "%s"' % log)
e = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin"); e.pop("LONGHORN_BACKUP_TARGET", None)
r = subprocess.run(["bash", repo + "/scripts/backup/configure-longhorn-backups.sh"], env=e, capture_output=True, text=True)
check("longhorn backups: no target, no cluster change", not os.path.exists(log) or not re.search(r"apply|patch", open(log).read()), r.stdout + r.stderr)
print("   exit", r.returncode, "|", (r.stdout + r.stderr).strip().splitlines()[0] if (r.stdout + r.stderr).strip() else "")

# ---------- the RecurringJob names itself in its spec
stub(t + "/bin", "kubectl", 'if [ "${1:-}" = apply ]; then cat > "%s/applied.yaml"; fi; echo "kubectl $*" >> "%s"' % (t, log))
e = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", LONGHORN_BACKUP_TARGET="s3://b@r/", LONGHORN_BACKUP_CREDENTIAL_SECRET="s")
r = subprocess.run(["bash", repo + "/scripts/backup/configure-longhorn-backups.sh"], env=e, capture_output=True, text=True)
job = next(yaml.safe_load_all(open(t + "/applied.yaml")))
check("longhorn backups: RecurringJob spec has a name", job["kind"] == "RecurringJob" and job["spec"].get("name") == job["metadata"]["name"], str(job) + r.stderr)

shutil.rmtree(base)
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
