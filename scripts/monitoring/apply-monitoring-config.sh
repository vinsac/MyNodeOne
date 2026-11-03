#!/bin/bash

###############################################################################
# Apply the MyNodeOne monitoring configuration to a running cluster.
#
# Safe to re-run. It:
#   1. Lets node-exporter and promtail schedule in the monitoring namespace.
#   2. Applies the alert rules and the Longhorn ServiceMonitor.
#   3. Runs helm upgrade on kube-prometheus-stack with the same chart version,
#      keeping current values and adding kube-prometheus-stack-values.yaml, plus
#      the optional alert destination.
#
# Usage: sudo ./apply-monitoring-config.sh [--rules-only]
#
# Alert destination: ALERTMANAGER_VALUES_FILE, or /etc/mynodeone/alertmanager-values.yaml.
# If neither exists, Alertmanager's receiver is left as it is.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULES_ONLY=false

case "${1:-}" in
    "") ;;
    --rules-only) RULES_ONLY=true ;;
    *)
        echo "Usage: $0 [--rules-only]" >&2
        exit 1
        ;;
esac

source "$PROJECT_ROOT/scripts/lib/versions.sh"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "Labelling the monitoring namespace..."
kubectl label --overwrite namespace monitoring \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/enforce-version=latest

echo "Applying alert rules and the Longhorn ServiceMonitor..."
kubectl apply -f "$SCRIPT_DIR/longhorn-servicemonitor.yaml" -f "$SCRIPT_DIR/prometheus-alerts/"

if [ "$RULES_ONLY" = true ]; then
    echo "Done (rules only)."
    exit 0
fi

helm_args=(
    --namespace monitoring
    --version "$PROMETHEUS_STACK_VERSION"
    --reuse-values
    -f "$SCRIPT_DIR/kube-prometheus-stack-values.yaml"
)

alertmanager_values_file="${ALERTMANAGER_VALUES_FILE:-/etc/mynodeone/alertmanager-values.yaml}"
if [ -s "$alertmanager_values_file" ]; then
    echo "Using the alert destination in $alertmanager_values_file"
    helm_args+=(-f "$alertmanager_values_file")
else
    echo "No alert destination file: Alertmanager's receiver stays as it is."
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community

echo "Upgrading kube-prometheus-stack (chart $PROMETHEUS_STACK_VERSION)..."
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack "${helm_args[@]}" --timeout 10m

echo "Done. Check with: kubectl -n monitoring get pods"
