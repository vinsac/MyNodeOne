# Hardcoded Domain Fallbacks in MyNodeOne Scripts

This document lists all hardcoded domain fallbacks found in the repository that should be replaced with environment variables or user input.

## Summary of Findings

**Hardcoded domains found:**
- `minicloud` (most common)
- `mynodeone` 
- `mycloud`
- `nanocloud`
- `microcloud`
- `atomcloud`

## Scripts with Hardcoded Domain Fallbacks

### 1. **scripts/apps/immich/install-immich.sh**
- **Line 45:** `CLUSTER_DOMAIN="${USER_CLUSTER_DOMAIN:-minicloud}"`
- **Context:** User prompt fallback when cluster domain not detected
- **Recommendation:** Keep as user prompt fallback, but make it configurable

### 2. **scripts/apps/minio/install-minio.sh**
- **Line 85:** `CLUSTER_DOMAIN=$(kubectl get configmap ... || echo "minicloud")`
- **Line 943:** `cluster_domain=$(kubectl get configmap ... || echo "atomcloud.local")`
- **Line 998:** `local CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-atomcloud.local}"`
- **Context:** Multiple fallbacks for MinIO installation
- **Recommendation:** Use environment variable or fail gracefully

### 3. **scripts/apps/paperless/post-public-hook.sh**
- **Line 38:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-minicloud}"`
- **Context:** Paperless app configuration
- **Recommendation:** Use environment variable

### 4. **scripts/install-node-agent.sh**
- **Line 282:** `CLUSTER_DOMAIN="minicloud"`
- **Context:** VPS node agent configuration
- **Recommendation:** Use environment variable

### 5. **scripts/lib/validate-installation.sh**
- **Line 178:** `local cluster_domain="${CLUSTER_DOMAIN:-minicloud}"`
- **Line 135:** `echo "$registry_json" | jq -r 'to_entries[] | "  • \(.value.subdomain).\(env.CLUSTER_DOMAIN // "minicloud").local → \(.value.ip)"'`
- **Context:** Installation validation
- **Recommendation:** Use environment variable

### 6. **scripts/sync-dns.sh**
- **Line 64:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** DNS synchronization
- **Recommendation:** Use environment variable

### 7. **website/deploy-dashboard.sh**
- **Line 27:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Dashboard deployment
- **Recommendation:** Use environment variable

### 8. **scripts/manage-app-visibility.sh**
- **Line 45:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"`
- **Context:** App visibility management
- **Recommendation:** Use environment variable

### 9. **scripts/storage/longhorn/install-interactive.sh**
- **Line 656:** `local cluster_domain="${CLUSTER_DOMAIN:-}"`
- **Line 663:** `echo -n "Please enter cluster domain (e.g., nanocloud): "`
- **Context:** Longhorn storage installation
- **Recommendation:** Keep user prompt, remove hardcoded example

### 10. **scripts/apps/jellyfin/install-jellyfin.sh**
- **Line 36:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Jellyfin media server
- **Recommendation:** Use environment variable

### 11. **scripts/apps/mattermost/install-mattermost.sh**
- **Line 36:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Mattermost team chat
- **Recommendation:** Use environment variable

### 12. **scripts/apps/llm-chat/install-llm-chat.sh**
- **Line 40:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** LLM Chat application
- **Recommendation:** Use environment variable

### 13. **scripts/apps/nextcloud/install-nextcloud.sh**
- **Line 36:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Nextcloud cloud storage
- **Recommendation:** Use environment variable

### 14. **scripts/setup-laptop.sh**
- **Line 35:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Laptop setup
- **Recommendation:** Use environment variable

### 15. **scripts/deploy-demo-app.sh**
- **Line 231:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"`
- **Context:** Demo app deployment
- **Recommendation:** Use environment variable

### 16. **scripts/apps/homepage/install-homepage.sh**
- **Line 98:** `CLUSTER_DOMAIN="mynodeone"`
- **Line 101:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Homepage app
- **Recommendation:** Use environment variable

### 17. **scripts/sync-vps-routes.sh**
- **Line 56:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"`
- **Context:** VPS route synchronization
- **Recommendation:** Use environment variable

### 18. **scripts/install-vps-edge-node.sh**
- **Line 159:** `"${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** VPS edge node installation
- **Recommendation:** Use environment variable

### 19. **scripts/update-laptop-dns.sh**
- **Line 42:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Laptop DNS update
- **Recommendation:** Use environment variable

### 20. **scripts/apps/llmapi/install-llmapi.sh**
- **Line 63:** `CLUSTER_DOMAIN=$(kubectl get configmap ... || echo "mynodeone")`
- **Line 65:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** LLM API installation
- **Recommendation:** Use environment variable

### 21. **scripts/setup-local-dns.sh**
- **Line 31:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"`
- **Context:** Local DNS setup
- **Recommendation:** Use environment variable

### 22. **scripts/validate-cluster.sh**
- **Line 33:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"`
- **Context:** Cluster validation
- **Recommendation:** Use environment variable

### 23. **scripts/setup-management-node.sh**
- **Line 253:** `LOCAL_DOMAIN="${CLUSTER_DOMAIN:-mycloud}.local"`
- **Context:** Management node setup
- **Recommendation:** Use environment variable

