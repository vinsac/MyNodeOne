#!/usr/bin/env python3
"""Evaluates manifests/networkpolicy.yaml against the traffic the llmapi pods need.

Labels, Service selectors, target ports and PGHOST all come from the real manifests, so
renaming a label on either side of a rule fails here. This implements the Kubernetes
NetworkPolicy rules as documented. It is not a CNI: it can't show that kube-router
enforces them, or what source address a packet has when it reaches the policy.

Usage: check_networkpolicy.py [--networkpolicy FILE]
"""

import argparse
import sys
from pathlib import Path

import yaml

APP_DIR = Path(__file__).resolve().parents[1]
BACKUP_DIR = APP_DIR.parents[1] / "backup"
NAMESPACE = "llmapi"

WORKLOAD_FILES = [
    APP_DIR / "manifests" / name
    for name in ("gateway-deployment.yaml", "gateway.yaml", "postgres.yaml", "redis.yaml",
                 "vllm.yaml", "llamacpp.yaml", "embedding.yaml", "ollama.yaml")
] + [BACKUP_DIR / "llmapi-postgres-backup.yaml", BACKUP_DIR / "llmapi-postgres-restore-job.yaml"]

# Traffic from outside the namespace. Pod selectors without a namespaceSelector can't match
# these: a client or node address after kube-proxy, and Prometheus in another namespace.
EXTERNAL = {"namespace": None, "labels": {}}
PROMETHEUS = {"namespace": "monitoring", "labels": {"app.kubernetes.io/name": "prometheus"}}


def load_all(path):
    with open(path) as f:
        return [doc for doc in yaml.safe_load_all(f) if doc]


def pod_template(doc):
    kind = doc["kind"]
    if kind == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]
    if kind in ("Deployment", "StatefulSet", "Job"):
        return doc["spec"]["template"]
    return None


class Cluster:
    def __init__(self, policy_file):
        self.workloads, self.services = {}, {}
        for path in WORKLOAD_FILES:
            for doc in load_all(path):
                name = doc["metadata"]["name"]
                template = pod_template(doc)
                if template:
                    self.workloads[name] = template
                elif doc["kind"] == "Service":
                    self.services[name] = doc
        self.policies = [d for d in load_all(policy_file) if d["kind"] == "NetworkPolicy"]

    def source(self, workload):
        return {"namespace": NAMESPACE, "labels": self.workloads[workload]["metadata"]["labels"]}

    def env(self, workload, variable):
        for container in self.workloads[workload]["spec"]["containers"]:
            for entry in container.get("env", []):
                if entry["name"] == variable:
                    return entry["value"]
        raise KeyError(f"{workload} doesn't set {variable}")

    def resolve(self, service, port):
        """What a connection to a Service port reaches: pod labels and the pod's port."""
        spec = self.services[service]["spec"]
        for entry in spec["ports"]:
            if port in (entry["port"], entry.get("name")):
                target = entry.get("targetPort", entry["port"])
                if not isinstance(target, int):
                    raise ValueError(f"{service}: named targetPort {target} isn't handled")
                return spec["selector"], target
        raise KeyError(f"Service {service} has no port {port}")

    def allows(self, source, pod_labels, port):
        selecting = [
            p for p in self.policies
            if "Ingress" in p["spec"].get("policyTypes", ["Ingress"])
            and _matches(p["spec"]["podSelector"], pod_labels)
        ]
        if not selecting:
            return True  # A pod no policy selects isn't isolated.
        return any(
            _rule_allows(rule, source, port)
            for policy in selecting
            for rule in policy["spec"].get("ingress") or []
        )


def _matches(selector, labels):
    extra = set(selector) - {"matchLabels"}
    if extra:
        raise ValueError(f"selector fields not handled here: {extra}")
    return all(labels.get(k) == v for k, v in (selector.get("matchLabels") or {}).items())


