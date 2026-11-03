#!/usr/bin/env python3
"""helm template only: no cluster access. Compares chart defaults with our values.

Downloads the chart version versions.sh pins, so it needs helm and the network. Set
KUBE_PROMETHEUS_CHART to a chart directory to use a copy you already have.
"""
import atexit, os, pathlib, re, shutil, subprocess, sys, tempfile
try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed")
    sys.exit(77)
if not shutil.which("helm"):
    print("SKIP helm is not installed")
    sys.exit(77)
repo = str(pathlib.Path(__file__).resolve().parents[3])
scratch = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
atexit.register(shutil.rmtree, scratch, ignore_errors=True)
env = dict(os.environ, KUBECONFIG="/dev/null",
           HELM_CONFIG_HOME=scratch + "/h/c", HELM_CACHE_HOME=scratch + "/h/ca", HELM_DATA_HOME=scratch + "/h/d")
chart = os.environ.get("KUBE_PROMETHEUS_CHART")
if not chart:
    version = subprocess.run(["bash", "-c", 'source "$1"; echo "$PROMETHEUS_STACK_VERSION"', "_", repo + "/scripts/lib/versions.sh"],
                             capture_output=True, text=True).stdout.strip()
    pulled = subprocess.run(["helm", "pull", "kube-prometheus-stack", "--repo", "https://prometheus-community.github.io/helm-charts",
                             "--version", version, "--untar", "--untardir", scratch], env=env, capture_output=True, text=True, timeout=300)
    if pulled.returncode:
        print("SKIP could not download kube-prometheus-stack %s: %s" % (version, pulled.stderr.strip()[:300]))
        sys.exit(77)
    chart = scratch + "/kube-prometheus-stack"
values = repo + "/scripts/monitoring/kube-prometheus-stack-values.yaml"
base = ["helm", "template", "kube-prometheus-stack", chart, "--namespace", "monitoring",
        "--kube-version", "1.31.2", "--include-crds=false"]

def render(extra):
    r = subprocess.run(base[:-1] + extra, env=env, capture_output=True, text=True, cwd=scratch)
    if r.returncode:
        raise SystemExit("helm failed: " + r.stderr[:2000])
    return r.stdout

def alert_names(text):
    return set(re.findall(r'-\s*alert:\s*(\S+)', text))

default = render([])
ours = render(["-f", values, "--set", "prometheus.prometheusSpec.retention=30d"])
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok

for a in ["KubeSchedulerDown", "KubeControllerManagerDown", "KubeProxyDown"]:
    check("default chart has " + a, a in alert_names(default))
    check("our values remove " + a, a not in alert_names(ours))
removed = alert_names(default) - alert_names(ours)
print("alerts removed by our values:", sorted(removed))
print("alerts kept:", len(alert_names(ours)))

docs = [d for d in yaml.safe_load_all(ours) if d]
prom = [d for d in docs if d.get("kind") == "Prometheus"][0]
check("retentionSize rendered as 85GB", prom["spec"].get("retentionSize") == "85GB", prom["spec"].get("retentionSize"))
check("retention rendered", prom["spec"].get("retention") == "30d", prom["spec"].get("retention"))
check("rule selector matches release label", prom["spec"]["ruleSelector"]["matchLabels"].get("release") == "kube-prometheus-stack", prom["spec"].get("ruleSelector"))
check("serviceMonitor selector matches release label", prom["spec"]["serviceMonitorSelector"]["matchLabels"].get("release") == "kube-prometheus-stack", prom["spec"].get("serviceMonitorSelector"))

ds = [d for d in docs if d.get("kind") == "DaemonSet" and "node-exporter" in d["metadata"]["name"]][0]
c = ds["spec"]["template"]["spec"]["containers"][0]
args = c["args"]
default_ds = [d for d in yaml.safe_load_all(default) if d and d.get("kind") == "DaemonSet" and "node-exporter" in d["metadata"]["name"]][0]
default_args = default_ds["spec"]["template"]["spec"]["containers"][0]["args"]
check("node-exporter keeps every default arg", set(default_args) <= set(args), set(default_args) - set(args))
check("textfile directory arg added", "--collector.textfile.directory=/host/mynodeone-metrics" in args, args)
vols = {v["name"]: v for v in ds["spec"]["template"]["spec"]["volumes"]}
check("hostPath DirectoryOrCreate", vols.get("mynodeone-metrics", {}).get("hostPath") == {"path": "/var/lib/mynodeone/metrics", "type": "DirectoryOrCreate"}, vols.get("mynodeone-metrics"))
m = {v["name"]: v for v in c["volumeMounts"]}
check("mounted read-only", m.get("mynodeone-metrics", {}).get("readOnly") is True, m.get("mynodeone-metrics"))
spec = ds["spec"]["template"]["spec"]
print("node-exporter needs: hostNetwork=%s hostPID=%s" % (spec.get("hostNetwork"), spec.get("hostPID")), "hostPath volumes:", [k for k, v in vols.items() if "hostPath" in v])

svc_names = [d["metadata"]["name"] for d in docs if d.get("kind") == "Service"]
check("no scheduler/controller/proxy Services", not [s for s in svc_names if re.search("kube-scheduler|kube-controller|kube-proxy", s)], svc_names)

# Default chart disk rule thresholds, which the comment in node-disk-alerts.yaml cites
oos = re.findall(r'alert:\s*NodeFilesystemAlmostOutOfSpace[\s\S]{0,800}?expr:[^\n]*\n?[^\n]*?\* 100 < (\d+)', default)
print("chart NodeFilesystemAlmostOutOfSpace thresholds:", oos)

# Example alert destination with the comments removed: does it render, with the receiver wired up?
ex = open(repo + "/scripts/monitoring/alertmanager-values.example.yaml").read()
live = "\n".join(l[2:] if l.startswith("# ") else "" for l in ex.splitlines()[12:])
with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, dir=scratch) as t:
    t.write(live)
parsed = yaml.safe_load(live)
check("example parses when uncommented", parsed["alertmanager"]["config"]["route"]["receiver"] == "my-destination", parsed)
rendered = render(["-f", values, "-f", t.name])
check("example renders", "kind: Alertmanager" in rendered)
secret = [d for d in yaml.safe_load_all(rendered) if d and d.get("kind") == "Secret" and "alertmanager" in d["metadata"]["name"]]
check("example produces an alertmanager config secret", bool(secret))
os.unlink(t.name)

# Unset receiver leaves the chart default
secret_default = [d for d in docs if d.get("kind") == "Secret" and "alertmanager" in d["metadata"]["name"]]
secret_chart = [d for d in yaml.safe_load_all(default) if d and d.get("kind") == "Secret" and "alertmanager" in d["metadata"]["name"]]
check("no destination: alertmanager config equals chart default", secret_default[0]["data"] == secret_chart[0]["data"])

print("FAILURES:", fails)
sys.exit(1 if fails else 0)
