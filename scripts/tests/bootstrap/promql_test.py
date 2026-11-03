#!/usr/bin/env python3
"""Checks every alert rule's expression, and the labels the operator selects on.

Uses promtool, the Prometheus project's own checker, and the promql-parser package.
Either alone is enough to run, and with neither this skips.
"""
import glob, importlib.util, os, pathlib, shutil, subprocess, sys, tempfile
try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed")
    sys.exit(77)

repo = str(pathlib.Path(__file__).resolve().parents[3])
promtool = shutil.which("promtool")
parser = importlib.util.find_spec("promql_parser") is not None
if not promtool and not parser:
    print("SKIP neither promtool nor the promql-parser package is installed, so no alert rule was checked")
    sys.exit(77)
print("checking with:", ", ".join(n for n, on in (("promtool", promtool), ("promql-parser", parser)) if on))
fails = 0
for f in sorted(glob.glob(repo + "/scripts/monitoring/prometheus-alerts/*.yaml")):
    name = f.rsplit("/", 1)[1]
    doc = yaml.safe_load(open(f))
    if doc["metadata"]["labels"].get("release") != "kube-prometheus-stack":
        print("FAIL label", name); fails += 1
    for g in doc["spec"]["groups"]:
        for rule in g["rules"]:
            ok = bool(rule.get("labels", {}).get("severity"))
            print("PASS" if ok else "FAIL no severity", name, rule["alert"])
            fails += not ok
            if parser:
                import promql_parser
                try:
                    promql_parser.parse(rule["expr"])
                except Exception as e:
                    print("FAIL", rule["alert"], e); fails += 1
    if promtool:
        # The file is a PrometheusRule object, and promtool reads what's in its spec.
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
            rules = os.path.join(tmp, name)
            with open(rules, "w") as out:
                yaml.safe_dump(doc["spec"], out)
            r = subprocess.run([promtool, "check", "rules", rules], capture_output=True, text=True)
        print("PASS" if r.returncode == 0 else "FAIL", "promtool check rules", name)
        if r.returncode:
            print(r.stdout + r.stderr)
            fails += 1
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
