#!/bin/bash

# Standardized KUBECONFIG detection logic
export_k8s_config() {
    # 1. Prefer explicit KUBECONFIG if already set and valid
    if [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ]; then
        return 0
    fi

    # 2. Try K3s system config (control plane/worker)
    if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
        export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
        return 0
    fi

    # 3. Detect ACTUAL_HOME if not already set
    if [ -z "${ACTUAL_HOME:-}" ]; then
        local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$lib_dir/detect-actual-home.sh" ]; then
            source "$lib_dir/detect-actual-home.sh"
        else
            # Minimal fallback if library is missing
            local actual_user="${SUDO_USER:-$(whoami)}"
            if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    export ACTUAL_HOME="/Users/$actual_user"
                else
                    export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "/home/$actual_user")
                fi
            else
                export ACTUAL_HOME="$HOME"
            fi
        fi
    fi

    # 4. Check actual user's home
    if [ -n "${ACTUAL_HOME:-}" ] && [ -f "$ACTUAL_HOME/.kube/config" ]; then
        export KUBECONFIG="$ACTUAL_HOME/.kube/config"
        return 0
    fi

    # 5. Fallback to current user's HOME
    if [ -f "$HOME/.kube/config" ]; then
        export KUBECONFIG="$HOME/.kube/config"
        return 0
    fi
    
    # Verify connectivity if possible
    if ! command -v kubectl &>/dev/null; then
        return 1
    fi
    return 0
}

# Robust identification of the current node's Kubernetes name
get_k8s_node_name() {
    # Ensure KUBECONFIG is exportable
    export_k8s_config || return 1

    # 1. Check if NODE_NAME is already set and valid
    if [[ -n "${NODE_NAME:-}" ]]; then
        if kubectl get node "$NODE_NAME" &>/dev/null; then
            echo "$NODE_NAME"
            return 0
        fi
    fi

    # 2. Match local Tailscale IP against Kubernetes node internal IPs (most reliable)
    local my_ip=$(tailscale ip -4 2>/dev/null | head -n1)
    if [[ -n "$my_ip" ]]; then
        local node=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[] | select(.type==\"InternalIP\" and .address==\"$my_ip\")) | .metadata.name" 2>/dev/null)
        if [[ -n "$node" ]]; then
            echo "$node"
            return 0
        fi
    fi

    # 3. Match local hostname against Kubernetes node names
    local host_name=$(hostname)
    if kubectl get node "$host_name" &>/dev/null; then
        echo "$host_name"
        return 0
    fi
    
    local short_host=$(hostname -s)
    if kubectl get node "$short_host" &>/dev/null; then
        echo "$short_host"
        return 0
    fi

    # 4. Fallback: Take the first node that is NOT a control-plane (for workers)
    local worker_fallback=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$worker_fallback" ]]; then
        echo "$worker_fallback"
        return 0
    fi

    # 5. Last resort: Just take the very first node in the cluster
    kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname
}