### 24. **scripts/lib/post-install-routing.sh**
- **Line 65:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"`
- **Context:** Post-install routing
- **Recommendation:** Use environment variable

### 25. **scripts/lib/service-validation.sh**
- **Line 204:** `local cluster_domain="${4:-mycloud}"`
- **Line 256:** `local cluster_domain="${1:-mycloud}"`
- **Context:** Service validation
- **Recommendation:** Use environment variable

### 26. **scripts/lib/dns-validation.sh**
- **Line 120:** `local cluster_domain="${1:-mycloud}"`
- **Context:** DNS validation
- **Recommendation:** Use environment variable

### 27. **setup-client-dns.sh** (root level)
- **Line 14:** `CLUSTER_DOMAIN="atomcloud"`
- **Context:** Client DNS setup
- **Recommendation:** Use environment variable

### 28. **scripts/add-worker-node.sh**
- **Line 582:** `log_info "  - Create node-specific .local domain (minio-<nodename>.atomcloud.local)"`
- **Context:** Worker node installation log message
- **Recommendation:** Use variable in log message

### 29. **scripts/fix-duplicate-dns.sh**
- **Line 100:** `echo "  3. Result: Single consistent entry (demo.minicloud.local)"`
- **Line 113:** `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"`
- **Context:** DNS cleanup script
- **Recommendation:** Use variable in example

### 30. **scripts/uninstall-mynodeone.sh**
- **Lines 472-475:** Removes entries for `mycloud`, `minicloud`, `mynodeone`
- **Context:** Uninstallation cleanup
- **Recommendation:** Keep for cleanup of old installations

## Configuration Files with Hardcoded Domains

### 1. **examples/storage/app-with-minio-backup.yaml**
- **Line 149:** `value: "minio-pc1.minicloud.local:9000"`
- **Context:** Example configuration
- **Recommendation:** Keep as example, but add comment about replacing

## Comments and Documentation with Hardcoded Domains

### 1. **scripts/setup-local-dns.sh**
- **Line 172:** `# Note: MinIO uses node-specific domains (minio-nodename.minicloud.local)`
- **Context:** Comment about MinIO domains
- **Recommendation:** Keep as documentation example

### 2. **scripts/lib/validate-installation.sh**
- **Line 189:** `# Special case: dashboard is at root domain (e.g., minicloud.local, not minicloud.minicloud.local)`
- **Context:** Comment about domain structure
- **Recommendation:** Keep as documentation example

### 3. **scripts/lib/service-registry.sh**
- **Line 457:** `service-registry.sh export-dns minicloud.local    # Explicit domain`
- **Context:** Help documentation example
- **Recommendation:** Keep as example

### 4. **scripts/lib/node-registry-manager.sh**
- **Line 964:** `--endpoint minio-pc1.minicloud.local:9000`
- **Context:** Help documentation example
- **Recommendation:** Keep as example

## Recommendations

### High Priority (Installation Scripts)
1. **Replace all `CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-<hardcoded>}"`** with:
   - Check environment variable first
   - Check config file second
   - Prompt user for input if not found
   - Fail gracefully if user doesn't provide

2. **Update installation flow** to:
   - Require CLUSTER_DOMAIN environment variable
   - Or prompt for it at the beginning of installation
   - Store it in config file for future use

### Medium Priority (App Installation Scripts)
1. **All app install scripts** should:
   - Read from config file
   - Use environment variable
   - Fail with clear error message if not found

### Low Priority (Utility Scripts)
1. **Validation and utility scripts** can:
   - Use environment variable
   - Have reasonable defaults for testing
   - Document the default in comments

### Keep As-Is
1. **Example files** (YAML, documentation)
2. **Uninstall script** (needs to clean up old domains)
3. **Comments and documentation** (examples are helpful)

## Proposed Solution Structure

```bash
# Standard pattern for all scripts:
get_cluster_domain() {
    # 1. Check environment variable
    if [[ -n "${CLUSTER_DOMAIN:-}" ]]; then
        echo "$CLUSTER_DOMAIN"
        return
    fi
    
    # 2. Check config file
    if [[ -f "$HOME/.mynodeone/config.env" ]]; then
        source "$HOME/.mynodeone/config.env"
        if [[ -n "${CLUSTER_DOMAIN:-}" ]]; then
            echo "$CLUSTER_DOMAIN"
            return
        fi
    fi
    
    # 3. Check ConfigMap (if kubectl available)
    if command -v kubectl &>/dev/null; then
        local domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null)
        if [[ -n "$domain" ]]; then
            echo "$domain"
            return
        fi
    fi
    
    # 4. Prompt user (for interactive scripts)
    if [[ -t 0 ]]; then
        read -p "Enter cluster domain: " CLUSTER_DOMAIN
        echo "${CLUSTER_DOMAIN:-}"
        return
    fi
    
    # 5. Fail for non-interactive scripts
    echo "ERROR: CLUSTER_DOMAIN not set" >&2
    return 1
}
```

## Next Steps

1. Review each script in the list above
2. Decide on the approach for each category
3. Implement the standard `get_cluster_domain()` function
4. Update scripts one by one
5. Test thoroughly to ensure no breaking changes
