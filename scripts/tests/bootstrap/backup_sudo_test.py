#!/usr/bin/env python3
"""Runs the backup and sudo scripts against temp dirs with stubbed privileged commands."""
import glob, os, pathlib, shutil, stat, subprocess, sys, tarfile, tempfile, time
repo = str(pathlib.Path(__file__).resolve().parents[3])
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok
def mode(p): return stat.S_IMODE(os.stat(p).st_mode)
def stub(d, name, body):
    p = os.path.join(d, name)
    open(p, "w").write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)

base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
script = repo + "/scripts/backup/backup-control-plane-state.sh"

def setup(name):
    t = os.path.join(base, name)
    os.makedirs(t + "/etc"); os.makedirs(t + "/data/server/db/snapshots"); os.makedirs(t + "/bin")
    open(t + "/etc/encryption-config.yaml", "w").write("secret: K\n")
    open(t + "/etc/config.yaml", "w").write("x: y\n")
    open(t + "/data/server/token", "w").write("servertoken\n")
    os.symlink(t + "/data/server/token", t + "/data/server/agent-token")
    for i in range(4):
        p = t + "/data/server/db/snapshots/snap-%d" % i
        open(p, "w").write("s%d" % i)
        # A few hours old, and snap-3 is the newest
        when = time.time() - 3600 * (4 - i)
        os.utime(p, (when, when))
    log = t + "/calls.log"
    stub(t + "/bin", "rsync", 'echo "rsync $*" >> "%s"' % log)
    stub(t + "/bin", "gpg", 'echo "gpg $*" >> "%s"\nwhile [ $# -gt 0 ]; do if [ "$1" = --output ]; then echo enc > "$2"; fi; shift; done' % log)
    stub(t + "/bin", "systemctl", 'echo "systemctl $*" >> "%s"' % log)
    return t

def run(t, *args, **env):
    e = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", BACKUP_DIR=t + "/b", K3S_CONFIG_DIR=t + "/etc",
             K3S_DATA_DIR=t + "/data", METRICS_DIR=t + "/m", SYSTEMD_DIR=t + "/sd", INSTALL_PATH=t + "/inst",
             BACKUP_CONFIG_FILE=t + "/none.env")
    e.update(env)
    return subprocess.run(["bash", script] + list(args), env=e, capture_output=True, text=True)

t = setup("a")
r = run(t)
check("backup: exit 0", r.returncode == 0, r.stdout + r.stderr)
arch = glob.glob(t + "/b/control-plane-state-*.tar.gz")
check("backup: one archive", len(arch) == 1)
check("backup: archive 600", mode(arch[0]) == 0o600)
check("backup: dir 700", mode(t + "/b") == 0o700)
names = tarfile.open(arch[0]).getnames()
check("backup: has key", "k3s-config/encryption-config.yaml" in names, names)
check("backup: has token", "k3s-server/token" in names, names)
check("backup: symlinked agent-token stored as a file", tarfile.open(arch[0]).getmember("k3s-server/agent-token").isfile())
snaps = sorted(n for n in names if n.startswith("etcd-snapshots/"))
check("backup: only newest 2 snapshots", snaps == ["etcd-snapshots/snap-2", "etcd-snapshots/snap-3"], snaps)
check("backup: no work dir left", not glob.glob(t + "/b/.work.*"))
m = open(t + "/m/control-plane-backup.prom").read()
check("metrics: timestamp written", 'mynodeone_backup_last_success_timestamp_seconds{backup="control-plane-state"} ' in m, m)
check("metrics: remote flag 0", 'mynodeone_backup_remote_copy_enabled{backup="control-plane-state"} 0' in m, m)
check("metrics: world readable for node-exporter", mode(t + "/m/control-plane-backup.prom") == 0o644)
check("warns with no remote", "BACKUP_REMOTE is not set" in r.stdout)

# retention
t = setup("keep")
os.makedirs(t + "/b")
for i in range(5):
    open(t + "/b/control-plane-state-2020010%dT000000Z.tar.gz" % i, "w").write("old")
r = run(t, BACKUP_KEEP="3")
left = sorted(os.path.basename(f) for f in glob.glob(t + "/b/control-plane-state-*.tar.gz"))
check("retention: keeps 3 newest", len(left) == 3 and left[-1].startswith("control-plane-state-20") and "20200104" in left[1], left)

# plaintext remote refused, no metric update, archive kept
t = setup("plain")
r = run(t, BACKUP_REMOTE="u@h:/p")
check("remote without GPG: refused", r.returncode != 0 and "BACKUP_GPG_RECIPIENT" in r.stderr, r.stderr)
check("remote without GPG: local archive kept", len(glob.glob(t + "/b/control-plane-state-*.tar.gz")) == 1)
check("remote without GPG: no success metric", not os.path.exists(t + "/m/control-plane-backup.prom"))
check("remote without GPG: nothing sent", not os.path.exists(t + "/calls.log") or "rsync" not in open(t + "/calls.log").read())

