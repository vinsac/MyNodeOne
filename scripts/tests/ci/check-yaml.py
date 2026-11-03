#!/usr/bin/env python3
"""Parses every tracked YAML file, then validates the Kubernetes ones with kubeconform.

A file listed below has a known problem. It's expected to fail, and the run also fails
once it stops failing, so a fix has to remove it from the list.

KUBECONFORM overrides the command. Without kubeconform, that half is skipped and says
so, and in CI (CI=true) that's a failure.
"""
import os
import pathlib
import shutil
import subprocess
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]

# Files expected not to parse, with the reason. None at the moment.
EXPECTED_PARSE_FAILURES = {}

# Parse fine but aren't Kubernetes objects, so there's nothing to validate.
NOT_KUBERNETES = {
    "external-apps/examples/saas-fullstack/docker-compose.yml",
    "external-apps/examples/simple-web-app/docker-compose.yml",
    "scripts/monitoring/alertmanager-values.example.yaml",
    "scripts/monitoring/kube-prometheus-stack-values.yaml",
}

# Fail kubeconform on purpose. install-minio.sh substitutes MINIO_UID_PLACEHOLDER with
# sed, so the file has a string where the schema wants a number until it's installed.
EXPECTED_SCHEMA_FAILURES = {
    "scripts/storage/minio/manifests/statefulset.yaml",
}

KUBERNETES_VERSION = "1.31.0"  # K3S_VERSION in scripts/lib/versions.sh
# kubernetes-json-schema has no releases, and master moves, so pin a commit.
SCHEMA_COMMIT = "e0c72a1bc5f409d1685c0e1323460c8a98cd7459"
SCHEMA_LOCATION = (
    f"https://raw.githubusercontent.com/yannh/kubernetes-json-schema/{SCHEMA_COMMIT}/"
    "{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
)


def tracked_yaml():
    out = subprocess.run([str(HERE / "tracked-files.sh"), "*.yaml", "*.yml"], check=True, capture_output=True, text=True)
    return out.stdout.split("\n")[:-1]


def parse_all(files):
    problems = 0
    for file in files:
        expected = file in EXPECTED_PARSE_FAILURES
        try:
            with open(REPO / file) as stream:
                list(yaml.safe_load_all(stream))
        except yaml.YAMLError as error:
            if expected:
                print(f"expected failure: {file}: {EXPECTED_PARSE_FAILURES[file]}")
            else:
                print(f"FAIL {file}: {' '.join(str(error).split())}")
                problems += 1
        else:
            if expected:
                print(f"FAIL {file} parses now. Remove it from EXPECTED_PARSE_FAILURES in {pathlib.Path(__file__).name}.")
                problems += 1
    print(f"yaml: {len(files)} files, {len(EXPECTED_PARSE_FAILURES)} expected failures, {problems} problems")
    return problems


def kubeconform(tool, file):
    return subprocess.run(
        [tool, "-kubernetes-version", KUBERNETES_VERSION, "-schema-location", SCHEMA_LOCATION,
         "-ignore-missing-schemas", "-output", "text", file],
        cwd=REPO, capture_output=True, text=True,
    )


def validate_all(files):
    tool = os.environ.get("KUBECONFORM") or shutil.which("kubeconform")
    if not tool:
        if os.environ.get("CI"):
            print("FAIL kubeconform is not installed, and CI requires it")
            return 1
        print("SKIP kubeconform is not installed, so the manifests were not checked against the Kubernetes schemas")
        return 0
    problems = 0
    candidates = [
        f for f in files
        if f not in EXPECTED_PARSE_FAILURES and f not in NOT_KUBERNETES and not f.startswith(".github/")
    ]
    for file in candidates:
        done = kubeconform(tool, file)
        expected = file in EXPECTED_SCHEMA_FAILURES
        if done.returncode == 0 and expected:
            print(f"FAIL {file} validates now. Remove it from EXPECTED_SCHEMA_FAILURES in {pathlib.Path(__file__).name}.")
            problems += 1
        elif done.returncode != 0 and expected:
            print(f"expected failure: {file}: has an install-time placeholder")
        elif done.returncode != 0:
            print(f"FAIL {file}:\n{done.stdout}{done.stderr}")
            problems += 1
    print(f"kubeconform: {len(candidates)} files against Kubernetes {KUBERNETES_VERSION}, "
          f"{len(EXPECTED_SCHEMA_FAILURES)} expected failures, {problems} problems")
    return problems


def main():
    files = tracked_yaml()
    problems = parse_all(files)
    problems += validate_all(files)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
