#!/bin/bash
# =============================================================================
# Sync Pre-Downloaded Models to Worker Nodes
# =============================================================================
# This script syncs pre-downloaded models from control plane to worker nodes
# for use with hostPath storage in multi-node deployments.
#
# Usage:
#   ./sync-models-to-workers.sh [worker_node_hostname]
#
# Examples:
#   ./sync-models-to-workers.sh canada-pc-0002
#   ./sync-models-to-workers.sh  # Syncs to all worker nodes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="/var/lib/llmapi/models"
DEST_DIR="/var/lib/llmapi/models"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# =============================================================================
# Get Worker Nodes
# =============================================================================

get_worker_nodes() {
    # Get worker nodes with their Tailscale IPs from labels
    kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
        -o json 2>/dev/null | jq -r '.items[] | .metadata.name + " " + (.metadata.labels["mynodeone.io/worker-ip"] // "")' || true
}

# =============================================================================
# Check SSH Access
# =============================================================================

check_ssh_access() {
    local node_ip="$1"
    local node_name="$2"  # Hostname for label lookup
    
    # All logging goes to stderr so only the username is returned to stdout
    info "Testing SSH access to $node_ip..." >&2
    
    # Try to detect the username
    local ssh_user=""
    
    # First, try to get username from node label (set during worker node setup)
    local labeled_user=""
    if [[ -n "$node_name" ]]; then
        labeled_user=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null)
    fi
    
    local users_to_try=()
    if [[ -n "$labeled_user" ]]; then
        info "  Found labeled SSH user: $labeled_user" >&2
        users_to_try=("$labeled_user")
    else
        info "  No mynodeone.io/ssh-user label found, trying common usernames..." >&2
        users_to_try=(vinaysachdeva vinaysachdeva2 vinay ubuntu)
    fi
    
    # Try each username
    for user in "${users_to_try[@]}"; do
        info "  Trying user: $user" >&2
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
           "${user}@${node_ip}" "echo connected" 2>&1 | tee /tmp/ssh-test-$user.log | grep -q "connected"; then
            ssh_user="$user"
            success "  ✓ SSH works with user: $user" >&2
            break
        else
            warn "  ✗ SSH failed for user: $user" >&2
            info "  Error details: $(cat /tmp/ssh-test-$user.log 2>/dev/null | head -3)" >&2
        fi
    done
    
    if [[ -z "$ssh_user" ]]; then
        warn "Could not determine SSH user for $node_ip." >&2
        warn "Ensure SSH key-based auth is set up for the worker node." >&2
        warn "Run: ssh-copy-id <username>@${node_ip}" >&2
        if [[ -n "$node_name" ]]; then
            warn "Or add label: kubectl label node $node_name mynodeone.io/ssh-user=<username>" >&2
        fi
        return 1
    fi
    
    # Only the username goes to stdout (captured by caller)
    echo "$ssh_user"
}

# =============================================================================
# Sync Models to Worker
# =============================================================================

