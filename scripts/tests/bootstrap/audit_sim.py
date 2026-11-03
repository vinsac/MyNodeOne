#!/usr/bin/env python3
"""First-match simulator for audit-policy.yaml, following the API server's rule matching."""
import fnmatch, pathlib, sys
try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed")
    sys.exit(77)
repo = pathlib.Path(__file__).resolve().parents[3]
policy = yaml.safe_load(open(repo / "manifests/security/audit-policy.yaml"))
rules = policy["rules"]

def match(rule, user, groups, verb, group, resource, url=None):
    if rule.get("users") and user not in rule["users"]:
        return False
    if rule.get("userGroups") and not set(rule["userGroups"]) & set(groups):
        return False
    if rule.get("verbs") and verb not in rule["verbs"]:
        return False
    if rule.get("nonResourceURLs"):
        if url is None:
            return False
        return any(fnmatch.fnmatch(url, p) for p in rule["nonResourceURLs"])
    if rule.get("resources"):
        if url is not None:
            return False
        for r in rule["resources"]:
            if r.get("group", "") != group:
                continue
            if not r.get("resources") or resource in r["resources"]:
                return True
        return False
    return True

def level(user, groups, verb, group, resource, url=None):
    for r in rules:
        if match(r, user, groups, verb, group, resource, url):
            return r["level"]
    return "None"

cases = [
    ("admin reads secret", ("system:admin", ["system:masters"], "get", "", "secrets"), "Metadata"),
    ("admin writes secret", ("system:admin", ["system:masters"], "create", "", "secrets"), "Metadata"),
    ("admin patches secret", ("admin", ["system:masters"], "patch", "", "secrets"), "Metadata"),
    ("node watches secret", ("system:node:n1", ["system:nodes"], "watch", "", "secrets"), "Metadata"),
    ("longhorn SA reads secret", ("system:serviceaccount:longhorn-system:x", ["system:serviceaccounts:longhorn-system"], "get", "", "secrets"), "Metadata"),
    ("admin writes configmap", ("system:admin", ["system:masters"], "update", "", "configmaps"), "Metadata"),
    ("SA token request", ("system:node:n1", ["system:nodes"], "create", "", "serviceaccounts/token"), "Metadata"),
    ("tokenreview", ("system:apiserver", [], "create", "authentication.k8s.io", "tokenreviews"), "Metadata"),
    ("admin creates pod (inline env)", ("system:admin", ["system:masters"], "create", "", "pods"), "Metadata"),
    ("admin patches deployment (inline env)", ("system:admin", ["system:masters"], "patch", "apps", "deployments"), "Metadata"),
    ("admin creates cronjob", ("system:admin", ["system:masters"], "create", "batch", "cronjobs"), "Metadata"),
    ("pod exec", ("system:admin", ["system:masters"], "create", "", "pods/exec"), "Metadata"),
    ("lease update", ("system:node:n1", ["system:nodes"], "update", "coordination.k8s.io", "leases"), "None"),
    ("admin lease read", ("system:admin", ["system:masters"], "get", "coordination.k8s.io", "leases"), "None"),
    ("event write", ("system:node:n1", ["system:nodes"], "create", "", "events"), "None"),
    ("healthz", ("system:anonymous", [], "get", None, None, "/healthz"), "None"),
    ("readyz subpath", ("system:anonymous", [], "get", None, None, "/readyz/etcd"), "None"),
    ("kubelet reads pods", ("system:node:n1", ["system:nodes"], "list", "", "pods"), "None"),
    ("controller reads", ("system:kube-controller-manager", [], "watch", "apps", "deployments"), "None"),
    ("longhorn CR write", ("system:serviceaccount:longhorn-system:x", ["system:serviceaccounts:longhorn-system"], "update", "longhorn.io", "volumes"), "None"),
    ("admin writes clusterrolebinding", ("system:admin", ["system:masters"], "create", "rbac.authorization.k8s.io", "clusterrolebindings"), "Request"),
    ("admin patches service", ("system:admin", ["system:masters"], "patch", "", "services"), "Request"),
    ("admin reads service", ("system:admin", ["system:masters"], "get", "", "services"), "Metadata"),
    ("admin writes longhorn CR", ("system:admin", ["system:masters"], "patch", "longhorn.io", "settings"), "Metadata"),
    ("unknown CRD write", ("system:admin", ["system:masters"], "create", "traefik.io", "ingressroutes"), "Metadata"),
    ("non-resource other", ("system:admin", ["system:masters"], "get", None, None, "/api"), "Metadata"),
]
fails = 0
for name, args, want in cases:
    got = level(*args)
    ok = got == want
    print(("PASS" if ok else "FAIL"), name, "->", got, "" if ok else "(wanted %s)" % want)
    fails += not ok

first = rules[0]
assert any("secrets" in r.get("resources", []) for r in first["resources"]), "Secrets rule must be first"
assert first["level"] == "Metadata"
print("PASS first rule is the Secrets rule at Metadata")
levels = {r["level"] for r in rules}
assert "RequestResponse" not in levels
print("PASS no RequestResponse rule anywhere; levels:", sorted(levels))
for r in rules:
    if r["level"] == "Request":
        for res in r.get("resources", []):
            assert res.get("group") not in ("apps", "batch"), res
            for name in res.get("resources", []):
                assert name not in ("secrets", "configmaps", "pods"), name
print("PASS no Request rule covers secrets, configmaps, pods, apps or batch")
VERBS = {"get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"}
assert policy["apiVersion"] == "audit.k8s.io/v1" and policy["kind"] == "Policy"
for r in rules:
    assert r["level"] in ("None", "Metadata", "Request", "RequestResponse")
    assert not (r.get("nonResourceURLs") and (r.get("resources") or r.get("namespaces"))), r
    assert set(r.get("verbs", [])) <= VERBS, r
    for u in r.get("nonResourceURLs", []):
        assert u.startswith("/") and "*" not in u[:-1], u
print("PASS policy fields satisfy the API server's validation rules")
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
