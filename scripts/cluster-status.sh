#!/bin/bash

###############################################################################
# NodeZero Cluster Status Script
# 
# Quick overview of cluster health and resources
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

print_section() {
    echo -e "${BLUE}▶ $1${NC}"
    echo
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

main() {
    clear
    
    echo -e "${GREEN}"
    cat << "EOF"
    _   __          __     ______                
   / | / /___  ____/ /__  /__  (_)___  _________
  /  |/ / __ \/ __  / _ \   / / / _ \/ ___/ __ \
 / /|  / /_/ / /_/ /  __/  / /_/  __/ /  / /_/ /
/_/ |_/\____/\__,_/\___/  /___/\___/_/   \____/ 
                                                 
EOF
    echo -e "${NC}"
    echo -e "${CYAN}NodeZero Cluster Status${NC}"
    echo
    
    # Check prerequisites
    check_command kubectl
    check_command jq
    
    # Cluster Info
    print_header "CLUSTER INFORMATION"
    print_section "Kubernetes Version"
    kubectl version --short 2>/dev/null || kubectl version --output=json | jq -r '.serverVersion.gitVersion'
    echo
    
    print_section "Cluster Nodes"
    kubectl get nodes -o wide
    echo
    
    # Node Resources
    print_header "RESOURCE USAGE"
    print_section "Node Resources"
    kubectl top nodes 2>/dev/null || echo "Metrics server not ready"
    echo
    
    print_section "Top 10 CPU Consuming Pods"
    kubectl top pods -A --sort-by=cpu 2>/dev/null | head -11 || echo "Metrics not available"
    echo
    
    print_section "Top 10 Memory Consuming Pods"
    kubectl top pods -A --sort-by=memory 2>/dev/null | head -11 || echo "Metrics not available"
    echo
    
    # Pod Status
    print_header "POD STATUS"
    print_section "Pods by Namespace"
    kubectl get pods -A -o json | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \(length) pods"' | column -t
    echo
    
    print_section "Non-Running Pods"
    NON_RUNNING=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2)
    if [ -z "$NON_RUNNING" ]; then
        echo -e "${GREEN}✓ All pods are running${NC}"
    else
        echo -e "${YELLOW}Warning: Found non-running pods:${NC}"
        echo "$NON_RUNNING"
    fi
    echo
    
    # Storage
    print_header "STORAGE"
    print_section "Persistent Volumes"
    kubectl get pv
    echo
    
    print_section "Storage by Namespace"
    kubectl get pvc -A -o json | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \([.[] | .spec.resources.requests.storage] | join(", "))"'
    echo
    
    # Services
    print_header "SERVICES"
    print_section "LoadBalancer Services"
    kubectl get svc -A -o wide | grep LoadBalancer || echo "No LoadBalancer services"
    echo
    
    # Certificates
    print_header "SSL CERTIFICATES"
    if kubectl get certificates -A &>/dev/null; then
        print_section "Certificate Status"
        kubectl get certificates -A
        echo
    else
        echo "cert-manager not installed or no certificates"
        echo
    fi
    
    # Recent Events
    print_header "RECENT EVENTS"
    print_section "Last 10 Events"
    kubectl get events -A --sort-by='.lastTimestamp' | tail -10
    echo
    
    # System Pods
    print_header "SYSTEM COMPONENTS"
    
    NAMESPACES=("kube-system" "longhorn-system" "traefik" "monitoring" "argocd" "cert-manager" "metallb-system" "minio")
    
    for ns in "${NAMESPACES[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null; then
            print_section "$ns"
            kubectl get pods -n "$ns" -o wide 2>/dev/null | grep -v "NAME" | awk '{
                status = $3
                color = ""
                if (status == "Running") color = "\033[0;32m"
                else if (status == "Completed") color = "\033[0;34m"
                else color = "\033[0;31m"
                printf "%s%-50s %-15s\033[0m\n", color, $1, status
            }'
            echo
        fi
    done
    
    # Summary
    print_header "SUMMARY"
    
    TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
    READY_NODES=$(kubectl get nodes --no-headers | grep " Ready" | wc -l)
    TOTAL_PODS=$(kubectl get pods -A --no-headers | wc -l)
    RUNNING_PODS=$(kubectl get pods -A --no-headers | grep "Running" | wc -l)
    TOTAL_PV=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    BOUND_PV=$(kubectl get pv --no-headers 2>/dev/null | grep "Bound" | wc -l)
    
    echo "Nodes:   $READY_NODES/$TOTAL_NODES Ready"
    echo "Pods:    $RUNNING_PODS/$TOTAL_PODS Running"
    echo "Storage: $BOUND_PV/$TOTAL_PV PVs Bound"
    echo
    
    # Health Status
    if [ "$READY_NODES" -eq "$TOTAL_NODES" ] && [ "$RUNNING_PODS" -gt 0 ]; then
        echo -e "${GREEN}✓ Cluster is healthy${NC}"
    elif [ "$READY_NODES" -lt "$TOTAL_NODES" ]; then
        echo -e "${RED}✗ Some nodes are not ready${NC}"
    else
        echo -e "${YELLOW}⚠ Cluster status needs attention${NC}"
    fi
    
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Run
main "$@"
