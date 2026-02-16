#!/bin/bash

###############################################################################
# MyNodeOne - Component Versions (Single Source of Truth)
#
# All version numbers for MyNodeOne components are defined here.
# This file is sourced by all installation and setup scripts to ensure
# version consistency across control plane, worker nodes, VPS, and laptops.
#
# Usage:
#   source "$PROJECT_ROOT/scripts/lib/versions.sh"
#
# After sourcing, all version variables will be available as environment variables.
# Scripts can override versions by setting them before sourcing this file.
###############################################################################

# Kubernetes & Cluster Core
export K3S_VERSION="${K3S_VERSION:-v1.31.2+k3s1}"
export KUBECTL_VERSION="${KUBECTL_VERSION:-v1.31.2}"

# Helm & Package Management
export HELM_VERSION="${HELM_VERSION:-v3.15.3}"
export KOMPOSE_VERSION="${KOMPOSE_VERSION:-v1.34.0}"

# Storage
export LONGHORN_VERSION="${LONGHORN_VERSION:-1.7.2}"

# Ingress, Networking & Security
export CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
export TRAEFIK_VERSION="${TRAEFIK_VERSION:-33.2.0}"
export METALLB_VERSION="${METALLB_VERSION:-0.14.3}"

# Observability & Monitoring
export PROMETHEUS_STACK_VERSION="${PROMETHEUS_STACK_VERSION:-65.8.0}"
export LOKI_VERSION="${LOKI_VERSION:-2.10.2}"

# GitOps
export ARGOCD_VERSION="${ARGOCD_VERSION:-7.7.5}"

# CLI Tools (for management laptops)
export K9S_VERSION="${K9S_VERSION:-v0.32.5}"

# Validation function to ensure versions are loaded
validate_versions() {
    if [ -z "${K3S_VERSION:-}" ] || [ -z "${KUBECTL_VERSION:-}" ]; then
        echo "ERROR: versions.sh was not sourced correctly" >&2
        return 1
    fi
    return 0
}

# Auto-validate when sourced (non-fatal)
validate_versions 2>/dev/null || true
