#!/bin/bash

###############################################################################
# Shared Validation Library for App Installations
# 
# Provides consistent pre-flight checks across all app installation scripts
###############################################################################

# Colors
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

###############################################################################
# validate_prerequisites
# 
# Performs comprehensive pre-flight validation before app installation
# 
# Checks:
#   1. kubectl is installed
#   2. Kubernetes cluster is accessible
#   3. Longhorn storage class is available
#
# Returns:
#   0 on success
#   1 on failure (exits script)
###############################################################################
validate_prerequisites() {
    local require_storage="${1:-true}"  # Optional: set to "false" to skip storage check
    
    # Check 1: kubectl available
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found. Please install Kubernetes first.${NC}"
        echo "Run: sudo ./scripts/bootstrap-control-plane.sh"
        exit 1
    fi
    
    # Check 2: Cluster accessible
    if ! kubectl get nodes &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster.${NC}"
        echo "Please ensure:"
        echo "  • K3s is running: systemctl status k3s"
        echo "  • KUBECONFIG is set: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
        exit 1
    fi
    
    # Check 3: Storage available (optional)
    if [ "$require_storage" = "true" ]; then
        if ! kubectl get storageclass longhorn &> /dev/null; then
            echo -e "${YELLOW}Warning: Longhorn storage class not found.${NC}"
            echo "Installation may fail without persistent storage."
            read -p "Continue anyway? [y/N]: " continue_without_storage
            if [[ "$continue_without_storage" != "y" ]] && [[ "$continue_without_storage" != "Y" ]]; then
                echo "Installation cancelled."
                exit 1
            fi
        fi
    fi
    
    return 0
}

###############################################################################
# validate_and_sanitize_subdomain
# 
# Validates and sanitizes user-provided subdomain input
# 
# Args:
#   $1: subdomain input from user
#   $2: default subdomain to use if invalid
#
# Returns:
#   Sanitized subdomain via stdout
###############################################################################
validate_and_sanitize_subdomain() {
    local input="$1"
    local default="$2"
    local sanitized
    
    # Sanitize: lowercase, alphanumeric and hyphens only
    sanitized=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    
    # Validate: not empty after sanitization
    if [ -z "$sanitized" ]; then
        echo -e "${YELLOW}Error: Invalid subdomain. Using default: ${default}${NC}" >&2
        echo "$default"
        return 0
    fi
    
    # Validate: doesn't start with hyphen
    if [[ "$sanitized" == -* ]]; then
        echo -e "${YELLOW}Error: Subdomain cannot start with hyphen. Using default: ${default}${NC}" >&2
        echo "$default"
        return 0
    fi
    
    # Valid subdomain
    echo "$sanitized"
    return 0
}

###############################################################################
# check_namespace_exists
# 
# Checks if a namespace already exists
# 
# Args:
#   $1: namespace name
#
# Returns:
#   0 if exists, 1 if not
###############################################################################
check_namespace_exists() {
    local namespace="$1"
    
    if kubectl get namespace "$namespace" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

###############################################################################
# warn_if_namespace_exists
# 
# Warns user if namespace already exists and prompts to continue
# 
# Args:
#   $1: namespace name
#
# Returns:
#   0 to continue, exits if user cancels
###############################################################################
warn_if_namespace_exists() {
    local namespace="$1"
    
    if check_namespace_exists "$namespace"; then
        echo -e "${YELLOW}Warning: Namespace '${namespace}' already exists.${NC}"
        echo "This installation may overwrite existing resources."
        read -p "Continue anyway? [y/N]: " continue_install
        if [[ "$continue_install" != "y" ]] && [[ "$continue_install" != "Y" ]]; then
            echo "Installation cancelled."
            exit 1
        fi
    fi
    
    return 0
}
