#!/bin/bash

###############################################################################
# DNS Sync Script for Management Laptops
# 
# Fetches service registry from control plane and updates /etc/hosts
# Run this on management laptops to sync DNS entries
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    export ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6 2>/dev/null || echo "/home/$ACTUAL_USER")
fi

# Always ensure PROJECT_ROOT is set (needed for sourcing other scripts)
if [ -z "${PROJECT_ROOT:-}" ]; then
    # Get script directory and project root using standardized utility
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Bootstrap with fallback pattern (auto-discovers if path is wrong)
    source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
    source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
    source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null
fi

# Source K8s utilities for robust KUBECONFIG detection
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"
export_k8s_config || true
# shellcheck source=../lib/service-registry-lib.sh
source "$PROJECT_ROOT/scripts/lib/service-registry-lib.sh"

# Tests point this at a temp file.
HOSTS_FILE="${MYNODEONE_HOSTS_FILE:-/etc/hosts}"

# One writer per host. Installers call this script directly, but where the node agent
# owns the file it would only fight the agent's block, so it stands down: the agent
# picks the change up at its next poll. sr_hosts_writer answers "timer" while the timer
# is enabled, stopped or not, and with no writer at all this is the writer. A start of
# the timer's own service always runs, even with the timer disabled: someone asked for
# it by name. systemd puts that service's name in its cgroup, so this works with unit
# files already installed. Nothing here calls back into sr_refresh_hosts.
started_as_timer_service() {
    grep -q 'mynodeone-local-dns-sync\.service' "${MYNODEONE_CGROUP_FILE:-/proc/self/cgroup}" 2>/dev/null
}
if [[ "$(sr_hosts_writer)" == "agent" ]] && ! started_as_timer_service; then
    log_info "The node agent manages $HOSTS_FILE on this host; it applies changes at its next poll"
    exit 0
fi

# Load configuration
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Syncing DNS Entries from Control Plane"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Fetch cluster domain with priority: config file > ConfigMap > default
# Priority 1: Config file (already loaded above, most reliable source)
if [[ -z "${CLUSTER_DOMAIN:-}" ]]; then
    # Priority 2: ConfigMap (if kubectl is available and config file didn't have it)
    if command -v kubectl &>/dev/null; then
        # Ensure we use correct KUBECONFIG even under sudo
        CLUSTER_DOMAIN=$(KUBECONFIG="${KUBECONFIG:-$ACTUAL_HOME/.kube/config}" kubectl get cm cluster-info -n kube-system -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
        if [[ -n "$CLUSTER_DOMAIN" ]]; then
            log_info "Using cluster domain from cluster: $CLUSTER_DOMAIN"
        fi
    fi
    
    # Priority 3: Default fallback
    if [[ -z "$CLUSTER_DOMAIN" ]]; then
        CLUSTER_DOMAIN="mynodeone"
        log_warn "Could not fetch cluster domain from cluster, using: $CLUSTER_DOMAIN"
    fi
else
    log_info "Using cluster domain from config: $CLUSTER_DOMAIN"
fi

if ! sr_valid_cluster_domain "$CLUSTER_DOMAIN"; then
    log_warn "Cluster domain is not a valid DNS name; leaving $HOSTS_FILE unchanged"
    exit 1
fi

# Fetch the registry into REGISTRY_JSON. A failed or blank read is an error and
# must leave /etc/hosts alone: only a registry we actually read can remove entries.
REGISTRY_JSON=""

# Check if kubectl is configured
if ! command -v kubectl &>/dev/null; then
    log_warn "kubectl not found, attempting to fetch via SSH..."

    # Try SSH method
    CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
    CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        echo "Error: kubectl not configured and control plane IP not found"
        echo ""
        echo "Please either:"
        echo "  1. Configure kubectl access to the cluster"
        echo "  2. Set CONTROL_PLANE_IP in ~/.mynodeone/config.env"
        exit 1
    fi

    log_info "Fetching DNS entries from $CONTROL_PLANE_IP via SSH..."

    if ! raw_registry=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}'" 2>/dev/null); then
        log_warn "Could not read the registry from $CONTROL_PLANE_IP; leaving $HOSTS_FILE unchanged"
        exit 1
    fi
    if ! REGISTRY_JSON=$(jq -ce 'select(type == "object")' <<<"$raw_registry" 2>/dev/null); then
        log_warn "Registry from $CONTROL_PLANE_IP is blank or invalid; leaving $HOSTS_FILE unchanged"
        exit 1
    fi
else
    # Use kubectl directly
    log_info "Fetching DNS entries from cluster..."

    if ! REGISTRY_JSON=$(sr_get_services); then
        log_warn "Could not read the registry; leaving $HOSTS_FILE unchanged"
        exit 1
    fi
fi

