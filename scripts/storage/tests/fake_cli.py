#!/usr/bin/env python3
"""Stands in for kubectl and velero, answering from a JSON scenario.

Called as: fake_cli.py <tool> [args...]
Environment:
  FAKE_SCENARIO  JSON file: {"kubectl": [rules], "velero": [rules]}
  FAKE_CLI_LOG   each call is appended here as "<tool> <args>"
  FAKE_STDIN_LOG stdin sent to `apply -f -` is appended here

A rule is {"match": <regex searched in the joined args>, "stdout": "", "rc": 0}.
The first matching rule answers. A call that matches nothing fails, so an
unexpected command shows up as an error rather than as an empty success.
"""
import json
import os
import re
import sys


def main():
    tool, args = sys.argv[1], sys.argv[2:]
    joined = ' '.join(args)
    with open(os.environ['FAKE_CLI_LOG'], 'a') as log:
        log.write(f'{tool} {joined}\n')

    if '-f -' in joined:
        data = sys.stdin.read()
        with open(os.environ['FAKE_STDIN_LOG'], 'a') as log:
            log.write(data + '\n---\n')

    with open(os.environ['FAKE_SCENARIO']) as f:
        rules = json.load(f).get(tool, [])
    for rule in rules:
        if re.search(rule['match'], joined):
            sys.stdout.write(rule.get('stdout', ''))
            if rule.get('stderr'):
                sys.stderr.write(rule['stderr'])
            return rule.get('rc', 0)
    sys.stderr.write(f'fake {tool}: no rule for: {joined}\n')
    return 1


if __name__ == '__main__':
    sys.exit(main())
