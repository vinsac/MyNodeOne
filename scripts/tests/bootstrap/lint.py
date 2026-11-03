#!/usr/bin/env python3
"""bash -n on the bootstrap's scripts, plus parsing its YAML. These are also covered
across the whole repo by CI's shell and manifests jobs, along with shellcheck's ratchet
(scripts/tests/ci/ratchet.py), but this suite then runs on its own with one command."""
import glob, os, pathlib, subprocess, sys
try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed")
    sys.exit(77)
repo = str(pathlib.Path(__file__).resolve().parents[3])
scripts = """scripts/installation/bootstrap-control-plane.sh
scripts/installation/install-mynodeone.sh
scripts/lib/versions.sh
scripts/monitoring/apply-monitoring-config.sh
scripts/setup/setup-control-plane-sudo.sh
scripts/setup/enable-security-hardening.sh
scripts/setup/check-audit-policy.sh
scripts/setup/setup-edge-node.sh
scripts/validation/monitor-flannel-health.sh
scripts/nodes/add-worker-node.sh
scripts/lib/fetch-cluster-info.sh
scripts/backup/backup-control-plane-state.sh
scripts/backup/configure-longhorn-backups.sh""".split()

fails = 0
for f in scripts:
    p = os.path.join(repo, f)
    r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
    print("bash -n", "ok  " if r.returncode == 0 else "FAIL", f, r.stderr.strip())
    fails += r.returncode != 0

yamls = [os.path.join(repo, "manifests/security/audit-policy.yaml")] + \
    glob.glob(os.path.join(repo, "scripts/monitoring/*.yaml")) + \
    glob.glob(os.path.join(repo, "scripts/monitoring/prometheus-alerts/*.yaml")) + \
    [os.path.join(repo, "scripts/storage/velero/velero-prometheus-rules.yaml")]
for y in yamls:
    try:
        docs = list(yaml.safe_load_all(open(y)))
        print("yaml ok  ", os.path.relpath(y, repo), [d.get("kind") if isinstance(d, dict) else d for d in docs])
    except Exception as e:
        print("yaml FAIL", y, e); fails += 1
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
