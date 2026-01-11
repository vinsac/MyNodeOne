# Hardcoded Domain Fallbacks in MyNodeOne Scripts

## ✅ COMPLETED - Domain Standardization

All hardcoded domain fallbacks have been successfully standardized to use `mynodeone` as the default.

### Summary of Changes

**Standardized from → to:**
- `minicloud` → `mynodeone`
- `mycloud` → `mynodeone`
- `atomcloud` → `mynodeone`
- `nanocloud` → `mynodeone` (examples only)
- `microcloud` → `mynodeone` (examples only)

### Commits

- **Commit `372d9da`**: Standardized all code fallbacks (17 files)
- **Commit `dae2763`**: Updated examples and comments (7 files)

### Scripts Updated

#### Code Standardization (17 scripts)
- scripts/apps/immich/install-immich.sh
- scripts/apps/minio/install-minio.sh
- scripts/apps/paperless/post-public-hook.sh
- scripts/install-node-agent.sh
- scripts/lib/validate-installation.sh
- scripts/sync-dns.sh
- scripts/manage-app-visibility.sh
- scripts/storage/longhorn/install-interactive.sh
- scripts/deploy-demo-app.sh
- scripts/sync-vps-routes.sh
- scripts/fix-duplicate-dns.sh
- scripts/setup-management-node.sh
- scripts/validate-cluster.sh
- scripts/lib/post-install-routing.sh
- scripts/lib/service-validation.sh
- scripts/lib/dns-validation.sh
- scripts/storage/minio/install-minio.sh

#### Documentation & Examples (7 files)
- examples/storage/app-with-minio-backup.yaml
- scripts/setup-local-dns.sh
- scripts/lib/validate-installation.sh
- scripts/lib/service-registry.sh
- scripts/lib/node-registry-manager.sh
- scripts/add-worker-node.sh
- scripts/fix-duplicate-dns.sh

### Impact

- **Consistency**: Single standard domain across entire codebase
- **Non-breaking**: Existing installations continue to work
- **Flexibility**: Users can override via `CLUSTER_DOMAIN` environment variable
- **Safety**: Eliminates DNS conflicts from mixed domain names

### How It Works Now

All scripts follow this pattern:
```bash
# Check config file first
if [[ -f "$HOME/.mynodeone/config.env" ]]; then
    source "$HOME/.mynodeone/config.env"
fi

# Use configured domain or fallback to mynodeone
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
```

Users can override by setting:
```bash
export CLUSTER_DOMAIN="my-custom-domain"
```

## ✅ ALL STANDARDIZED

No more hardcoded domain fallbacks exist in the repository.
