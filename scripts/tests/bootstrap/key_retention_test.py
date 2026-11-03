#!/usr/bin/env python3
"""Runs bootstrap's key-retention functions against temp dirs with stubbed commands."""
import glob, os, pathlib, shutil, stat, subprocess, sys, tempfile, textwrap

repo = str(pathlib.Path(__file__).resolve().parents[3])
src = open(os.path.join(repo, "scripts/installation/bootstrap-control-plane.sh")).read()

start = src.index("# True if this file holds at least one encryption key.")
end = src.index("    # Wait for K3s to be ready\n    log_info \"Waiting for K3s to be ready...\"")
funcs = src[start:end] + "}\n"
fw_start = src.index("# Older installs opened 8472/udp to Anywhere.")
fw_end = src.index("optimize_system_for_containers() {")
funcs += src[fw_start:fw_end]

fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + detail) if detail and not ok else ""))
    if not ok:
        fails += 1

def stub(bin_dir, name, body):
    p = os.path.join(bin_dir, name)
    open(p, "w").write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)

def run(tmp, call="install_k3s", ufw_status="", env_extra=None):
    bin_dir = os.path.join(tmp, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    calls = os.path.join(tmp, "calls.log")
    for name in ["sudo", "kubectl", "systemctl", "ufw", "curl"]:
        body = 'echo "%s $*" >> "%s"' % (name, calls)
        if name == "ufw":
            body += '\nif [ "$1" = status ]; then cat "%s/ufw_status" 2>/dev/null; fi' % tmp
        if name == "systemctl":
            body += '\n[ "$1" = is-active ] && [ -f "%s/k3s_running" ] && exit 0\n[ "$1" = is-active ] && exit 3\nexit 0' % tmp
        if name == "curl":
            body += '\necho "exit 0"'
        stub(bin_dir, name, body)
    open(os.path.join(tmp, "ufw_status"), "w").write(ufw_status)
    harness = os.path.join(tmp, "harness.sh")
    open(harness, "w").write(textwrap.dedent("""\
        #!/bin/bash
        set -euo pipefail
        log_info() { echo "INFO $1"; }
        log_success() { echo "OK $1"; }
        log_warn() { echo "WARN $1"; }
        log_error() { echo "ERR $1"; }
        """) + funcs + "\n" + call + "\n")
    env = dict(os.environ)
    env.update({
        "PATH": bin_dir + ":/usr/bin:/bin",
        "K3S_CONFIG_DIR": os.path.join(tmp, "etc"),
        "K3S_DATA_DIR": os.path.join(tmp, "data"),
        "K3S_BINARY": os.path.join(tmp, "k3s"),
        "K3S_SERVICE_UNIT": os.path.join(tmp, "k3s.service"),
        "SECRETS_BACKUP_DIR": os.path.join(tmp, "backup"),
        "PROJECT_ROOT": repo,
        "NODE_NAME": "n1", "TAILSCALE_IP": "100.64.1.2", "K3S_VERSION": "v1.31.2+k3s1",
    })
    env.update(env_extra or {})
    r = subprocess.run(["bash", harness], env=env, capture_output=True, text=True)
    log = open(calls).read() if os.path.exists(calls) else ""
    return r, log

def mode(p):
    return stat.S_IMODE(os.stat(p).st_mode)

KEY = "apiVersion: apiserver.config.k8s.io/v1\nresources:\n  - providers:\n      - aescbc:\n          keys:\n            - name: key1\n              secret: ORIGINALKEY==\n"

base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
def scenario(name):
    d = os.path.join(base, name)
    os.makedirs(d + "/etc", exist_ok=True)
    return d

# 1 Fresh install
t = scenario("fresh")
r, log = run(t)
cfg = t + "/etc/encryption-config.yaml"
check("fresh: exit 0", r.returncode == 0, r.stdout + r.stderr)
check("fresh: key generated with mode 600", os.path.exists(cfg) and mode(cfg) == 0o600)
check("fresh: key backed up", len(glob.glob(t + "/backup/encryption-config-*.yaml")) == 1)
check("fresh: backup dir mode 700", mode(t + "/backup") == 0o700)
check("fresh: backup file mode 600", all(mode(f) == 0o600 for f in glob.glob(t + "/backup/*")))
check("fresh: installer ran", "curl -sfL https://get.k3s.io" in log)
conf = open(t + "/etc/config.yaml").read()
check("fresh: agent-token-file set", 'agent-token-file: "%s/etc/agent-token"' % t in conf)
check("fresh: agent token mode 600", mode(t + "/etc/agent-token") == 0o600)
check("fresh: agent token is 64 hex chars", len(open(t + "/etc/agent-token").read()) == 64)
check("fresh: nodeport-addresses set", 'nodeport-addresses=100.64.0.0/10' in conf)
check("fresh: flannel-iface set", 'flannel-iface: tailscale0' in conf)
aud = open(t + "/etc/audit-policy.yaml").read()
check("fresh: audit policy installed from repo", aud == open(repo + "/manifests/security/audit-policy.yaml").read())

# 2 Re-run on an existing cluster
t = scenario("rerun")
open(t + "/etc/encryption-config.yaml", "w").write(KEY); os.chmod(t + "/etc/encryption-config.yaml", 0o644)
open(t + "/etc/audit-policy.yaml", "w").write("custom-audit\n")
open(t + "/etc/pod-security-config.yaml", "w").write("custom-psa\n")
open(t + "/etc/config.yaml", "w").write("custom-config\nflannel-iface: tailscale0\n")
os.makedirs(t + "/data/server/db/etcd")
open(t + "/k3s", "w").write("#!/bin/true\n"); os.chmod(t + "/k3s", 0o755)
open(t + "/k3s.service", "w").write("x")
open(t + "/k3s_running", "w").write("x")
r, log = run(t)
check("rerun: exit 0", r.returncode == 0, r.stdout + r.stderr)
check("rerun: key byte-identical", open(t + "/etc/encryption-config.yaml").read() == KEY)
check("rerun: key tightened to 600", mode(t + "/etc/encryption-config.yaml") == 0o600)
check("rerun: audit policy kept", open(t + "/etc/audit-policy.yaml").read() == "custom-audit\n")
check("rerun: pod security kept", open(t + "/etc/pod-security-config.yaml").read() == "custom-psa\n")
check("rerun: config.yaml kept", open(t + "/etc/config.yaml").read().startswith("custom-config"))
check("rerun: installer NOT run", "get.k3s.io" not in log, log)
check("rerun: k3s not restarted or started", "systemctl restart" not in log and "systemctl start" not in log, log)
check("rerun: no agent token added", not os.path.exists(t + "/etc/agent-token"))
backups = glob.glob(t + "/backup/encryption-config-*.yaml")
check("rerun: key backed up byte-identical", len(backups) == 1 and open(backups[0]).read() == KEY)
r, log = run(t)
check("rerun twice: still one backup", len(glob.glob(t + "/backup/encryption-config-*.yaml")) == 1)
check("rerun twice: key still identical", open(t + "/etc/encryption-config.yaml").read() == KEY)

# 3 Service stopped: started, not reinstalled
t2 = scenario("stopped")
shutil.copytree(t + "/etc", t2 + "/etc", dirs_exist_ok=True)
os.makedirs(t2 + "/data/server/db/etcd")
open(t2 + "/k3s", "w").write("#!/bin/true\n"); os.chmod(t2 + "/k3s", 0o755)
open(t2 + "/k3s.service", "w").write("x")
r, log = run(t2)
check("stopped: starts service", "systemctl start k3s" in log, log)
check("stopped: installer not run", "get.k3s.io" not in log, log)

# 4 Datastore exists but key is gone
t = scenario("lostkey")
os.makedirs(t + "/data/server/db/etcd")
r, log = run(t)
check("lost key: aborts", r.returncode != 0, r.stdout)
check("lost key: no key generated", not os.path.exists(t + "/etc/encryption-config.yaml"))
check("lost key: installer not run", "get.k3s.io" not in log)
check("lost key: explains", "unreadable" in r.stdout)

# 5 Empty key file with a datastore: abort, leave as is
t = scenario("emptykey")
os.makedirs(t + "/data/server/db/etcd")
open(t + "/etc/encryption-config.yaml", "w").write("")
r, log = run(t)
check("empty key + datastore: aborts", r.returncode != 0, r.stdout)
check("empty key + datastore: file left alone", os.path.getsize(t + "/etc/encryption-config.yaml") == 0)

# 6 Empty key file with no datastore: moved aside and regenerated
t = scenario("emptyfresh")
open(t + "/etc/encryption-config.yaml", "w").write("garbage\n")
r, log = run(t)
check("garbage key, no datastore: regenerated", r.returncode == 0 and "secret:" in open(t + "/etc/encryption-config.yaml").read(), r.stdout + r.stderr)
check("garbage key, no datastore: moved aside", len(glob.glob(t + "/etc/encryption-config.yaml.invalid-*")) == 1)

# 7 Backup cannot be written: stop before any change
t = scenario("nobackup")
open(t + "/etc/encryption-config.yaml", "w").write(KEY)
open(t + "/blocker", "w").write("file")
r, log = run(t, env_extra={"SECRETS_BACKUP_DIR": t + "/blocker/sub"})
check("backup fails: aborts", r.returncode != 0, r.stdout)
check("backup fails: installer not run", "get.k3s.io" not in log and not os.path.exists(t + "/etc/config.yaml"))

# 8 A second, different key gets its own backup, the old one remains
t = scenario("rotated")
open(t + "/etc/encryption-config.yaml", "w").write(KEY)
r, _ = run(t, call="prepare_encryption_config")
open(t + "/etc/encryption-config.yaml", "w").write(KEY.replace("ORIGINALKEY", "NEWERKEY"))
r, _ = run(t, call="prepare_encryption_config")
check("changed key: both copies kept", len(glob.glob(t + "/backup/encryption-config-*.yaml")) == 2)

# 9 UFW rule removal
OLD = "Status: active\n22/tcp ALLOW Anywhere\n8472/udp                   ALLOW       Anywhere\nAnywhere on tailscale0     ALLOW       Anywhere\n8472/udp (v6)              ALLOW       Anywhere (v6)\n"
t = scenario("ufw1")
open(t + "/etc/config.yaml", "w").write("flannel-iface: tailscale0\n")
r, log = run(t, call="remove_public_vxlan_rule", ufw_status=OLD)
check("ufw: deletes open rule when flannel-iface is tailscale0", "ufw delete allow 8472/udp" in log, log + r.stdout)
t = scenario("ufw2")
open(t + "/etc/config.yaml", "w").write("flannel-iface: eth0\n")
r, log = run(t, call="remove_public_vxlan_rule", ufw_status=OLD)
check("ufw: keeps rule when VXLAN is on another interface", "delete" not in log, log)
t = scenario("ufw3")
r, log = run(t, call="remove_public_vxlan_rule", ufw_status=OLD)
check("ufw: deletes when no config yet", "ufw delete allow 8472/udp" in log, log)
t = scenario("ufw4")
open(t + "/etc/config.yaml", "w").write("flannel-iface: tailscale0\n")
r, log = run(t, call="remove_public_vxlan_rule", ufw_status="Status: active\nAnywhere on tailscale0 ALLOW Anywhere\n")
check("ufw: no-op when already gone", "delete" not in log, log)

shutil.rmtree(base)
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