# gpg path
t = setup("gpg")
r = run(t, BACKUP_REMOTE="u@h:/p", BACKUP_GPG_RECIPIENT="me")
log = open(t + "/calls.log").read()
check("remote with GPG: exit 0", r.returncode == 0, r.stdout + r.stderr)
check("remote with GPG: sends only .gpg", ".tar.gz.gpg u@h:/p/" in log, log)
check("remote with GPG: encrypted copy removed locally", not glob.glob(t + "/b/*.gpg"))
check("remote with GPG: remote flag 1", 'remote_copy_enabled{backup="control-plane-state"} 1' in open(t + "/m/control-plane-backup.prom").read())

# explicit plaintext
t = setup("plainok")
r = run(t, BACKUP_REMOTE="u@h:/p", BACKUP_ALLOW_PLAINTEXT_REMOTE="1")
check("explicit plaintext remote: sent", r.returncode == 0 and ".tar.gz u@h:/p/" in open(t + "/calls.log").read(), r.stderr)

# no key
t = setup("nokey")
os.unlink(t + "/etc/encryption-config.yaml")
r = run(t)
check("missing key: fails, no archive", r.returncode != 0 and not glob.glob(t + "/b/control-plane-state-*.tar.gz"), r.stderr)

# --- a run only counts if the archive could restore the cluster
PROM = "/m/control-plane-backup.prom"
def expect_incomplete(name, t, r, reason):
    check(name + ": exit non-zero", r.returncode != 0, r.stdout + r.stderr)
    check(name + ": says why", reason in r.stdout + r.stderr, r.stdout + r.stderr)
    check(name + ": no success metric", not os.path.exists(t + PROM))
    check(name + ": no good-looking archive", not glob.glob(t + "/b/control-plane-state-*.tar.gz"))
    kept = glob.glob(t + "/b/incomplete-control-plane-state-*.tar.gz")
    check(name + ": keeps what it could, privately", len(kept) == 1 and mode(kept[0]) == 0o600, kept)

def age_snapshots(t, hours):
    for p in glob.glob(t + "/data/server/db/snapshots/*"):
        when = time.time() - hours * 3600
        os.utime(p, (when, when))

def set_ca(t, hours):
    os.makedirs(t + "/data/server/tls", exist_ok=True)
    p = t + "/data/server/tls/server-ca.crt"
    open(p, "w").write("ca")
    when = time.time() - hours * 3600
    os.utime(p, (when, when))

# The reviewer's case: only the encryption key was there
t = setup("onlykey")
shutil.rmtree(t + "/data/server/db/snapshots")
os.unlink(t + "/data/server/token"); os.unlink(t + "/data/server/agent-token")
expect_incomplete("nothing restorable", t, run(t), "server token is missing")

t = setup("notoken")
os.unlink(t + "/data/server/token"); os.unlink(t + "/data/server/agent-token")
expect_incomplete("no token, fresh snapshots", t, run(t), "server token is missing")

t = setup("emptytoken")
open(t + "/data/server/token", "w").close()
expect_incomplete("empty token", t, run(t), "server token is missing")

# The reviewer's other case: a 60-day-old snapshot counted
t = setup("oldsnap")
age_snapshots(t, 60 * 24)
expect_incomplete("60-day-old snapshot", t, run(t), "1440 hours old")

t = setup("justover")
age_snapshots(t, 25)
expect_incomplete("snapshot just over the limit", t, run(t), "25 hours old")

t = setup("limitset")
age_snapshots(t, 25)
r = run(t, BACKUP_MAX_SNAPSHOT_AGE_HOURS="48")
check("the limit can be raised", r.returncode == 0 and os.path.exists(t + PROM), r.stdout + r.stderr)

t = setup("badlimit")
r = run(t, BACKUP_MAX_SNAPSHOT_AGE_HOURS="1d")
check("a bad limit stops the run", r.returncode != 0 and "whole numbers" in r.stderr and not os.path.exists(t + PROM), r.stderr)

# Failed etcd snapshots leave empty files, which are not snapshots
t = setup("emptysnap")
for p in glob.glob(t + "/data/server/db/snapshots/*"):
    open(p, "w").close()
expect_incomplete("only empty snapshot files", t, run(t), "no etcd snapshots")

t = setup("newemptysnap")
age_snapshots(t, 60 * 24)
p = t + "/data/server/db/snapshots/snap-new"
open(p, "w").close()
expect_incomplete("a new empty file doesn't hide an old snapshot", t, run(t), "1440 hours old")

# New cluster: no snapshot can exist yet
t = setup("grace")
shutil.rmtree(t + "/data/server/db/snapshots")
set_ca(t, 1)
r = run(t)
check("new cluster: exit 0", r.returncode == 0, r.stdout + r.stderr)
check("new cluster: says no snapshot yet", "no etcd snapshot yet" in r.stdout, r.stdout)
check("new cluster: no success metric", not os.path.exists(t + PROM))
kept = glob.glob(t + "/b/control-plane-state-*.tar.gz")
check("new cluster: keeps keys and tokens, privately", len(kept) == 1 and mode(kept[0]) == 0o600, kept)

t = setup("graceover")
shutil.rmtree(t + "/data/server/db/snapshots")
set_ca(t, 25)
expect_incomplete("cluster over a day old with no snapshots", t, run(t), "no etcd snapshots")