# Registry values end up as lines in a root-owned file every local resolver trusts,
# and an annotation can set them. Only valid IPs and single DNS labels get through.
# \A and \z because `$` in jq also matches before a trailing newline.
JQ_HOSTS_FILTER='
def valid_ip:
    type == "string" and (
        test("\\A((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\z")
        or (test("\\A[0-9A-Fa-f:.]{2,45}\\z") and contains(":")));
def valid_name:
    type == "string"
    and test("\\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z")
    and ((ascii_downcase | IN("localhost", "localhost4", "localhost6", "broadcasthost",
         "ip6-localhost", "ip6-loopback", "ip6-allnodes", "ip6-allrouters",
         "ip6-localnet", "ip6-mcastprefix")) | not);
[ to_entries[] | .value | select(type == "object" and (.ip | valid_ip))
  | if .local_name == "" then
        "\(.ip)\t\($domain)"
    elif (.local_name | valid_name) then
        "\(.ip)\t\(.local_name).\($domain)",
        # Dashboard gets both local_name AND bare domain entries
        (if .local_name == "dashboard" then "\(.ip)\t\($domain)" else empty end)
    else
        empty
    end
] | unique | .[]'

if ! DNS_ENTRIES=$(jq -r --arg domain "${CLUSTER_DOMAIN}.local" "$JQ_HOSTS_FILTER" <<<"$REGISTRY_JSON"); then
    log_warn "Could not parse the registry; leaving $HOSTS_FILE unchanged"
    exit 1
fi

REGISTRY_COUNT=$(jq 'length' <<<"$REGISTRY_JSON")
if [[ -z "$DNS_ENTRIES" && "$REGISTRY_COUNT" -gt 0 ]]; then
    # Services without a valid IP yet, or all of them rejected above. That isn't the
    # same as a confirmed empty registry, so existing entries stay.
    log_warn "No services found in registry with a usable IP and hostname"
    exit 0
fi

# Build the new file: everything except the managed block and old MyNodeOne names.
# awk compares strings so the domain is never read as a regex.
#
# Runs of blank lines collapse to one and leading and trailing ones go, so a file the
# old version grew by a line a minute shrinks at the next run and can't grow again.
# NUL bytes go too: a zero-filled hole in the file is damage, not content, and any
# line with real text in it keeps that text. LC_ALL=C because the file may hold bytes
# that aren't valid in the current locale.
#
# A block ends at its blank line, or at the first line that isn't one of its entries,
# so a line someone added right below it survives.
HOSTS_WORK=$(mktemp -d)
trap 'rm -rf "$HOSTS_WORK"' EXIT
OLD_HOSTS="$HOSTS_WORK/old"
NEW_HOSTS="$HOSTS_WORK/new"

if ! cat "$HOSTS_FILE" >"$OLD_HOSTS"; then
    log_warn "Could not read $HOSTS_FILE"
    exit 1
fi

if ! tr -d '\000' <"$OLD_HOSTS" | HOSTS_DOMAIN="${CLUSTER_DOMAIN}.local" LC_ALL=C awk '
    function managed(name) {
        return name == domain || name == legacy ||
            (length(name) > length(suffix) && substr(name, length(name) - length(suffix) + 1) == suffix) ||
            (length(name) > length(lsuffix) && substr(name, length(name) - length(lsuffix) + 1) == lsuffix)
    }
    # A line this script or the node agent wrote: address, name.local, and from the agent
    # the short name. Both go together, or the short name would stay behind.
    function block_entry() {
        if ($1 ~ /^#/) return 0
        if (NF == 2) return $2 ~ /\.local$/
        return NF == 3 && $2 ~ /\.local$/ && index($2, $3 ".") == 1
    }
    BEGIN {
        domain = ENVIRON["HOSTS_DOMAIN"]; suffix = "." domain
        legacy = "mynodeone.local"; lsuffix = "." legacy
        blank_pending = 0; printed = 0; in_block = 0
    }
    # Markers are whole comment lines; a line that only quotes one is not ours.
    /^[[:space:]]*# MyNodeOne Services([[:space:]]+-.*)?[[:space:]]*$/ { in_block = 1; next }
    /^[[:space:]]*# MyNodeOne DNS entries([[:space:]]+[(].*)?[[:space:]]*$/ { in_block = 1; next }
    in_block {
        if (/^[[:space:]]*$/) { in_block = 0; next }
        if (block_entry()) next
        in_block = 0
    }
    # Elsewhere only the matching name goes. A comment after the names is not a name.
    !/^[[:space:]]*(#|$)/ {
        kept = ""; removed = 0; stop = NF + 1
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^#/) { stop = i; break }
            if (managed($i)) removed = 1
            else kept = kept " " $i
        }
        if (removed) {
            if (kept == "") next
            note = ""
            for (i = stop; i <= NF; i++) note = note " " $i
            $0 = $1 kept note
        }
    }
    /^[[:space:]]*$/ { blank_pending = 1; next }
    {
        if (blank_pending && printed) print ""
        blank_pending = 0; printed = 1
        print
    }
