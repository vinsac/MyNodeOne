#!/bin/bash

###############################################################################
# Report or remove the MinIO resources left behind by a removed node.
#
# install-minio.sh creates a minio-<node> namespace, a PVC and a PV pinned to the
# node. Removing the node doesn't remove them, and the pod stays Pending forever.
#
# USAGE:
#   cleanup-node-minio.sh --list                 Report every MinIO instance, and
#                                                mark those whose node is gone.
#   cleanup-node-minio.sh --node <name>          Report one node's resources.
#   cleanup-node-minio.sh --node <name> --delete Delete the Kubernetes resources
#                                                after a typed confirmation.
#
# Reporting is the default and changes nothing. Deleting is refused when the node
# is still in the cluster, when there's no terminal to confirm on, and when the
# PV's reclaim policy isn't Retain.
#
# Files on the node's disk are never touched, because this script can't reach that
# disk. It prints the path so you can decide what to do with the data.
###############################################################################

set -euo pipefail

NODE=""
MODE="report"

usage() {
    sed -n '/^# USAGE:/,/^# disk\. It prints/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            MODE="list"
            shift
            ;;
        --node)
            if [[ $# -lt 2 ]]; then
                echo "--node needs a node name" >&2
                exit 2
            fi
            NODE="$2"
            shift 2
            ;;
        --delete)
            MODE="delete"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$MODE" != "list" ]]; then
    if [[ -z "$NODE" ]]; then
        echo "Specify --node <name> or --list." >&2
        exit 2
    fi
    if ! [[ "$NODE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
        echo "Not a valid node name: $NODE" >&2
        exit 2
    fi
fi

# A failed query must not read as "nothing left behind", so every lookup goes through
# here and stops the script when kubectl fails. The result is left in KUBE_OUT rather
# than printed, because an exit inside $(...) would only end the subshell.
KUBE_OUT=""
kube() {
    if ! KUBE_OUT=$(kubectl "$@"); then
        echo "kubectl failed: kubectl $*" >&2
        echo "Can't tell what exists, so nothing was changed." >&2
        exit 1
    fi
}

node_in_cluster() {
    kube get node "$1" -o name --ignore-not-found
    [[ -n "$KUBE_OUT" ]]
}

# Prints each non-empty line of $1 with the prefix $2.
print_prefixed() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && echo "$2$line"
    done <<< "$1"
    return 0
}

# Prints the node's resources. Sets FOUND_NS, FOUND_PVS and FOUND_ANY.
report_node() {
    local node="$1" namespace="minio-$1" pv reclaim path phase
    FOUND_NS=""
    FOUND_PVS=""
    FOUND_ANY=false

    if node_in_cluster "$node"; then
        echo "Node $node: in the cluster"
    else
        echo "Node $node: NOT in the cluster"
    fi

    kube get namespace "$namespace" -o name --ignore-not-found
    if [[ -n "$KUBE_OUT" ]]; then
        FOUND_NS="$namespace"
        FOUND_ANY=true
        echo "  Namespace: $namespace"
        kube get pvc -n "$namespace" --no-headers \
            -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage'
        print_prefixed "$KUBE_OUT" "    PVC: "
        kube get pods -n "$namespace" --no-headers \
            -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
        print_prefixed "$KUBE_OUT" "    Pod: "
    fi

    kube get pv -l "app=minio,node=$node" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    FOUND_PVS="$KUBE_OUT"
    while IFS= read -r pv; do
        [[ -n "$pv" ]] || continue
        FOUND_ANY=true
        kube get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
        reclaim="$KUBE_OUT"
        kube get pv "$pv" -o jsonpath='{.status.phase}'
        phase="$KUBE_OUT"
        kube get pv "$pv" -o jsonpath='{.spec.hostPath.path}'
        path="$KUBE_OUT"
        echo "  PV: $pv (status: $phase, reclaim policy: $reclaim)"
        echo "    Data on the node's disk, not touched by this script: ${path:-unknown}"
    done <<< "$FOUND_PVS"

    if [[ "$FOUND_ANY" == false ]]; then
        echo "  No MinIO resources found."
    fi
}

list_all() {
    local namespace namespaces node any=false orphans=0
    kube get namespaces -l app=minio -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    namespaces="$KUBE_OUT"
    while IFS= read -r namespace; do
        [[ -n "$namespace" ]] || continue
        any=true
        node="${namespace#minio-}"
        report_node "$node"
        if ! node_in_cluster "$node"; then
            orphans=$((orphans + 1))
            echo "  Left behind. To remove: $0 --node $node --delete"
        fi
        echo
    done <<< "$namespaces"
    if [[ "$any" == false ]]; then
        echo "No MinIO instances found."
    fi
    echo "MinIO instances whose node is gone: $orphans"
}

delete_node() {
    local node="$1" pv reclaim typed=""

    report_node "$node"
    echo

    if [[ "$FOUND_ANY" == false ]]; then
        echo "Nothing to delete."
        return 0
    fi
    if node_in_cluster "$node"; then
        echo "Refusing to delete: $node is still in the cluster. Remove the node first." >&2
        exit 1
    fi
    if [[ ! -t 0 ]]; then
        echo "Refusing to delete: this run has no terminal to confirm on. Nothing was changed." >&2
        exit 1
    fi

    while IFS= read -r pv; do
        [[ -n "$pv" ]] || continue
        kube get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
        reclaim="$KUBE_OUT"
        if [[ "$reclaim" != "Retain" ]]; then
            echo "Refusing to delete: PV $pv has reclaim policy '$reclaim', so deleting it could also delete its data." >&2
            exit 1
        fi
    done <<< "$FOUND_PVS"

    echo "This deletes the namespace above with its credentials Secret and PVC, then the PV."
    echo "The files on the node's disk are not deleted."
    read -r -p "Type the namespace name (minio-$node) to delete, or anything else to cancel: " typed || typed=""
    if [[ "$typed" != "minio-$node" ]]; then
        echo "Confirmation did not match. Nothing was changed."
        exit 1
    fi

    if [[ -n "$FOUND_NS" ]]; then
        kubectl delete namespace "$FOUND_NS" --wait=true
    fi
    # A PV bound to a PVC that's still being removed would hang, so it goes last
    while IFS= read -r pv; do
        [[ -n "$pv" ]] || continue
        kubectl delete pv "$pv"
    done <<< "$FOUND_PVS"
    echo "Deleted the Kubernetes resources for minio-$node."
}

case "$MODE" in
    list)
        list_all
        ;;
    report)
        report_node "$NODE"
        if [[ "$FOUND_ANY" == true ]] && ! node_in_cluster "$NODE"; then
            echo
            echo "These are left over from a removed node. To remove them: $0 --node $NODE --delete"
        fi
        ;;
    delete)
        delete_node "$NODE"
        ;;
esac
