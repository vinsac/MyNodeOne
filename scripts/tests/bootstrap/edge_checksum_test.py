#!/usr/bin/env python3
"""setup_monitoring_agent's download check on the edge node. The function is cut from the
script with its system paths pointed into a temp dir. curl, dpkg, systemctl and install are
stubs. sha256sum and tar are real, because they're what's under test."""
import hashlib, os, pathlib, re, subprocess, sys, tarfile, tempfile
repo = str(pathlib.Path(__file__).resolve().parents[3])
source = open(repo + "/scripts/setup/setup-edge-node.sh").read()
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok

m = re.search(r"^setup_monitoring_agent\(\) \{.*?^\}", source, re.S | re.M)
fn = m.group(0)
base = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
VERSION, ARCH = "9.9.9", "amd64"
TARBALL = "node_exporter-%s.linux-%s.tar.gz" % (VERSION, ARCH)

def make_release(d):
    os.makedirs(d)
    inner = d + "/node_exporter"
    open(inner, "w").write("#!/bin/sh\necho binary\n")
    os.chmod(inner, 0o755)
    with tarfile.open(d + "/" + TARBALL, "w:gz") as tar:
        tar.add(inner, arcname="node_exporter-%s.linux-%s/node_exporter" % (VERSION, ARCH))
    os.unlink(inner)
    return hashlib.sha256(open(d + "/" + TARBALL, "rb").read()).hexdigest()

def run(name, sums, curl_fail_on=None):
    t = os.path.join(base, re.sub(r"[^a-z0-9]+", "-", name)); rel = t + "/rel"
    digest = make_release(rel)
    open(rel + "/sha256sums.txt", "w").write(sums(digest))
    bindir = t + "/bin"; os.makedirs(bindir); os.makedirs(t + "/systemd"); os.makedirs(t + "/usr-local-bin")
    def stub(tool, body):
        open(bindir + "/" + tool, "w").write("#!/bin/bash\n" + body + "\n")
        os.chmod(bindir + "/" + tool, 0o755)
    stub("dpkg", "echo %s" % ARCH)
    stub("systemctl", 'echo "systemctl $*" >> %s/calls.log' % t)
    # Records where the binary would go, and copies it into the temp dir.
    stub("install", 'echo "install $*" >> %s/calls.log; /usr/bin/cp "${@: -2:1}" %s/usr-local-bin/' % (t, t))
    fail_clause = 'if [[ "$1" == *%s* ]]; then exit 22; fi' % curl_fail_on if curl_fail_on else ""
    # curl -fsSL URL -o FILE
    stub("curl", '''shift; url="$1"; out="$3"; %s
/usr/bin/cp "%s/${url##*/}" "$out" ''' % (fail_clause.replace("$1", "$url"), rel))
    body = fn.replace("/usr/local/bin/node_exporter", t + "/usr-local-bin/node_exporter").replace("/etc/systemd/system", t + "/systemd")
    prog = 'set -euo pipefail\nlog_info() { echo "INFO $*"; }; log_success() { echo "OK $*"; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERROR $*"; }\n' \
        + 'NODE_EXPORTER_VERSION=%s\n%s\nsetup_monitoring_agent\necho REACHED_END\n' % (VERSION, body)
    r = subprocess.run(["bash", "-c", prog], env=dict(os.environ, PATH=bindir + ":/usr/bin:/bin", TMPDIR=t), capture_output=True, text=True)
    installed = os.path.exists(t + "/usr-local-bin/node_exporter")
    calls = open(t + "/calls.log").read() if os.path.exists(t + "/calls.log") else ""
    return r, installed, calls, t

def refused(name, *args, **kw):
    r, installed, calls, t = run(name, *args, **kw)
    out = r.stdout + r.stderr
    check(name + ": stops the install", r.returncode != 0 and "REACHED_END" not in r.stdout, out)
    check(name + ": says so", "Could not download and verify node_exporter" in out, out)
    check(name + ": binary not installed", not installed and "install " not in calls, calls)
    check(name + ": service not started", "systemctl" not in calls, calls)
    leftovers = [n for n in os.listdir(t) if n.startswith("tmp.")]
    check(name + ": temp dir removed", not leftovers, leftovers)

refused("wrong checksum", lambda d: "%s  %s\n" % ("0" * 64, TARBALL))
refused("name missing from sha256sums.txt", lambda d: "%s  node_exporter-other.tar.gz\n" % d)
refused("empty sha256sums.txt", lambda d: "")
refused("checksum list won't download", lambda d: "%s  %s\n" % (d, TARBALL), curl_fail_on="sha256sums.txt")
refused("tarball won't download", lambda d: "%s  %s\n" % (d, TARBALL), curl_fail_on=TARBALL)

r, installed, calls, t = run("correct", lambda d: "%s  other.tar.gz\n%s  %s\n" % ("1" * 64, d, TARBALL))
check("correct checksum: installs", r.returncode == 0 and installed, r.stdout + r.stderr)
check("correct checksum: uses mode 0755", "install -m 0755" in calls, calls)

subprocess.run(["rm", "-rf", base])
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