t = setup("noca")
shutil.rmtree(t + "/data/server/db/snapshots")
expect_incomplete("no snapshots, age unknown", t, run(t), "no etcd snapshots")

t = setup("gracenotoken")
shutil.rmtree(t + "/data/server/db/snapshots")
os.unlink(t + "/data/server/token"); os.unlink(t + "/data/server/agent-token")
set_ca(t, 1)
expect_incomplete("new cluster without a token", t, run(t), "server token is missing")

# Grace only covers having no snapshot, not having a stale one
t = setup("graceold")
age_snapshots(t, 60 * 24)
set_ca(t, 1)
expect_incomplete("new CA doesn't excuse an old snapshot", t, run(t), "1440 hours old")

# k3s rewrites the token at each start, so a fresh token on an old cluster gets no grace
t = setup("freshtoken")
shutil.rmtree(t + "/data/server/db/snapshots")
set_ca(t, 24 * 30)
now = time.time()
os.utime(t + "/data/server/token", (now, now))
expect_incomplete("restart doesn't make a cluster new", t, run(t), "no etcd snapshots")

# A failed run must not push good archives out, send anything, or refresh the metric
t = setup("rotation")
os.makedirs(t + "/b")
good = ["control-plane-state-2020010%dT000000Z.tar.gz" % i for i in range(3)]
for g in good:
    open(t + "/b/" + g, "w").write("good")
os.makedirs(t + "/m")
open(t + PROM, "w").write("previous\n")
age_snapshots(t, 60 * 24)
for i in range(5):
    open(t + "/b/incomplete-control-plane-state-2020010%dT000000Z.tar.gz" % i, "w").write("bad")
r = run(t, BACKUP_KEEP="3", BACKUP_REMOTE="u@h:/p", BACKUP_ALLOW_PLAINTEXT_REMOTE="1")
check("failed run: exit non-zero", r.returncode != 0)
check("failed run: good archives all kept", all(os.path.exists(t + "/b/" + g) for g in good))
check("failed run: its own archives pruned", len(glob.glob(t + "/b/incomplete-control-plane-state-*.tar.gz")) == 3)
check("failed run: nothing sent off the machine", not os.path.exists(t + "/calls.log") or "rsync" not in open(t + "/calls.log").read())
check("failed run: previous metric untouched", open(t + PROM).read() == "previous\n")

# The first backup at install time reports its failure to the caller
t = setup("installfail")
age_snapshots(t, 60 * 24)
r = run(t, "--install")
check("--install: failing first backup exits non-zero", r.returncode != 0, r.stdout + r.stderr)

# --- sudo script
sudo_script = repo + "/scripts/setup/setup-control-plane-sudo.sh"
def sudo_run(name, consent=None, preexisting=False, stdin=None, visudo_ok=True):
    t = os.path.join(base, "s_" + name)
    os.makedirs(t + "/bin")
    # sudo stub drops the -S-style privilege change and only logs; `install -o root` is mapped below
    stub(t + "/bin", "sudo", 'echo "sudo $*" >> "%s/calls.log"\ncase "$1" in\n  visudo) %s ;;\n  install) cp "${@: -2:1}" "${@: -1}"; chmod 440 "${@: -1}" ;;\n  *) "$@" ;;\nesac' % (t, "exit 0" if visudo_ok else "exit 1"))
    target = t + "/sudoers"
    if preexisting:
        open(target, "w").write("old rule\n")
    e = dict(os.environ, PATH=t + "/bin:/usr/bin:/bin", SUDOERS_FILE=target, SUDO_USER="tester")
    e.pop("MYNODEONE_SUDO_CONSENT", None)
    if consent:
        e["MYNODEONE_SUDO_CONSENT"] = consent
    r = subprocess.run(["bash", sudo_script], env=e, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r, target

r, f = sudo_run("noanswer")
check("sudo: no tty, no answer: nothing added", r.returncode == 0 and not os.path.exists(f), r.stdout + r.stderr)
r, f = sudo_run("noanswer_old", preexisting=True)
check("sudo: no tty, no answer: existing rule untouched", open(f).read() == "old rule\n")
r, f = sudo_run("yes", consent="yes")
c = open(f).read() if os.path.exists(f) else ""
check("sudo: consent yes writes rule", "NOPASSWD: /usr/local/bin/kubectl, /usr/bin/kubectl" in c, r.stdout + r.stderr)
active = "\n".join(l for l in c.splitlines() if not l.startswith("#"))
check("sudo: active rule has no scripts path or glob", "scripts" not in active and "*" not in active, active)
check("sudo: rule file is 440", mode(f) == 0o440)
r, f = sudo_run("no", consent="no", preexisting=True)
check("sudo: consent no removes existing rule", not os.path.exists(f))
r, f = sudo_run("bad", consent="yes", visudo_ok=False)
check("sudo: visudo failure installs nothing", r.returncode != 0 and not os.path.exists(f), r.stdout)
r, f = sudo_run("garbage", consent="maybe")
check("sudo: invalid consent value adds nothing", not os.path.exists(f))

shutil.rmtree(base)
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
