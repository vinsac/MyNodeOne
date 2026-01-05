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

# Detect control plane user (authoritative source: cluster config)
# This is critical because SSH keys are owned by the control plane user, not root
CONTROL_PLANE_USER=""
if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
    CONTROL_PLANE_USER=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.control-plane-user}' 2>/dev/null)
fi

# Fallback to SUDO_USER if cluster config not available
if [ -z "$CONTROL_PLANE_USER" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        CONTROL_PLANE_USER="$SUDO_USER"
    else
        CONTROL_PLANE_USER="$(whoami)"
    fi
fi

ACTUAL_USER="$CONTROL_PLANE_USER"
ACTUAL_HOME=$(getent passwd "$CONTROL_PLANE_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")

# Use user-specific temp directory to avoid permission issues
TEMP_DIR="${ACTUAL_HOME}/.cache/mynodeone/tmp"
mkdir -p "$TEMP_DIR" 2>/dev/null || TEMP_DIR="/tmp"
# Ensure proper ownership if we created it
if [ "$(whoami)" = "root" ] && [ "$TEMP_DIR" != "/tmp" ]; then
    chown -R "$CONTROL_PLANE_USER:$CONTROL_PLANE_USER" "$TEMP_DIR" 2>/dev/null || true
fi

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
    
    # Prepare SSH command that works under sudo
    # Use CONTROL_PLANE_USER (from cluster config) who has SSH keys, not SUDO_USER
    local ssh_cmd="ssh"
    if [ "$(whoami)" = "root" ]; then
        ssh_cmd="sudo -u $CONTROL_PLANE_USER ssh"
        info "  Script running as root - using SSH as: $CONTROL_PLANE_USER" >&2
    fi
    
    # First, try to get username from node label (set during worker node setup)
    local labeled_user=""
    if [[ -n "$node_name" ]]; then
        labeled_user=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null)
    fi
    
    # Determine usernames to try
    local users_to_try=()
    if [[ -n "$labeled_user" ]]; then
        info "  Found labeled SSH user: $labeled_user" >&2
        users_to_try=("$labeled_user")
    else
        info "  No mynodeone.io/ssh-user label found, trying common usernames..." >&2
        # Use ACTUAL_USER (detected from SUDO_USER or whoami), then common defaults
        users_to_try=("$ACTUAL_USER" "ubuntu" "root")
    fi
    
    # Try each username
    for user in "${users_to_try[@]}"; do
        info "  Trying user: $user" >&2
        local ssh_test_output
        if ssh_test_output=$($ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
           "${user}@${node_ip}" "echo connected" 2>&1); then
            ssh_user="$user"
            success "  ✓ SSH works with user: $ssh_user" >&2
            break
        else
            warn "  ✗ SSH failed for user: $user" >&2
            if [[ "$user" == "$labeled_user" ]]; then
                warn "  SSH error: $ssh_test_output" >&2
                warn "  Make sure SSH keys are set up: ssh-copy-id ${user}@${node_ip}" >&2
                if [ -n "${SUDO_USER:-}" ]; then
                    warn "  Note: SSH keys should be in /home/$SUDO_USER/.ssh/" >&2
                fi
            fi
        fi
    done
    
    if [[ -z "$ssh_user" ]]; then
        warn "Cannot sync to $node_ip - SSH username not found." >&2
        warn "Tried usernames: ${users_to_try[*]}" >&2
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
    
    # Defensive: Ensure correct SSH permissions on worker to prevent auth issues
    # Run SSH as actual user if under sudo
    local ssh_cmd="ssh"
    local rsync_ssh_opt=""
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ssh_cmd="sudo -u $SUDO_USER ssh"
        rsync_ssh_opt="-e 'sudo -u $SUDO_USER ssh -o StrictHostKeyChecking=no -o BatchMode=yes'"
    else
        rsync_ssh_opt="-e 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes'"
    fi
    
    info "Fixing SSH permissions on $node_ip (defensive)..."
    if $ssh_cmd -o BatchMode=yes "${ssh_user}@${node_ip}" "chmod 700 ~/.ssh 2>/dev/null; chmod 600 ~/.ssh/authorized_keys 2>/dev/null; chmod go-w ~ 2>/dev/null; true" 2>&1 | tee "$TEMP_DIR/ssh-fix-perms.log"; then
        success "SSH permissions verified/fixed on $node_ip"
    else
        warn "Could not verify SSH permissions on $node_ip (non-critical)"
        info "Error details: $(cat "$TEMP_DIR/ssh-fix-perms.log" 2>/dev/null | head -3)"
    fi
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
    info "Command: $ssh_cmd ${ssh_user}@${node_ip} \"sudo mkdir -p $DEST_DIR && sudo chown -R ${ssh_user}:${ssh_user} $DEST_DIR\""
    
    if $ssh_cmd -o BatchMode=yes "${ssh_user}@${node_ip}" "sudo mkdir -p $DEST_DIR && sudo chown -R ${ssh_user}:${ssh_user} $DEST_DIR" 2>&1 | tee "$TEMP_DIR/ssh-mkdir.log"; then
        success "Destination directory created: $DEST_DIR"
    else
        error "Failed to create destination directory on $node_ip"
        info "Error details: $(cat "$TEMP_DIR/ssh-mkdir.log" 2>/dev/null)"
        return 1
    fi
    echo ""
    
    # Sync vLLM models (only HuggingFace cache format)
    if [[ -d "$SOURCE_DIR/vllm" ]]; then
        # Validate models are in HuggingFace format before syncing
        local hf_model_count=$(find "$SOURCE_DIR/vllm" -maxdepth 1 -type d -name "models--*" 2>/dev/null | wc -l)
        
        if [[ $hf_model_count -eq 0 ]]; then
            warn "No HuggingFace-format models found in $SOURCE_DIR/vllm"
            info "Expected directory structure: models--Org--ModelName/snapshots/..."
            info "Flat directory structures are no longer supported."
            info "Models will be downloaded directly by init containers in HuggingFace format."
            return 1
        fi
        
        info "Found $hf_model_count HuggingFace-format model(s)"
        
        # List models being synced
        for model_dir in "$SOURCE_DIR/vllm"/models--*/; do
            if [[ -d "$model_dir" ]]; then
                local model_name=$(basename "$model_dir")
                local model_size=$(du -sh "$model_dir" 2>/dev/null | cut -f1)
                info "  • $model_name ($model_size)"
            fi
        done
        
        local vllm_size=$(du -sh "$SOURCE_DIR/vllm" 2>/dev/null | cut -f1)
        local vllm_files=$(find "$SOURCE_DIR/vllm" -type f | wc -l)
        echo ""
        info "Syncing vLLM models:"
        info "  Total Size: $vllm_size"
        info "  Total Files: $vllm_files"
        info "  Source: $SOURCE_DIR/vllm/"
        info "  Destination: ${ssh_user}@${node_ip}:${DEST_DIR}/vllm/"
        info "This may take several minutes depending on model size and network speed..."
        echo ""
        
        info "Running: rsync -av --progress $rsync_ssh_opt ..."
        local rsync_cmd
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            rsync_cmd="sudo -u $SUDO_USER rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes'"
        else
            rsync_cmd="rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no -o BatchMode=yes'"
        fi
        
        if eval "$rsync_cmd \"$SOURCE_DIR/vllm/\" \"${ssh_user}@${node_ip}:${DEST_DIR}/vllm/\"" 2>&1 | tee "$TEMP_DIR/rsync-vllm.log"; then
            success "vLLM models synced to $node_ip"
        else
            warn "Failed to sync vLLM models to $node_ip"
            info "Rsync error details:"
            tail -20 "$TEMP_DIR/rsync-vllm.log"
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
        
        if eval "$rsync_cmd \"$SOURCE_DIR/llamacpp/\" \"${ssh_user}@${node_ip}:${DEST_DIR}/llamacpp/\"" 2>&1 | tee "$TEMP_DIR/rsync-llamacpp.log"; then
            success "llamacpp models synced to $node_ip"
        else
            warn "Failed to sync llamacpp models to $node_ip"
            info "Rsync error details:"
            tail -20 "$TEMP_DIR/rsync-llamacpp.log"
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
        
        if eval "$rsync_cmd \"$SOURCE_DIR/embedding/\" \"${ssh_user}@${node_ip}:${DEST_DIR}/embedding/\"" 2>&1 | tee "$TEMP_DIR/rsync-embedding.log"; then
            success "embedding models synced to $node_ip"
        else
            warn "Failed to sync embedding models to $node_ip"
            info "Rsync error details:"
            tail -20 "$TEMP_DIR/rsync-embedding.log"
            return 1
        fi
        echo ""
    else
        info "No embedding models found at $SOURCE_DIR/embedding"
    fi
    
    # Fix permissions on worker - critical for init containers to read files
    info "Fixing permissions on $node_ip..."
    
    # Try to set 1000:1000 ownership (ideal for vLLM containers)
    if $ssh_cmd -o BatchMode=yes "${ssh_user}@${node_ip}" "sudo chown -R 1000:1000 $DEST_DIR && sudo chmod -R 755 $DEST_DIR" 2>&1 | tee "$TEMP_DIR/ssh-chown.log"; then
        success "✓ Permissions set to 1000:1000 (vLLM user)"
    else
        warn "Could not set 1000:1000 ownership (passwordless sudo not configured)"
        info "Attempting fallback: setting user ownership with world-readable..."
        
        # Fallback: Set current user ownership and make world-readable
        # This allows init containers (running as root) to read the files
        if $ssh_cmd -o BatchMode=yes "${ssh_user}@${node_ip}" "chown -R ${ssh_user}:${ssh_user} $DEST_DIR && chmod -R 755 $DEST_DIR" 2>&1; then
            success "✓ Permissions set to ${ssh_user}:${ssh_user} with 755 (init container can read)"
            info "Init container will fix ownership to 1000:1000 when copying to PVC"
        else
            error "Failed to fix permissions on $node_ip"
            info "Error details: $(cat "$TEMP_DIR/ssh-chown.log" 2>/dev/null)"
            return 1
        fi
    fi
    echo ""
    
    success "All models synced to $node_ip successfully!"
    echo ""
    return 0
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
    
    # Summary - output to both stdout and stderr to ensure visibility
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE}📊 Sync Summary${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    success "Successfully synced to $success_count worker node(s)" >&2
    if [[ $fail_count -gt 0 ]]; then
        warn "Failed to sync to $fail_count worker node(s)" >&2
    fi
    echo "" >&2
    
    info "Next steps:" >&2
    echo "  • Restart vLLM pods to use synced models: kubectl rollout restart statefulset/vllm -n llmapi" >&2
    echo "  • Or scale vLLM to use both GPUs: kubectl scale statefulset/vllm -n llmapi --replicas=2" >&2
    echo "" >&2
    
    # Return success if at least one node synced successfully, failure if all failed
    if [[ $success_count -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

main "$@"
exit $?
