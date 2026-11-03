#!/usr/bin/env python3
"""Checks the gateway's dependencies in the environment this runs in.

Every third-party module main.py imports must come from a distribution listed in
requirements.lock, and every installed distribution the lock lists must be at the
locked version, so the tests can't pass against something the image won't run. Then
imports main.py, as the image does, to catch anything that only fails at load.

Run it with the gateway's Python, right after installing requirements.lock and before
adding the dev requirements, so test-only packages can't hide a missing dependency.
"""
import ast
import importlib.metadata
import pathlib
import re
import sys

GATEWAY = pathlib.Path(__file__).resolve().parents[2] / "apps" / "llmapi" / "gateway"


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def locked_versions():
    pairs = re.findall(r"^([A-Za-z0-9_.-]+)==(\S+)", (GATEWAY / "requirements.lock").read_text(), re.M)
    return {normalize(name): version for name, version in pairs}


def imported_modules():
    modules = set()
    for node in ast.walk(ast.parse((GATEWAY / "main.py").read_text())):
        if isinstance(node, ast.Import):
            modules.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0:
            modules.add(node.module.split(".")[0])
    return sorted(modules - set(sys.stdlib_module_names))


def main():
    locked = locked_versions()
    providers = importlib.metadata.packages_distributions()
    problems = 0

    for module in imported_modules():
        distributions = [normalize(name) for name in providers.get(module, [])]
        if any(name in locked for name in distributions):
            print(f"ok   import {module}: {' '.join(name for name in distributions if name in locked)}")
        else:
            print(f"FAIL import {module}: not provided by anything in requirements.lock (installed from: {distributions})")
            problems += 1

    for name, version in sorted(locked.items()):
        try:
            installed = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            print(f"FAIL {name}=={version} is locked but not installed")
            problems += 1
            continue
        if installed != version:
            print(f"FAIL {name}: locked {version}, installed {installed}")
            problems += 1

    sys.path.insert(0, str(GATEWAY))
    try:
        import main as gateway  # noqa: F401
        print("ok   import main")
    except Exception as error:
        print(f"FAIL import main: {type(error).__name__}: {error}")
        problems += 1

    print(f"gateway dependencies: {len(locked)} locked, {problems} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
