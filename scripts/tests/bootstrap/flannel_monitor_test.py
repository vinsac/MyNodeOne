#!/usr/bin/env python3
"""monitor-flannel-health.sh with a stub ip and systemctl. The state of the interfaces comes
from files a test sets up, so nothing here looks at or restarts anything real."""
import os, pathlib, stat, subprocess, sys, tempfile, time
repo = str(pathlib.Path(__file__).resolve().parents[3])
script = repo + "/scripts/validation/monitor-flannel-health.sh"
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok

base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
def stub(d, name, body):
    p = os.path.join(d, name)
    open(p, "w").write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)

HOUR = 3600
def setup(name, flannel="missing", underlay="up", started_ago=HOUR, config="flannel-iface: tailscale0\n", history=(), heal_after_checks=None, heal_on_restart=True):
    t = os.path.join(base, name); os.makedirs(t + "/bin"); os.makedirs(t + "/state")
    log = t + "/calls.log"
    open(t + "/flannel", "w").write(flannel)
    open(t + "/underlay", "w").write(underlay)
    if config is not None:
        open(t + "/config.yaml", "w").write(config)
    if history:
        now = int(time.time())
        open(t + "/state/recovery.log", "w").write("".join("%d x recovery\n" % (now - ago) for ago in history))
    heal = "" if heal_after_checks is None else '''
n=$(cat "%s/checks" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "%s/checks"
if [ "$n" -gt %d ]; then echo up > "%s/flannel"; fi''' % (t, t, heal_after_checks, t)
    stub(t + "/bin", "ip", '''
args="$*"
state() { cat "%s/$1"; }
case "$args" in
  "link show flannel.1")%s
    [ "$(state flannel)" != missing ] ;;
  "-4 addr show flannel.1")
    [ "$(state flannel)" = up ] && echo "    inet 10.42.0.0/32 scope global flannel.1"; true ;;
  "-o link show tailscale0")
    case "$(state underlay)" in
      up) echo "5: tailscale0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280 state UNKNOWN" ;;
      down) echo "5: tailscale0: <POINTOPOINT,MULTICAST,NOARP> mtu 1280 state DOWN" ;;
      *) exit 1 ;;
    esac ;;
  *) echo "unexpected ip $args" >> "%s"; exit 1 ;;
esac''' % (t, heal, log))
    entered = "" if started_ago is None else time.strftime("%a %Y-%m-%d %H:%M:%S UTC", time.gmtime(time.time() - started_ago))
    stub(t + "/bin", "systemctl", '''
case "$1" in
  is-active) [ "$2" = k3s ] ;;
  show) echo "%s" ;;
  restart) echo "RESTART $2" >> "%s"; %s ;;
  *) echo "systemctl $*" >> "%s" ;;
esac''' % (entered, log, ('echo up > "%s/flannel"' % t) if heal_on_restart else "true", log))
    stub(t + "/bin", "ufw", "exit 1")
    stub(t + "/bin", "logger", "exit 0")
    stub(t + "/bin", "hostname", "echo node1")
    stub(t + "/bin", "sleep", 'echo "sleep $*" >> "%s"' % log)
    stub(t, "hook", 'echo "HOOK $1" >> "%s"' % log)
    return t

def run(t, **env):
    e = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", FLANNEL_HEALTH_STATE_DIR=t + "/state", K3S_CONFIG_FILE=t + "/config.yaml",
             ALERT_HOOK=t + "/hook", RECOVERY_WAIT_SECONDS="4")
    e.update(env)
    r = subprocess.run(["bash", script], env=e, capture_output=True, text=True, timeout=60)
    log = open(t + "/calls.log").read() if os.path.exists(t + "/calls.log") else ""
    return r, log

def expect_no_restart(name, t, **env):
    r, log = run(t, **env)
    check(name + ": no restart", "RESTART" not in log, log + r.stdout + r.stderr)
    return r, log

t = setup("healthy", flannel="up")
r, log = expect_no_restart("healthy", t)
check("healthy: exit 0, no alert", r.returncode == 0 and "HOOK" not in log, r.stdout + r.stderr)

# The false positive: gone for one look, back on the next
t = setup("transient", heal_after_checks=1)
r, log = expect_no_restart("gone for one look", t)
check("gone for one look: exit 0, no alert", r.returncode == 0 and "HOOK" not in log, log + r.stdout)
check("gone for one look: waited first", "sleep 20" in log, log)

t = setup("noip", flannel="noip", heal_after_checks=1)
expect_no_restart("no IP for one look", t)

