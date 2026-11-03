#!/bin/bash
# Prints the repo's files matching the given git pathspecs, one per line and relative
# to the repo root. In a clean checkout that is the tracked files. With uncommitted
# work it also takes new files that aren't ignored and drops deleted ones, so a local
# run sees what the commit will contain. Agent worktrees under .claude/ never count.
#
#   scripts/tests/ci/tracked-files.sh '*.sh'

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
git ls-files --cached --others --exclude-standard -- "$@" |
    grep -v '^\.claude/' |
    sort -u |
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            printf '%s\n' "$file"
        fi
    done