def _rule_allows(rule, source, port):
    ports = rule.get("ports")
    if ports:
        for entry in ports:
            if set(entry) - {"protocol", "port"}:
                raise ValueError(f"port fields not handled here: {entry}")
        if not any(entry["port"] == port and entry.get("protocol", "TCP") == "TCP" for entry in ports):
            return False
    peers = rule.get("from")
    if not peers:
        return True  # No `from` means any source.
    for peer in peers:
        if set(peer) != {"podSelector"}:
            raise ValueError(f"peer fields not handled here: {peer}")
        if source["namespace"] == NAMESPACE and _matches(peer["podSelector"], source["labels"]):
            return True
    return False


def check(policy_file):
    cluster = Cluster(policy_file)
    failures = 0

    def report(ok, description):
        nonlocal failures
        print(f"{'ok  ' if ok else 'FAIL'} - {description}")
        failures += 0 if ok else 1

    def flow(expected, label, source, service, port):
        labels, target = cluster.resolve(service, port)
        word = "allowed" if expected else "denied"
        report(cluster.allows(source, labels, target) == expected, f"{word}: {label} -> {service}:{port}")

    gateway = cluster.source("gateway")
    backup = cluster.source("llmapi-postgres-backup")
    restore = cluster.source("llmapi-postgres-restore")
    vllm = cluster.source("vllm")
    llamacpp = cluster.source("llamacpp")
    embedding = cluster.source("embedding")

    # The jobs connect to whatever PGHOST names, so read it rather than assume it.
    flow(True, "backup CronJob", backup, cluster.env("llmapi-postgres-backup", "PGHOST"), 5432)
    flow(True, "restore Job", restore, cluster.env("llmapi-postgres-restore", "PGHOST"), 5432)

    for service, port in (("redis", 6379), ("llmapi-postgres", 5432), ("vllm", 8000),
                          ("llamacpp", 8080), ("embedding", 8080), ("ollama", 11434)):
        flow(True, "gateway", gateway, service, port)

    flow(True, "LoadBalancer path (external source)", EXTERNAL, "llmapi", 80)
    flow(True, "external source", EXTERNAL, "llmapi-internal", 8000)
    flow(True, "Prometheus, ServiceMonitor port", PROMETHEUS, "llmapi", "http")

    for service, port in (("redis", 6379), ("vllm", 8000), ("llamacpp", 8080),
                          ("embedding", 8080), ("ollama", 11434)):
        flow(False, "backup CronJob", backup, service, port)

    for label, source in (("vllm", vllm), ("llamacpp", llamacpp), ("embedding", embedding)):
        flow(False, label, source, "redis", 6379)
        flow(False, label, source, "llmapi-postgres", 5432)

    for service, port in (("redis", 6379), ("llmapi-postgres", 5432), ("vllm", 8000),
                          ("llamacpp", 8080), ("embedding", 8080), ("ollama", 11434)):
        flow(False, "external source", EXTERNAL, service, port)
        flow(False, "Prometheus", PROMETHEUS, service, port)

    report(not cluster.allows(gateway, cluster.resolve("llmapi-postgres", 5432)[0], 6379),
           "denied: gateway -> Postgres pod on a port it doesn't serve")

    # Structure that the flows above can't show.
    deny = [p for p in cluster.policies if p["metadata"]["name"] == "default-deny-ingress"]
    report(len(deny) == 1 and deny[0]["spec"]["podSelector"] == {} and "ingress" not in deny[0]["spec"],
           "default-deny-ingress selects every pod and allows nothing")
    report(all(p["metadata"].get("namespace") == NAMESPACE for p in cluster.policies),
           f"every policy is in namespace {NAMESPACE}")
    # DNS and model downloads depend on this: any Egress policy would need its own DNS rule.
    report(all("Egress" not in p["spec"].get("policyTypes", []) and "egress" not in p["spec"]
               for p in cluster.policies),
           "no policy restricts egress, so DNS and model downloads stay open")

    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--networkpolicy", default=APP_DIR / "manifests" / "networkpolicy.yaml")
    args = parser.parse_args()
    failures = check(args.networkpolicy)
    print(f"\n{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