# k3s still starting, for instance just after a boot
t = setup("starting", started_ago=30)
r, log = expect_no_restart("k3s started 30s ago", t)
check("k3s started 30s ago: exit 0", r.returncode == 0 and "HOOK" not in log, r.stdout + log)

t = setup("started-long-ago", started_ago=10 * 60, heal_on_restart=True)
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("k3s up for 10 minutes: restarts", "RESTART k3s" in log, log + r.stdout)

# Restarting k3s can't bring back Tailscale
for state in ("down", "missing"):
    t = setup("underlay-" + state, underlay=state)
    r, log = expect_no_restart("tailscale0 " + state, t)
    check("tailscale0 %s: reported" % state, r.returncode != 0 and "HOOK flannel-underlay-down" in log and "tailscale0" in r.stdout, r.stdout + log)

# Backends with no flannel.1 at all
t = setup("wg", config='flannel-iface: tailscale0\nflannel-backend: "wireguard-native"\n')
r, log = expect_no_restart("another backend", t)
check("another backend: exit 0", r.returncode == 0 and "HOOK" not in log, r.stdout + log)
t = setup("vxlan", config="flannel-backend: vxlan\nflannel-iface: tailscale0\n")
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("backend vxlan: still restarts", "RESTART k3s" in log, log)
t = setup("noconfig", config=None)
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("no config file: still restarts", "RESTART k3s" in log, log + r.stdout + r.stderr)

# A real failure: restart once it's confirmed, and check what it did
t = setup("real")
r, log = run(t)
check("really gone: restarts once", log.count("RESTART k3s") == 1, log + r.stdout + r.stderr)
check("really gone: looked three more times first", log.count("sleep 20") == 3, log)
check("really gone: alerts", "HOOK flannel-missing" in log, log)
check("really gone: restored, exit 0", r.returncode == 0 and "Recovery successful" in r.stdout, r.stdout)
check("really gone: restart recorded", os.path.exists(t + "/state/recovery.log"))

t = setup("not-fixed", heal_on_restart=False)
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("restart didn't help: says so", r.returncode != 0 and "Recovery FAILED" in r.stdout and "HOOK recovery-failed" in log, r.stdout + log)

t = setup("link-no-ip", flannel="noip", heal_on_restart=False)
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("back without an IP isn't a recovery", "Recovery FAILED" in r.stdout, r.stdout)

# Backoff: 15 minutes after the first restart, then 30, then 60
for name, history, restarts in [
    ("10m after 1 restart", [10 * 60], False),
    ("20m after 1 restart", [20 * 60], True),
    ("20m after 2 restarts", [40 * 60, 20 * 60], False),
    ("35m after 2 restarts", [60 * 60, 35 * 60], True),
    ("45m after 3 restarts", [3 * HOUR, 2 * HOUR, 45 * 60], False),
    ("65m after 3 restarts", [3 * HOUR, 2 * HOUR, 65 * 60], True),
    ("old restarts don't count", [25 * HOUR, 26 * HOUR, 27 * HOUR, 28 * HOUR], True),
]:
    # Recorded oldest first, like the real log
    t = setup("backoff-" + name.replace(" ", "-"), history=sorted(history, reverse=True))
    r, log = run(t, RECHECK_DELAY_SECONDS="0")
    check(name + (": restarts" if restarts else ": holds off"), ("RESTART" in log) == restarts, log + r.stdout + r.stderr)
    if not restarts:
        check(name + ": exit non-zero", r.returncode != 0)
        check(name + ": says it's backing off", "Backing off" in r.stdout, r.stdout)

t = setup("cap", history=[23 * HOUR, 20 * HOUR, 15 * HOUR, 8 * HOUR])
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("4 restarts in 24 hours: stops", "RESTART" not in log and r.returncode != 0, log + r.stdout)
check("4 restarts in 24 hours: asks for a person", "Manual intervention" in r.stdout and "HOOK recovery-throttled" in log, r.stdout + log)

# Run it like the timer would, on a node that never recovers
t = setup("storm", heal_on_restart=False)
restarts = 0
for _ in range(10):
    r, log = run(t, RECHECK_DELAY_SECONDS="0", RECOVERY_WAIT_SECONDS="0")
check("repeated runs in a row: one restart, not one per run", log.count("RESTART") == 1, log.count("RESTART"))

t = setup("garbage", history=[25 * HOUR])
with open(t + "/state/recovery.log", "a") as f:
    f.write("not a timestamp\n\n")
r, log = run(t, RECHECK_DELAY_SECONDS="0")
check("junk in the log: still works", "RESTART k3s" in log, log + r.stdout + r.stderr)

subprocess.run(["rm", "-rf", base])
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
