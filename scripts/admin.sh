#!/bin/bash

###############################################################################
# MyNodeOne Admin Tool
# 
# Simple menu-driven interface for non-technical cluster administration
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

show_header() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MyNodeOne Admin Tool${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_apps() {
    show_header
    echo "📦 Installed Applications:"
    echo ""
    kubectl get deployments --all-namespaces -o custom-columns='NAMESPACE:.metadata.namespace,APP:.metadata.name,READY:.status.readyReplicas/:.status.replicas,AGE:.metadata.creationTimestamp' | grep -v "kube-\|longhorn\|metallb\|traefik" || echo "No apps installed"
    echo ""
    read -p "Press Enter to continue..."
}

show_resources() {
    show_header
    echo "💾 Resource Usage:"
    echo ""
    kubectl top nodes 2>/dev/null || echo "Metrics not available"
    echo ""
    echo "Storage:"
    kubectl get pvc --all-namespaces -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SIZE:.spec.resources.requests.storage,USED:.status.capacity.storage' | grep -v "kube-\|longhorn\|metallb" || echo "No storage"
    echo ""
    read -p "Press Enter to continue..."
}

show_logs() {
    show_header
    echo "📋 View Logs"
    echo ""
    echo "Select application:"
    echo ""
    
    # List namespaces
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "kube-\|default\|longhorn\|metallb" || echo "")
    
    if [ -z "$namespaces" ]; then
        echo "No applications found"
        read -p "Press Enter to continue..."
        return
    fi
    
    select ns in $namespaces "Back"; do
        if [ "$ns" = "Back" ] || [ -z "$ns" ]; then
            return
        fi
        
        # Get pods in namespace
        pods=$(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}')
        
        if [ -z "$pods" ]; then
            echo "No pods found in $ns"
            read -p "Press Enter to continue..."
            return
        fi
        
        echo ""
        echo "Select pod:"
        select pod in $pods "Back"; do
            if [ "$pod" = "Back" ] || [ -z "$pod" ]; then
                break
            fi
            
            echo ""
            echo "Showing logs for $pod in $ns (Ctrl+C to stop)..."
            echo ""
            kubectl logs -n "$ns" "$pod" --tail=50 -f || true
            break
        done
        break
    done
}

restart_app() {
    show_header
    echo "🔄 Restart Application"
    echo ""
    echo "Select application:"
    echo ""
    
    # List deployments
    deployments=$(kubectl get deployments --all-namespaces -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers | grep -v "kube-\|longhorn\|metallb\|traefik" || echo "")
    
    if [ -z "$deployments" ]; then
        echo "No applications found"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "$deployments" | nl
    echo ""
    read -p "Enter number (or 0 to cancel): " choice
    
    if [ "$choice" = "0" ]; then
        return
    fi
    
    selected=$(echo "$deployments" | sed -n "${choice}p")
    ns=$(echo "$selected" | awk '{print $1}')
    app=$(echo "$selected" | awk '{print $2}')
    
    if [ -z "$ns" ] || [ -z "$app" ]; then
        echo "Invalid selection"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    echo "Restarting $app in $ns..."
    kubectl rollout restart deployment "$app" -n "$ns"
    echo "✓ Restart initiated"
    sleep 2
}

manage_storage() {
    show_header
    echo "💾 Storage Management"
    echo ""
    echo "1. View storage usage"
    echo "2. Expand LLM Chat storage"
    echo "3. Monitor LLM storage (auto-expand)"
    echo "4. Back"
    echo ""
    read -p "Choose [1-4]: " choice
    
    case $choice in
        1)
            echo ""
            kubectl get pvc --all-namespaces
            echo ""
            read -p "Press Enter to continue..."
            ;;
        2)
            if [ -f "$SCRIPT_DIR/apps/install-llm-chat.sh" ]; then
                bash "$SCRIPT_DIR/apps/install-llm-chat.sh"
            else
                echo "LLM Chat script not found"
                read -p "Press Enter to continue..."
            fi
            ;;
        3)
            if [ -f "$SCRIPT_DIR/apps/monitor-llm-storage.sh" ]; then
                bash "$SCRIPT_DIR/apps/monitor-llm-storage.sh"
                read -p "Press Enter to continue..."
            else
                echo "Storage monitor script not found"
                read -p "Press Enter to continue..."
            fi
            ;;
        *)
            return
            ;;
    esac
}

install_app() {
    show_header
    echo "📦 Install Application"
    echo ""
    
    if [ -f "$SCRIPT_DIR/app-store.sh" ]; then
        bash "$SCRIPT_DIR/app-store.sh"
    else
        echo "App store not found"
        read -p "Press Enter to continue..."
    fi
}

setup_dashboard() {
    show_header
    echo "🌐 Web Dashboard Setup"
    echo ""
    
    if [ -f "$SCRIPT_DIR/setup-admin-dashboard.sh" ]; then
        bash "$SCRIPT_DIR/setup-admin-dashboard.sh"
        read -p "Press Enter to continue..."
    else
        echo "Dashboard setup script not found"
        read -p "Press Enter to continue..."
    fi
}

show_health() {
    show_header
    echo "🏥 Cluster Health"
    echo ""
    
    echo "Nodes:"
    kubectl get nodes
    echo ""
    
    echo "System Pods:"
    kubectl get pods -n kube-system | grep -v "Running\|Completed" || echo "All system pods healthy"
    echo ""
    
    echo "Storage:"
    kubectl get pvc --all-namespaces | grep -v "Bound" || echo "All storage bound"
    echo ""
    
    read -p "Press Enter to continue..."
}

main_menu() {
    while true; do
        show_header
        echo "Choose an option:"
        echo ""
        echo "  1. View installed apps"
        echo "  2. View resource usage"
        echo "  3. View logs"
        echo "  4. Restart application"
        echo "  5. Manage storage"
        echo "  6. Install new app"
        echo "  7. Cluster health check"
        echo "  8. Setup web dashboard"
        echo "  9. Exit"
        echo ""
        read -p "Enter choice [1-9]: " choice
        
        case $choice in
            1) show_apps ;;
            2) show_resources ;;
            3) show_logs ;;
            4) restart_app ;;
            5) manage_storage ;;
            6) install_app ;;
            7) show_health ;;
            8) setup_dashboard ;;
            9) 
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl get nodes &> /dev/null; then
    echo "Error: Cannot access Kubernetes cluster"
    exit 1
fi

main_menu