' >"$NEW_HOSTS"; then
    log_warn "Could not process $HOSTS_FILE"
    exit 1
fi

if [[ -n "$DNS_ENTRIES" ]]; then
    {
        echo ""
        echo "# MyNodeOne Services - Auto-synced on $(date)"
        printf '%s\n' "$DNS_ENTRIES"
        echo ""
    } >>"$NEW_HOSTS"
fi

# Prints a hosts file with the marker's timestamp removed, since that changes on every
# render. sed rather than grep: grep stops at the first NUL byte and calls the file
# binary, which would make two different files compare as equal and block every write.
without_timestamp() {
    LC_ALL=C sed 's/# MyNodeOne Services.*/# MyNodeOne Services/' "$1"
}

# Keeps the newest 5 backups and the oldest, which is the closest thing to the file
# from before MyNodeOne managed it. A glob here can exceed the argument limit, so the
# names come from find and rm runs in batches.
prune_hosts_backups() {
    LC_ALL=C find "$(dirname "$HOSTS_FILE")" -maxdepth 1 -type f \
        -name "$(basename "$HOSTS_FILE").backup.[0-9]*_[0-9]*" -printf '%T@\t%p\n' |
        LC_ALL=C awk '/\.backup\.[0-9]+_[0-9]+$/' |
        LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r |
        tail -n +6 | head -n -1 | cut -f2- | tr '\n' '\0' |
        xargs -0 -r sudo rm -f --
}

# The timer runs this every minute, so only a real change may cost a write and a backup.
if cmp -s <(without_timestamp "$OLD_HOSTS") <(without_timestamp "$NEW_HOSTS"); then
    log_success "DNS entries already up to date"
else
    log_info "Backing up $HOSTS_FILE..."
    sudo cp "$HOSTS_FILE" "$HOSTS_FILE.backup.$(date +%Y%m%d_%H%M%S)" || {
        log_warn "Could not back up $HOSTS_FILE; leaving it unchanged"
        exit 1
    }

    # Write in place, not sed -i or a rename. /etc/hosts can be a bind mount (it is
    # in containers and in a sandboxed unit), where replacing the file fails.
    log_info "Updating DNS entries..."
    if ! sudo tee "$HOSTS_FILE" <"$NEW_HOSTS" >/dev/null || ! sudo cmp -s "$NEW_HOSTS" "$HOSTS_FILE"; then
        log_warn "Could not write $HOSTS_FILE; restoring the previous contents"
        sudo tee "$HOSTS_FILE" <"$OLD_HOSTS" >/dev/null || log_warn "Restore failed; see the newest $HOSTS_FILE.backup.* file"
        exit 1
    fi

    # After the write, so that clearing a large pile of backups can't delay the update.
    prune_hosts_backups || log_warn "Could not prune old $HOSTS_FILE.backup.* files"
fi

# Count services
SERVICE_COUNT=$(printf '%s\n' "$DNS_ENTRIES" | grep -c -v '^$' || true)

# Defensive check: Ensure /etc/hosts has correct permissions
if [[ "$OSTYPE" == "darwin"* ]]; then
    HOSTS_PERMS=$(stat -f "%OLp" "$HOSTS_FILE" 2>/dev/null || echo "unknown")
else
    HOSTS_PERMS=$(stat -c "%a" "$HOSTS_FILE" 2>/dev/null || echo "unknown")
fi

if [ "$HOSTS_PERMS" != "644" ]; then
    log_warn "$HOSTS_FILE has permissions $HOSTS_PERMS, fixing to 644..."
    sudo chmod 644 "$HOSTS_FILE"
fi

if [[ -z "$DNS_ENTRIES" ]]; then
    log_warn "No services found in registry"
    echo ""
    echo "This might mean:"
    echo "  • Service registry is not initialized"
    echo "  • No apps are installed yet"
    echo ""
    echo "Run this on control plane to initialize:"
    # Use CONTROL_PLANE_REPO_PATH from config if available, otherwise use a generic path
    CONTROL_PLANE_PATH="${CONTROL_PLANE_REPO_PATH:-~/MyNodeOne}"
    echo "  sudo $CONTROL_PLANE_PATH/scripts/lib/service-registry.sh sync"
    exit 0
fi

log_success "DNS sync complete"
echo ""
echo "✅ Updated $SERVICE_COUNT service entries:"
printf '%s\n' "$DNS_ENTRIES" | sed 's/^/   /'
echo ""

# Test actual resolution with first service (may fail due to DNS caching)
FIRST_SERVICE=$(printf '%s\n' "$DNS_ENTRIES" | head -1 | awk '{print $2}')
if [ -n "$FIRST_SERVICE" ] && getent hosts "$FIRST_SERVICE" >/dev/null 2>&1; then
    log_success "DNS resolution verified ✓"
else
    log_info "DNS entries added successfully (resolution may take a moment due to caching)"
fi

log_info "You can now access services via .local domains"
echo ""
