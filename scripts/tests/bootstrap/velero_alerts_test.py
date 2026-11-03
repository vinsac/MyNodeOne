#!/usr/bin/env python3
"""The Velero alerts and monitor: that kube-prometheus-stack would load them, and that they
use metrics and labels that the pinned Velero has. Facts about Velero v1.12.3 are listed
here because they were read from that tag's source. Bumping the pin means re-reading them:
  pkg/metrics/metrics.go   metric names, and the schedule label
  pkg/install/resources.go Labels, containerPorts: component=velero, port metrics
  pkg/install/deployment.go  pod labels: deploy=velero
  pkg/install/resources.go AllResources: no Service object
"""
import importlib.util, os, pathlib, re, shutil, subprocess, sys, tempfile
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

PIN = "v1.12.3"
BACKUP_METRICS = """velero_backup_tarball_size_bytes velero_backup_total velero_backup_attempt_total velero_backup_success_total
velero_backup_partial_failure_total velero_backup_failure_total velero_backup_validation_failure_total
velero_backup_duration_seconds velero_backup_duration_seconds_bucket velero_backup_duration_seconds_sum velero_backup_duration_seconds_count
velero_backup_deletion_attempt_total velero_backup_deletion_success_total velero_backup_deletion_failure_total
velero_backup_last_successful_timestamp velero_backup_items_total velero_backup_items_errors velero_backup_warning_total velero_backup_last_status""".split()
POD_LABELS = {"component": "velero", "deploy": "velero"}
POD_PORT = "metrics"

install = open(repo + "/scripts/storage/velero/install.sh").read()
check("the pinned CLI is still the one these facts are from", PIN in install, re.findall(r"v\d+\.\d+\.\d+", install))

path = repo + "/scripts/storage/velero/velero-prometheus-rules.yaml"
docs = [d for d in yaml.safe_load_all(open(path)) if d]
by_kind = {}
for d in docs:
    by_kind.setdefault(d["kind"], []).append(d)

rule = by_kind.get("PrometheusRule", [None])[0]
check("has a PrometheusRule", rule is not None)
for d in docs:
    check("%s has the label the operator selects on" % d["kind"], d["metadata"]["labels"].get("release") == "kube-prometheus-stack", d["metadata"]["labels"])
    check("%s is in the velero namespace" % d["kind"], d["metadata"]["namespace"] == "velero")

check("no ServiceMonitor: velero install creates no Service for one to select", "ServiceMonitor" not in by_kind)
pm = by_kind.get("PodMonitor", [None])[0]
check("has a PodMonitor", pm is not None)
if pm:
    sel = pm["spec"]["selector"]["matchLabels"]
    check("PodMonitor selects the Velero pod", all(POD_LABELS.get(k) == v for k, v in sel.items()) and sel, sel)
    ports = [e.get("port") for e in pm["spec"]["podMetricsEndpoints"]]
    check("PodMonitor uses the pod's metrics port", ports == [POD_PORT], ports)

rules = [r for g in (rule or {"spec": {"groups": []}})["spec"]["groups"] for r in g["rules"]]
check("has alert rules", len(rules) >= 3)
parser = importlib.util.find_spec("promql_parser") is not None
if parser:
    import promql_parser
exprs = {}
for r in rules:
    expr = r["expr"]
    exprs[r["alert"]] = expr
    check(r["alert"] + ": has a severity", bool(r.get("labels", {}).get("severity")))
    names = set(re.findall(r"\bvelero_[a-z_]+", expr))
    check(r["alert"] + ": uses a metric", bool(names), expr)
    missing = names - set(BACKUP_METRICS)
    check(r["alert"] + ": metrics exist in " + PIN, not missing, missing)
    for label in re.findall(r"[{,]\s*([a-zA-Z_]+)\s*[!=~]+", expr):
        check(r["alert"] + ": label '%s' exists" % label, label == "schedule", expr)
    # A counter over 0 stays true from the first failure until Velero restarts.
    check(r["alert"] + ": doesn't compare a raw counter", not re.search(r"(?<!\()\bvelero_[a-z_]+_total(\{[^}]*\})?\s*>", expr), expr)
    if parser:
        try:
            promql_parser.parse(expr)
            check(r["alert"] + ": parses", True)
        except Exception as e:
            check(r["alert"] + ": parses", False, e)

schedules = open(repo + "/scripts/storage/velero/configure-backup.sh").read()
stale = [r for r in rules if "last_successful_timestamp" in r["expr"]]
named = set()
for r in stale:
    m = re.search(r'schedule="([^"]+)"', r["expr"])
    check(r["alert"] + ": is for one schedule, since each has its own period", m is not None, r["expr"])
    if m:
        named.add(m.group(1))
        check(r["alert"] + ": schedule exists in configure-backup.sh", m.group(1) in schedules, m.group(1))
check("a staleness alert for each schedule", named == {"daily-incremental-backup", "monthly-full-backup"}, named)
for r in stale:
    seconds = 0
    m = re.search(r">\s*(\d+)\s*\*\s*86400", r["expr"])
    days = int(m.group(1)) if m else 0
    if "monthly" in r["expr"]:
        check("the monthly alert allows over a month", days > 31, days)
    else:
        check("the daily alert allows a missed run", days >= 2, days)

# Rendered selectors from the chart itself, when it's there to render.
chart = os.environ.get("KUBE_PROMETHEUS_CHART")
helm = shutil.which("helm")
if not chart or not helm:
    print("note: KUBE_PROMETHEUS_CHART or helm not available, so the rendered selectors weren't checked")
else:
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
        values = repo + "/scripts/monitoring/kube-prometheus-stack-values.yaml"
        args = [helm, "template", "kube-prometheus-stack", chart, "--namespace", "monitoring"]
        if os.path.exists(values):
            args += ["-f", values]
        r = subprocess.run(args, capture_output=True, text=True, env=dict(os.environ, HOME=tmp))
        check("chart renders", r.returncode == 0, r.stderr[-300:])
        prom = [d for d in yaml.safe_load_all(r.stdout) if d and d.get("kind") == "Prometheus"]
        if prom:
            spec = prom[0]["spec"]
            for key, obj in (("ruleSelector", rule), ("podMonitorSelector", pm)):
                want = spec.get(key, {}).get("matchLabels", {})
                check("rendered %s matches" % key, obj and all(obj["metadata"]["labels"].get(k) == v for k, v in want.items()), want)
            for key in ("ruleNamespaceSelector", "podMonitorNamespaceSelector"):
                check("rendered %s allows the velero namespace" % key, spec.get(key) == {}, spec.get(key))

print("FAILURES:", fails)
sys.exit(1 if fails else 0)
