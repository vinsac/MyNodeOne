#!/bin/bash

# Runs every storage test. They use stubs, need no root or cluster, and never touch
# a real disk. Needs python3, jq and PyYAML.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for test_file in test-disk-safety.sh test-longhorn-disks.sh test-velero-config.sh test-minio-cleanup.sh test-minio-install.sh test-backup.sh test-misc.sh; do
    echo "=== $test_file"
    if ! bash "$TESTS_DIR/$test_file"; then
        status=1
        echo "=== $test_file FAILED"
    fi
    echo
done
exit "$status"
