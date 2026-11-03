#!/bin/bash
###############################################################################
# Cleanup Generic MinIO Aliases
# 
# Removes old generic minio/minio-api/minio-console entries from service registry
# Run this on control plane after fresh install to clean up stale entries
###############################################################################

set -euo pipefail

# shellcheck source=../lib/service-registry-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/service-registry-lib.sh"

# A generic alias under either key format. Real per-node entries such as
# minio-node1/minio have a service field of minio too, so that field can't be used.
GENERIC_MINIO_JQ='def generic_minio:
    (.value.legacy_key // .key) as $name
    | (["minio", "minio-api", "minio-console"] | index($name)) != null;'

remove_generic_minio() {
    jq -c "$GENERIC_MINIO_JQ"' with_entries(select(generic_minio | not))'
}

echo "Cleaning up generic MinIO aliases from service registry..."

# A failed read isn't an empty registry: nothing has been checked yet.
if ! SERVICES=$(sr_get_services); then
    echo "✗ Could not read the service registry; nothing changed" >&2
    exit 1
fi

if [ "$SERVICES" = "{}" ]; then
    echo "✓ No service registry found (nothing to clean)"
    exit 0
fi

# Check for generic aliases
GENERIC_KEYS=$(jq -r "$GENERIC_MINIO_JQ"' to_entries[] | select(generic_minio) | .key' <<<"$SERVICES")

if [ -z "$GENERIC_KEYS" ]; then
    echo "✓ No generic MinIO aliases found"
    exit 0
fi

echo "Found generic MinIO aliases, removing:"
sed 's/^/  - /' <<<"$GENERIC_KEYS"

# Remove generic entries. The write is conditional on what was read, so it can't lose
# another writer's change. A generic entry still backed by a real Service comes back
# from the next sync.
if ! sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" remove_generic_minio; then
    echo "✗ Could not update the service registry; nothing changed" >&2
    exit 1
fi

echo "✓ Generic MinIO aliases removed"
echo ""
echo "Remaining MinIO services:"
sr_get_services | \
    jq -r 'to_entries[] | select((.value.legacy_key // .key) | startswith("minio")) | "  - \(.key) → \(.value.local_name // .value.subdomain // "unnamed") (\(.value.ip // "pending"))"' || \
    echo "  (could not read the registry to list them)"

echo ""
echo "Run DNS sync to update /etc/hosts:"
echo "  sudo ./scripts/domains/sync-dns.sh"