sync_to_worker() {
    local node_ip="$1"
    local node_name="$2"  # Optional: hostname for label lookup
    
    info "Syncing models to worker node: $node_ip"
    echo ""
    
    # Check SSH access (only once, cache the result)
    local ssh_user
    ssh_user=$(check_ssh_access "$node_ip" "$node_name")
    if [[ $? -ne 0 ]]; then
        error "SSH access check failed for $node_ip"
        return 1
    fi
    
    info "Using SSH user: $ssh_user"
    echo ""
    
    # Check if source directory exists
    if [[ ! -d "$SOURCE_DIR" ]]; then
        warn "Source directory $SOURCE_DIR does not exist. No models to sync."
        return 1
    fi
    
    info "Source directory: $SOURCE_DIR"
    info "Contents:"
    ls -lh "$SOURCE_DIR" 2>/dev/null || warn "Cannot list source directory"
    echo ""
    
    # Create destination directory on worker
    info "Creating destination directory on $node_ip..."
    info "Command: ssh ${ssh_user}@${node_ip} \"sudo mkdir -p $DEST_DIR && sudo chown -R ${ssh_user}:${ssh_user} $DEST_DIR\""
    
    if ssh "${ssh_user}@${node_ip}" "sudo mkdir -p $DEST_DIR && sudo chown -R ${ssh_user}:${ssh_user} $DEST_DIR" 2>&1 | tee /tmp/ssh-mkdir.log; then
        success "Destination directory created: $DEST_DIR"
    else
        error "Failed to create destination directory on $node_ip"
        info "Error details: $(cat /tmp/ssh-mkdir.log 2>/dev/null)"
        return 1
    fi
    echo ""
    
    # Sync vLLM models
    if [[ -d "$SOURCE_DIR/vllm" ]]; then
        local vllm_size=$(du -sh "$SOURCE_DIR/vllm" 2>/dev/null | cut -f1)
        local vllm_files=$(find "$SOURCE_DIR/vllm" -type f | wc -l)
        info "Syncing vLLM models:"
        info "  Size: $vllm_size"
        info "  Files: $vllm_files"
        info "  Source: $SOURCE_DIR/vllm/"
        info "  Destination: ${ssh_user}@${node_ip}:${DEST_DIR}/vllm/"
        info "This may take several minutes depending on model size and network speed..."
        echo ""
        
        info "Running: rsync -av --progress -e \"ssh -o StrictHostKeyChecking=no\" ..."
        if rsync -av --progress \
            -e "ssh -o StrictHostKeyChecking=no" \
            "$SOURCE_DIR/vllm/" \
            "${ssh_user}@${node_ip}:${DEST_DIR}/vllm/" 2>&1 | tee /tmp/rsync-vllm.log; then
            success "vLLM models synced to $node_ip"
        else
            warn "Failed to sync vLLM models to $node_ip"
            info "Rsync error details:"
            tail -20 /tmp/rsync-vllm.log
            return 1
        fi
        echo ""
    else
        info "No vLLM models found at $SOURCE_DIR/vllm"
    fi
    
    # Sync llamacpp models
    if [[ -d "$SOURCE_DIR/llamacpp" ]]; then
        local llamacpp_size=$(du -sh "$SOURCE_DIR/llamacpp" 2>/dev/null | cut -f1)
        local llamacpp_files=$(find "$SOURCE_DIR/llamacpp" -type f | wc -l)
        info "Syncing llamacpp models:"
        info "  Size: $llamacpp_size"
        info "  Files: $llamacpp_files"
        echo ""
        
        if rsync -av --progress \
            -e "ssh -o StrictHostKeyChecking=no" \
            "$SOURCE_DIR/llamacpp/" \
            "${ssh_user}@${node_ip}:${DEST_DIR}/llamacpp/" 2>&1 | tee /tmp/rsync-llamacpp.log; then
            success "llamacpp models synced to $node_ip"
        else
            warn "Failed to sync llamacpp models to $node_ip"
            info "Rsync error details:"
            tail -20 /tmp/rsync-llamacpp.log
            return 1
        fi
        echo ""
    else
        info "No llamacpp models found at $SOURCE_DIR/llamacpp"
    fi
    
    # Sync embedding models
    if [[ -d "$SOURCE_DIR/embedding" ]]; then
        local embedding_size=$(du -sh "$SOURCE_DIR/embedding" 2>/dev/null | cut -f1)
        local embedding_files=$(find "$SOURCE_DIR/embedding" -type f | wc -l)
        info "Syncing embedding models:"
        info "  Size: $embedding_size"
        info "  Files: $embedding_files"
        echo ""
        
        if rsync -av --progress \
            -e "ssh -o StrictHostKeyChecking=no" \
            "$SOURCE_DIR/embedding/" \
            "${ssh_user}@${node_ip}:${DEST_DIR}/embedding/" 2>&1 | tee /tmp/rsync-embedding.log; then
            success "embedding models synced to $node_ip"
        else
            warn "Failed to sync embedding models to $node_ip"
            info "Rsync error details:"
            tail -20 /tmp/rsync-embedding.log
            return 1
        fi
        echo ""
    else
        info "No embedding models found at $SOURCE_DIR/embedding"
    fi
    
    # Fix permissions on worker
    info "Fixing permissions on $node_ip..."
    info "Command: ssh ${ssh_user}@${node_ip} \"sudo chown -R 1000:1000 $DEST_DIR && sudo chmod -R 755 $DEST_DIR\""
    
    # Use -t to allow sudo password prompt
    if ssh -t "${ssh_user}@${node_ip}" "sudo chown -R 1000:1000 $DEST_DIR && sudo chmod -R 755 $DEST_DIR" 2>&1 | tee /tmp/ssh-chown.log; then
        success "Permissions fixed on $node_ip"
    else
        warn "Failed to fix permissions on $node_ip"
        info "Error details: $(cat /tmp/ssh-chown.log 2>/dev/null)"
    fi
    echo ""
    
    success "All models synced to $node_ip successfully!"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📦 Sync Models to Worker Nodes${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Check if running on control plane
    if ! kubectl get nodes &>/dev/null; then
        error "Cannot access Kubernetes cluster. Run this on the control plane."
    fi
    
    # Get worker nodes
    local worker_data
    if [[ $# -gt 0 ]]; then
        local target_node="$1"
        local target_ip=""
        
        # Check if specific IP provided as second argument
        if [[ $# -gt 1 ]]; then
            target_ip="$2"
            worker_data="$target_node $target_ip"
            info "Using specified IP for sync: $target_ip"
        else
            # Try to get IP from label if hostname provided
            target_ip=$(kubectl get node "$target_node" -o jsonpath='{.metadata.labels.mynodeone\.io/worker-ip}' 2>/dev/null)
            
            if [[ -n "$target_ip" ]]; then
                worker_data="$target_node $target_ip"
            else
                # Assume the first argument is an IP if lookup failed
                worker_data="$target_node $target_node"
            fi
        fi
    else
        # Auto-detect all worker nodes
        worker_data=$(get_worker_nodes)
        if [[ -z "$worker_data" ]]; then
            warn "No worker nodes found in cluster."
            warn "Make sure worker nodes have the mynodeone.io/worker-ip label."
            exit 0
        fi
    fi
    
    info "Found worker node(s):"
    echo "$worker_data" | while read -r node_name node_ip; do
        [[ -n "$node_name" ]] && info "  - $node_name (IP: ${node_ip:-'no label'})"
    done
    echo ""
    
    # Sync to each worker
    local success_count=0
    local fail_count=0
    
    while read -r node_name node_ip; do
        [[ -z "$node_name" ]] && continue
        
        # Use IP if available, otherwise fall back to hostname
        local target="${node_ip:-$node_name}"
        if [[ -z "$node_ip" ]]; then
            warn "No mynodeone.io/worker-ip label for $node_name, trying hostname..."
        fi
        
        # Pass both IP and hostname to sync_to_worker
        if sync_to_worker "$target" "$node_name"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done <<< "$worker_data"
    
    # Summary
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📊 Sync Summary${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    success "Successfully synced to $success_count worker node(s)"
    if [[ $fail_count -gt 0 ]]; then
        warn "Failed to sync to $fail_count worker node(s)"
    fi
    echo ""
    
    info "Next steps:"
    echo "  • Restart vLLM pods to use synced models: kubectl rollout restart statefulset/vllm -n llmapi"
    echo "  • Or scale vLLM to use both GPUs: kubectl scale statefulset/vllm -n llmapi --replicas=2"
}

main "$@"
