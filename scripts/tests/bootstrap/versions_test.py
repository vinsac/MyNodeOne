#!/usr/bin/env python3
"""bootstrap takes every Helm chart version from versions.sh, not from its own text."""
import pathlib, re, subprocess, sys
repo = str(pathlib.Path(__file__).resolve().parents[3])
now = open(repo + "/scripts/installation/bootstrap-control-plane.sh").read()
out = subprocess.run(["bash", "-c", 'source "$1"; set | grep -E "^[A-Z0-9_]+_VERSION="', "_", repo + "/scripts/lib/versions.sh"], capture_output=True, text=True).stdout
vals = dict(l.split("=", 1) for l in out.splitlines())
vals = {k: v.strip("'\"") for k, v in vals.items() if not k.startswith("BASH")}
fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + str(detail)) if detail and not ok else ""))
    fails += not ok
pairs = [("CERT_MANAGER_VERSION", r'jetstack/cert-manager \\\n\s+--namespace cert-manager \\\n\s+--version (\S+)'),
         ("LONGHORN_VERSION", r'longhorn/longhorn \\\n\s+--namespace longhorn-system \\\n\s+--version (\S+)'),
         ("TRAEFIK_VERSION", r'traefik/traefik \\\n\s+--namespace traefik \\\n\s+--version (\S+)'),
         ("PROMETHEUS_STACK_VERSION", r'prometheus-community/kube-prometheus-stack" "monitoring" \\\n\s+--version (\S+)'),
         ("LOKI_VERSION", r'grafana/loki-stack" "monitoring" \\\n\s+--version (\S+)'),
         ("ARGOCD_VERSION", r'argo/argo-cd" "argocd" \\\n\s+--version (\S+)')]
for var, pat in pairs:
    check("versions.sh sets %s=%s" % (var, vals.get(var)), bool(vals.get(var)))
    m = re.search(pat, now)
    check("bootstrap uses $%s" % var, m and m.group(1) == '"$%s"' % var, m and m.group(1))
check("every $..._VERSION bootstrap uses is set in versions.sh",
      not (set(re.findall(r'--version "\$([A-Z0-9_]+_VERSION)"', now)) - set(vals)),
      set(re.findall(r'--version "\$([A-Z0-9_]+_VERSION)"', now)) - set(vals))
check("MetalLB chart version has no v prefix (compared to helm chart name)", not vals.get("METALLB_VERSION", "v").startswith("v"))
left = re.findall(r'--version\s+v?\d[\w.]*\s*(?:\\|$)', now, re.M)
check("no hardcoded --version left in bootstrap", not left, left)
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
