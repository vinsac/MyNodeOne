#!/bin/bash

###############################################################################
# MyNodeOne App Deployment Script
# 
# Deploy any containerized app to MyNodeOne with one command.
# Works with docker-compose.yml or provides interactive setup.
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# MyNodeOne root (detect from script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Calculate project root from external-apps location
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/project-root.sh"
MYNODEONE_ROOT="$PROJECT_ROOT"

# Get cluster domain from cluster-info ConfigMap (authoritative source)
CLUSTER_DOMAIN=""
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    CLUSTER_DOMAIN=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
fi

# If not found, use default
if [ -z "$CLUSTER_DOMAIN" ]; then
    CLUSTER_DOMAIN="mynodeone"
fi

# State shared between the setup, generation and deployment functions
APP_NAME=""
LOCAL_SUBDOMAIN=""
PUBLIC_DOMAINS=""
MANIFEST_DIR=""
SERVICE_ARRAY=()
SERVICE_NAMES=()
SERVICE_IMAGES=()
SERVICE_PORTS=()
declare -A SERVICE_TYPES=()

# Generated manifests go in a private directory, removed on success. After a
# failure it is kept and its path printed, so the manifests can be inspected.
DEPLOY_WORK_DIR=""
cleanup_work_dir() {
    local status=$?
    if [[ -n "$DEPLOY_WORK_DIR" && -d "$DEPLOY_WORK_DIR" ]]; then
        if [[ $status -eq 0 ]]; then
            rm -rf "$DEPLOY_WORK_DIR"
        else
            echo "Generated manifests kept for debugging: $DEPLOY_WORK_DIR" >&2
        fi
    fi
}
trap cleanup_work_dir EXIT

# Start a fresh output directory, dropping any earlier attempt so that a failed
# kompose conversion cannot leave stale manifests to be applied.
prepare_output_dir() {
    if [[ -n "$DEPLOY_WORK_DIR" && -d "$DEPLOY_WORK_DIR" ]]; then
        rm -rf "$DEPLOY_WORK_DIR"
    fi
    DEPLOY_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mynodeone-deploy.XXXXXX")
}

log() { echo -e "${BLUE}▶${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
ask() { echo -e "${CYAN}?${NC} $1"; }

clear 2>/dev/null || true
cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║           Deploy Your App on MyNodeOne                   ║
║                                                          ║
║   Standard containerized apps work out-of-the-box       ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

EOF

echo ""

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl not found"
        echo "Please install kubectl or run this from the MyNodeOne control plane"
        exit 1
    fi
    
    if ! kubectl get nodes &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        echo "Please ensure:"
        echo "  • You're on the control plane, or"
        echo "  • KUBECONFIG is set correctly"
        exit 1
    fi
    
    success "Connected to cluster"
    echo ""
}

# Auto-detect app structure
detect_app_structure() {
    local app_dir="${1:-.}"
    
    log "Detecting app structure in: $app_dir"
    echo ""
    
    APP_TYPE="unknown"
    
    # Check for docker-compose
    if [[ -f "$app_dir/docker-compose.yml" ]] || [[ -f "$app_dir/docker-compose.yaml" ]]; then
        APP_TYPE="docker-compose"
        COMPOSE_FILE=$(find "$app_dir" -maxdepth 1 -name "docker-compose.y*ml" | head -1)
        success "Found docker-compose.yml"
        return 0
    fi
    
    # Check for Kubernetes manifests
    if [[ -d "$app_dir/k8s" ]] || [[ -d "$app_dir/kubernetes" ]] || [[ -d "$app_dir/manifests" ]]; then
        APP_TYPE="kubernetes"
        K8S_DIR=$(find "$app_dir" -maxdepth 1 -type d \( -name "k8s" -o -name "kubernetes" -o -name "manifests" \) | head -1)
        success "Found Kubernetes manifests in: $(basename "$K8S_DIR")"
        return 0
    fi
    
    # Check for Dockerfile
    if [[ -f "$app_dir/Dockerfile" ]]; then
        APP_TYPE="dockerfile"
        success "Found Dockerfile"
        return 0
    fi
    
    warn "No app structure detected"
    echo "Will use interactive mode"
    APP_TYPE="interactive"
    return 0
}

# Parse docker-compose file
parse_docker_compose() {
    local compose_file="$1"
    
    log "Parsing docker-compose.yml..."
    
    # Extract service names (basic grep parsing - works without dependencies)
    SERVICES=$(grep -E "^  [a-z][a-z0-9_-]*:" "$compose_file" | sed 's/://g' | awk '{print $1}' | xargs)
    
    if [[ -n "$SERVICES" ]]; then
        # Store services in array
        IFS=' ' read -ra SERVICE_ARRAY <<< "$SERVICES"
        
        # Filter out networks and volumes (they don't have 'image:' or 'build:' keys)
        declare -a REAL_SERVICES
        for svc in "${SERVICE_ARRAY[@]}"; do
            # Check if this service has an image or build directive
            if grep -A 5 "^  ${svc}:" "$compose_file" | grep -qE "^    (image|build):"; then
                REAL_SERVICES+=("$svc")
            fi
        done
        
        SERVICE_ARRAY=("${REAL_SERVICES[@]}")
        
        if [[ ${#SERVICE_ARRAY[@]} -eq 0 ]]; then
            warn "No container services found in docker-compose"
            return 1
        fi
        
        success "Detected services: ${SERVICE_ARRAY[*]}"
        
        # Detect service types based on common naming patterns
        detect_service_types
        
        echo ""
        return 0
    else
        warn "Could not parse services from docker-compose"
        return 1
    fi
}

# Classify a service by name. Datastores and other internal infrastructure are
# checked first, because their names routinely contain a word that also suggests a
# public service: "mysql-server", "redis-server", "web-db", "api-cache".
classify_service() {
    local svc_lower
    svc_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    # These tools are named after a database but are not datastores
    if [[ "$svc_lower" =~ (phpmyadmin|pgadmin|adminer|mongo-express|redis-commander|redisinsight) ]]; then
        echo "admin"
    elif [[ "$svc_lower" =~ (^|[-_])(db|database)($|[-_0-9]) ]] || [[ "$svc_lower" =~ [a-z]db($|[-_]) ]] || \
         [[ "$svc_lower" =~ (postgres|mysql|mariadb|mongo|mssql|sqlserver|cassandra|clickhouse|elasticsearch|opensearch|neo4j|cockroach|timescale|influx|couch) ]]; then
        echo "database"
    elif [[ "$svc_lower" =~ (redis|valkey|cache|memcache) ]]; then
        echo "cache"
    elif [[ "$svc_lower" =~ (worker|queue|celery|seed|rabbitmq|kafka|zookeeper|mosquitto) ]] || \
         [[ "$svc_lower" =~ (^|[-_])nats($|[-_0-9]) ]]; then
        echo "worker"
    elif [[ "$svc_lower" =~ (vote|result) ]]; then
        # Voting app specific
        echo "frontend"
    elif [[ "$svc_lower" =~ (admin|dashboard) ]]; then
        echo "admin"
    elif [[ "$svc_lower" =~ (frontend|web|ui|client) ]]; then
        echo "frontend"
    elif [[ "$svc_lower" =~ (backend|api|server) ]]; then
        echo "backend"
    else
        echo "internal"
    fi
}

# Detect service types based on naming conventions
detect_service_types() {
    declare -g -A SERVICE_TYPES

    local svc
    for svc in "${SERVICE_ARRAY[@]}"; do
        SERVICE_TYPES["$svc"]=$(classify_service "$svc")
    done
}

# Double a Kubernetes quantity for use as a limit. A quantity this cannot double
# exactly (such as "0.5") is returned as it is, which is still a valid limit.
double_quantity() {
    local quantity="$1"
    if [[ "$quantity" =~ ^([0-9]+)(m|k|M|G|T|Ki|Mi|Gi|Ti)?$ ]]; then
        echo "$((10#${BASH_REMATCH[1]} * 2))${BASH_REMATCH[2]}"
    else
        echo "$quantity"
    fi
}

# Ask for the app name and local subdomain
prompt_app_identity() {
    ask "What's your app name?"
    echo "  (lowercase, no spaces, used for namespace)"
    read -p "App name: " APP_NAME
    APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

    if [[ -z "$APP_NAME" ]]; then
        error "App name is required"
        return 1
    fi

    success "App name: $APP_NAME"
    echo ""

    ask "Local subdomain for cluster access?"
    echo "  (your app will be at: <subdomain>.${CLUSTER_DOMAIN}.local)"
    read -p "Subdomain [$APP_NAME]: " LOCAL_SUBDOMAIN
    LOCAL_SUBDOMAIN=${LOCAL_SUBDOMAIN:-$APP_NAME}
    LOCAL_SUBDOMAIN=$(echo "$LOCAL_SUBDOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

    success "Subdomain: $LOCAL_SUBDOMAIN"
    echo "  Access: http://$LOCAL_SUBDOMAIN.${CLUSTER_DOMAIN}.local"
    echo ""
}

# Ask whether to expose the app publicly
prompt_public_access() {
    ask "Make this app publicly accessible?"
    read -p "Public access [y/N]: " MAKE_PUBLIC

    if [[ "$MAKE_PUBLIC" =~ ^[Yy] ]]; then
        configure_public_domains || PUBLIC_DOMAINS=""
    else
        PUBLIC_DOMAINS=""
    fi
}

# Interactive app setup
interactive_setup() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Interactive App Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    prompt_app_identity || exit 1

    # Services/containers
    ask "How many services/containers does your app have?"
    echo "  Examples:"
    echo "  • 1 = Simple web app"
    echo "  • 2 = Frontend + Backend"
    echo "  • 3 = Frontend + Backend + Database"
    read -p "Number of services [1]: " NUM_SERVICES
    NUM_SERVICES=${NUM_SERVICES:-1}
    
    echo ""
    
    # Collect service details
    SERVICE_NAMES=()
    SERVICE_IMAGES=()
    SERVICE_PORTS=()

    for ((i=1; i<=NUM_SERVICES; i++)); do
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Service $i Configuration"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        ask "Service $i name? (e.g., frontend, backend, api)"
        read -p "Name: " svc_name
        svc_name=$(echo "$svc_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        if [[ -z "$svc_name" ]]; then
            error "Service name is required"
            exit 1
        fi
        SERVICE_NAMES+=("$svc_name")

        ask "Docker image for $svc_name?"
        echo "  Examples:"
        echo "  • your-registry/myapp:1.0.0"
        echo "  • ghcr.io/username/myapp:v1.0.0"
        echo "  • docker.io/nginxinc/nginx-unprivileged:1.31.7-alpine"
        read -p "Image: " svc_image
        if [[ -z "$svc_image" ]]; then
            error "Docker image is required"
            exit 1
        fi
        SERVICE_IMAGES+=("$svc_image")

        ask "Port that $svc_name listens on?"
        read -p "Port [80]: " svc_port
        svc_port=${svc_port:-80}
        SERVICE_PORTS+=("$svc_port")
        
        echo ""
    done
    
    # Resources
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Resource Requirements"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    ask "Memory per service?"
    echo "  Examples: 256Mi, 512Mi, 1Gi, 2Gi"
    read -p "Memory [512Mi]: " MEMORY_REQ
    MEMORY_REQ=${MEMORY_REQ:-512Mi}
    
    ask "CPU per service?"
    echo "  Examples: 100m (0.1 core), 500m (0.5 core), 1000m (1 core)"
    read -p "CPU [500m]: " CPU_REQ
    CPU_REQ=${CPU_REQ:-500m}
    
    echo ""
    
    # Storage
    ask "Need persistent storage?"
    read -p "Storage size (or 'none') [10Gi]: " STORAGE_SIZE
    STORAGE_SIZE=${STORAGE_SIZE:-10Gi}
    
    echo ""
    
    # Public access needs to know the services
    SERVICE_ARRAY=("${SERVICE_NAMES[@]}")
    detect_service_types

    prompt_public_access

    echo ""
}

# Index of the service that gets the app's subdomain: the first frontend, or else
# the first service that is not a datastore, cache or worker.
find_primary_index() {
    local idx svc_type fallback=""
    for idx in "${!SERVICE_NAMES[@]}"; do
        svc_type=$(classify_service "${SERVICE_NAMES[$idx]}")
        case "$svc_type" in
            frontend)
                echo "$idx"
                return 0
                ;;
            database|cache|worker)
                ;;
            *)
                [[ -n "$fallback" ]] || fallback="$idx"
                ;;
        esac
    done
    echo "${fallback:-0}"
}

# Generate Kubernetes manifests from SERVICE_NAMES, SERVICE_IMAGES and SERVICE_PORTS.
# Datastores, caches and workers are never given a LoadBalancer. The primary service
# always gets one otherwise; with "expose_all" so does every frontend and backend.
render_manifests() {
    local expose_mode="$1"
    prepare_output_dir
    local output_dir="$DEPLOY_WORK_DIR"

    log "Generating Kubernetes manifests..."

    # Namespace
    cat > "$output_dir/00-namespace.yaml" << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $APP_NAME
  labels:
    app.kubernetes.io/name: $APP_NAME
    app.kubernetes.io/managed-by: mynodeone-deploy
EOF

    # Storage (if requested)
    if [[ "$STORAGE_SIZE" != "none" ]]; then
        cat > "$output_dir/10-storage.yaml" << EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP_NAME}-data
  namespace: $APP_NAME
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $STORAGE_SIZE
EOF
    fi

    local primary_idx memory_limit cpu_limit
    primary_idx=$(find_primary_index)
    memory_limit=$(double_quantity "$MEMORY_REQ")
    cpu_limit=$(double_quantity "$CPU_REQ")

    # Services and deployments
    local idx
    for idx in "${!SERVICE_NAMES[@]}"; do
        local svc_name="${SERVICE_NAMES[$idx]}"
        local svc_image="${SERVICE_IMAGES[$idx]}"
        local svc_port="${SERVICE_PORTS[$idx]}"
        local svc_type
        svc_type=$(classify_service "$svc_name")
        local is_primary="false"
        [[ "$idx" == "$primary_idx" ]] && is_primary="true"

        local service_type="ClusterIP"
        case "$svc_type" in
            database|cache|worker)
                ;;
            frontend|backend)
                if [[ "$is_primary" == "true" || "$expose_mode" == "expose_all" ]]; then
                    service_type="LoadBalancer"
                fi
                ;;
            *)
                [[ "$is_primary" == "true" ]] && service_type="LoadBalancer"
                ;;
        esac

        local mount_storage="false"
        [[ "$STORAGE_SIZE" != "none" && "$is_primary" == "true" ]] && mount_storage="true"

        # A ReadWriteOnce volume cannot be attached to pods on two nodes, and two
        # replicas of a datastore would each hold different data.
        local replicas=2
        if [[ "$mount_storage" == "true" || "$svc_type" == "database" || "$svc_type" == "cache" ]]; then
            replicas=1
        fi

        cat > "$output_dir/20-${svc_name}.yaml" << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-${svc_name}
  namespace: $APP_NAME
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${APP_NAME}
      component: ${svc_name}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        component: ${svc_name}
    spec:
      containers:
      - name: ${svc_name}
        image: ${svc_image}
        ports:
        - containerPort: ${svc_port}
          name: http
        resources:
          requests:
            memory: "${MEMORY_REQ}"
            cpu: "${CPU_REQ}"
          limits:
            memory: "${memory_limit}"
            cpu: "${cpu_limit}"
        livenessProbe:
          tcpSocket:
            port: ${svc_port}
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: ${svc_port}
          initialDelaySeconds: 10
          periodSeconds: 5
$(if [[ "$mount_storage" == "true" ]]; then
cat << VOLMOUNT
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${APP_NAME}-data
VOLMOUNT
fi)

---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-${svc_name}
  namespace: $APP_NAME
$(if [[ "$is_primary" == "true" ]]; then
cat << ANNOTATIONS
  annotations:
    mynodeone.io/subdomain: "${LOCAL_SUBDOMAIN}"
    mynodeone.io/auto-register: "true"
ANNOTATIONS
fi)
spec:
  type: ${service_type}
  ports:
  - port: 80
    targetPort: ${svc_port}
  selector:
    app: ${APP_NAME}
    component: ${svc_name}
EOF
    done

    success "Manifests generated in: $output_dir"
    MANIFEST_DIR="$output_dir"
    echo ""
}

# Generate manifests from interactive input
generate_manifests() {
    render_manifests "primary_only"
}

# Extract service details from docker-compose
extract_service_details() {
    local compose_file="$1"
    local service_name="$2"
    
    # The lines belonging to this service
    local block
    block=$(awk -v svc="$service_name" '
        $0 ~ "^  " svc ":" { in_service = 1; next }
        in_service && /^([^ #]| [^ #]|  [^ #])/ { exit }
        in_service { print }
    ' "$compose_file")

    # Extract image
    local image
    image=$(printf '%s\n' "$block" | awk '$1 == "image:" { print $2; exit }' | tr -d "\"'")

    # Extract the container side of the first published port ("8080:80", "127.0.0.1:80:80/tcp")
    local port
    port=$(printf '%s\n' "$block" | awk '
        /^ *ports:/ { in_ports = 1; next }
        in_ports && /^ *-/ { print; exit }
        in_ports { in_ports = 0 }
    ' | sed -E 's/^ *- *//; s/["'"'"' ]//g; s#/[a-z]+$##; s/.*://')

    # If no published port, try the "expose" section
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        port=$(printf '%s\n' "$block" | awk '
            /^ *expose:/ { in_expose = 1; next }
            in_expose && /^ *-/ { print; exit }
            in_expose { in_expose = 0 }
        ' | sed -E 's/^ *- *//; s/["'"'"' ]//g')
    fi

    # The port is what the health probes check, so a wrong guess fails the deployment
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        case "$image" in
            *postgres*|*pgvector*|*timescale*) port="5432" ;;
            *mysql*|*mariadb*) port="3306" ;;
            *redis*|*valkey*) port="6379" ;;
            *mongo*) port="27017" ;;
            *) port="" ;;
        esac
    fi

    # Default port if not found
    if [[ -z "$port" ]]; then
        port="80"
    fi
    
    echo "${image}|${port}"
}

# Warn about common docker-compose limitations
check_compose_compatibility() {
    local compose_file="$1"
    
    # Check for build directives
    if grep -q "build:" "$compose_file"; then
        warn "docker-compose.yml contains 'build:' directives"
        echo ""
        echo "  ⚠️  Images need to be pre-built and available in a registry."
        echo "      Kompose cannot build images - only reference existing ones."
        echo ""
        echo "  Fix: Replace 'build:' with 'image:' pointing to registry images."
        echo "  Example: image: myregistry.com/myapp:1.0.0"
        echo ""
    fi
}

# Patch kompose output for MyNodeOne compatibility
patch_kompose_manifests() {
    local output_dir="$1"
    
    log "Patching manifests for MyNodeOne..."
    
    # Fix PVC sizes (minimum 1Gi in MyNodeOne)
    for pvc_file in "$output_dir"/*-persistentvolumeclaim.yaml; do
        if [[ -f "$pvc_file" ]]; then
            # Replace any storage size < 1Gi with 1Gi
            sed -i 's/storage: [0-9]*Mi$/storage: 1Gi/' "$pvc_file"
            sed -i 's/storage: [0-9]*Ki$/storage: 1Gi/' "$pvc_file"
            # Add storageClassName if missing
            if ! grep -q "storageClassName:" "$pvc_file"; then
                sed -i '/spec:/a\  storageClassName: longhorn' "$pvc_file"
            fi
        fi
    done
    
    # Convert ClusterIP services to LoadBalancer for frontend/backend services
    # This is critical - kompose creates ClusterIP by default!
    local patched_count=0
    for svc_file in "$output_dir"/*-service.yaml; do
        if [[ -f "$svc_file" ]]; then
            # Extract service name from filename
            local svc_name=$(basename "$svc_file" | sed 's/-service.yaml$//')
            
            # Check if this is a frontend or backend service
            if [[ -n "${SERVICE_TYPES[$svc_name]:-}" ]]; then
                local svc_type="${SERVICE_TYPES[$svc_name]}"
                
                if [[ "$svc_type" == "frontend" || "$svc_type" == "backend" ]]; then
                    # Must add type field if missing, or change existing ClusterIP
                    if grep -q "type: ClusterIP" "$svc_file"; then
                        sed -i 's/type: ClusterIP/type: LoadBalancer/' "$svc_file"
                    elif ! grep -q "type:" "$svc_file"; then
                        # Add type field after spec:
                        sed -i '/^spec:/a\  type: LoadBalancer' "$svc_file"
                    fi
                    echo "  ✓ $svc_name: Changed to LoadBalancer (public-facing service)"
                    patched_count=$((patched_count + 1))
                fi
            fi
        fi
    done
    
    if [[ $patched_count -eq 0 ]]; then
        warn "No services converted to LoadBalancer (check SERVICE_TYPES array)"
    fi
    
    success "Manifests patched"
}

# Convert docker-compose to Kubernetes
convert_docker_compose() {
    local compose_file="$1"
    
    log "Converting docker-compose.yml to Kubernetes..."
    
    # Use kompose if available
    if command -v kompose &> /dev/null; then
        prepare_output_dir
        local output_dir="$DEPLOY_WORK_DIR"

        if (cd "$(dirname "$compose_file")" && kompose convert -f "$(basename "$compose_file")" -o "$output_dir") &>/dev/null; then
            success "Converted with kompose"
            
            # Check for common compatibility issues
            check_compose_compatibility "$compose_file"
            
            # IMPORTANT: Detect service types FIRST (needed for patching)
            detect_service_types
            
            # Patch manifests for MyNodeOne compatibility
            patch_kompose_manifests "$output_dir"
            
            MANIFEST_DIR="$output_dir"
            
            # Ask for app name and basic config (kompose doesn't know about our conventions)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  App Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            prompt_app_identity || return 1

            # Update namespace in all manifests
            for manifest in "$output_dir"/*.yaml; do
                if [[ -f "$manifest" ]]; then
                    # Add namespace if not present, or update default namespace
                    if grep -q "namespace: default" "$manifest"; then
                        sed -i "s/namespace: default/namespace: $APP_NAME/g" "$manifest"
                    elif ! grep -q "namespace:" "$manifest" && grep -q "kind: " "$manifest"; then
                        # Add namespace to metadata
                        sed -i "/^metadata:/a\  namespace: $APP_NAME" "$manifest"
                    fi
                fi
            done
            
            # Create namespace manifest if not exists
            if [[ ! -f "$output_dir/00-namespace.yaml" ]]; then
                cat > "$output_dir/00-namespace.yaml" << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $APP_NAME
  labels:
    app.kubernetes.io/name: $APP_NAME
    app.kubernetes.io/managed-by: mynodeone-deploy
EOF
            fi
            
            # Ask about public access
            prompt_public_access

            return 0
        fi
    fi
    
    # Without kompose, extract details from docker-compose directly
    log "Extracting service details from docker-compose.yml..."
    
    # We already have SERVICE_ARRAY from parse_docker_compose
    if [[ ${#SERVICE_ARRAY[@]} -eq 0 ]]; then
        warn "No services detected"
        return 1
    fi
    
    # Filter out non-container services (volumes, networks)
    local REAL_SERVICES=()
    SERVICE_IMAGES=()
    SERVICE_PORTS=()

    for svc in "${SERVICE_ARRAY[@]}"; do
        # Extract service details
        local details=$(extract_service_details "$compose_file" "$svc")
        local image=$(echo "$details" | cut -d'|' -f1)
        local port=$(echo "$details" | cut -d'|' -f2)
        if [[ -z "$port" ]]; then
            port="80"
        fi

        # Skip if no image (likely a volume or network definition)
        if [[ -z "$image" ]]; then
            continue
        fi
        
        REAL_SERVICES+=("$svc")
        SERVICE_IMAGES+=("$image")
        SERVICE_PORTS+=("$port")
        
        echo "  ✓ $svc: $image (port $port)"
    done
    
    # Update global arrays
    SERVICE_ARRAY=("${REAL_SERVICES[@]}")
    SERVICE_NAMES=("${REAL_SERVICES[@]}")

    echo ""
    success "Extracted ${#SERVICE_ARRAY[@]} services from docker-compose"

    echo ""
    prompt_app_identity || return 1

    # Resource requirements
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Resource Requirements"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    ask "Memory per service?"
    echo "  Examples: 256Mi, 512Mi, 1Gi, 2Gi"
    read -p "Memory [512Mi]: " MEMORY_REQ
    MEMORY_REQ=${MEMORY_REQ:-512Mi}
    
    ask "CPU per service?"
    echo "  Examples: 100m (0.1 core), 500m (0.5 core), 1000m (1 core)"
    read -p "CPU [500m]: " CPU_REQ
    CPU_REQ=${CPU_REQ:-500m}
    
    echo ""
    
    ask "Need persistent storage?"
    read -p "Storage size (or 'none') [10Gi]: " STORAGE_SIZE
    STORAGE_SIZE=${STORAGE_SIZE:-10Gi}
    
    echo ""
    prompt_public_access

    # Generate manifests with extracted data
    render_manifests "expose_all"

    return 0
}

# Deploy manifests to cluster
deploy_to_cluster() {
    local manifest_dir="$1"
    
    log "Deploying to MyNodeOne cluster..."
    echo ""
    
    # Apply manifests
    local apply_output
    if ! apply_output=$(kubectl apply -f "$manifest_dir/" 2>&1); then
        echo "$apply_output"
        echo ""
        error "kubectl apply failed, so the app was not deployed"
        return 1
    fi
    echo "$apply_output" | grep -v "unchanged" || true

    echo ""
    log "Waiting for deployment..."

    # Wait for deployment
    sleep 5

    if [[ -z "$(kubectl get deployments -n "$APP_NAME" -o name 2>/dev/null)" ]]; then
        echo ""
        warn "No Deployments found in namespace '$APP_NAME', so there is nothing to wait for"
        return 0
    fi

    local wait_output
    if ! wait_output=$(kubectl wait --for=condition=available --timeout=180s \
        deployment -n "$APP_NAME" --all 2>&1); then
        echo "$wait_output"
        echo ""
        kubectl get pods -n "$APP_NAME" 2>&1 || true
        echo ""
        error "The app did not become available within 180s"
        echo "  Check why: kubectl describe pods -n $APP_NAME"
        return 1
    fi

    echo ""
    success "Deployment complete"
}

# Register with MyNodeOne
register_app() {
    log "Registering with MyNodeOne..."
    
    # Get the primary service name (prefer LoadBalancer type)
    local primary_service=$(kubectl get svc -n "$APP_NAME" -o json | \
        jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.name' | head -1)
    
    if [[ -z "$primary_service" ]]; then
        # Fallback to any service
        primary_service=$(kubectl get svc -n "$APP_NAME" -o name | head -1 | cut -d'/' -f2)
    fi
    
    if [[ -z "$primary_service" ]]; then
        warn "No service found to register"
        return 1
    fi
    
    log "Primary service: $primary_service"
    
    # Wait for LoadBalancer IP with improved retry and logging
    local max_wait=60  # Increased to 60 seconds
    local waited=0
    local retry_interval=3
    LB_IP=""
    
    log "Waiting for MetalLB to assign LoadBalancer IP (up to ${max_wait}s)..."
    echo ""
    
    while [[ $waited -lt $max_wait ]]; do
        LB_IP=$(kubectl get svc -n "$APP_NAME" "$primary_service" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$LB_IP" ]]; then
            echo ""
            success "LoadBalancer IP assigned: $LB_IP (after ${waited}s)"
            break
        fi
        
        # Show progress every 6 seconds
        if [[ $((waited % 6)) -eq 0 ]]; then
            echo "  ⏱️  Still waiting... (${waited}/${max_wait}s) - Checking MetalLB IP assignment"
        fi
        
        sleep $retry_interval
        waited=$((waited + retry_interval))
    done
    
    echo ""
    
    if [[ -z "$LB_IP" ]]; then
        warn "LoadBalancer IP not assigned after ${max_wait}s"
        echo ""
        echo "📊 Debugging Information:"
        echo ""
        
        # Check service status
        local svc_status=$(kubectl get svc -n "$APP_NAME" "$primary_service" 2>/dev/null)
        if [[ -n "$svc_status" ]]; then
            echo "  Service exists but IP is pending. Possible causes:"
            echo "    1. MetalLB IP pool exhausted"
            echo "    2. MetalLB controller not running"
            echo "    3. Network configuration issue"
        else
            echo "  Service not found - this is unexpected"
        fi
        
        echo ""
        echo "🔍 Check MetalLB status:"
        echo "   kubectl get pods -n metallb-system"
        echo "   kubectl get ipaddresspool -n metallb-system"
        echo "   kubectl describe svc -n $APP_NAME $primary_service"
        echo ""
        echo "⏰ Manual registration (run after IP is assigned):"
        echo "   # Check when IP is ready:"
        echo "   kubectl get svc -n $APP_NAME $primary_service -w"
        echo ""
        echo "   # Then register:"
        echo "   sudo bash $MYNODEONE_ROOT/scripts/lib/service-registry.sh register \\"
        echo "       $APP_NAME $LOCAL_SUBDOMAIN $APP_NAME $primary_service 80 false"
        echo "   sudo bash $MYNODEONE_ROOT/scripts/domains/sync-dns.sh"
        echo ""
        echo "🚀 Access your app now (without local DNS):"
        local nodeport=$(kubectl get svc -n "$APP_NAME" "$primary_service" \
            -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
        if [[ -n "$nodeport" ]]; then
            echo "   Via NodePort: http://<node-ip>:$nodeport"
        fi
        echo "   Via port-forward: kubectl port-forward -n $APP_NAME svc/$primary_service 8080:80"
        echo "                     http://localhost:8080"
        echo ""
        return 1
    fi
    
    # Register with service registry
    if [[ -f "$MYNODEONE_ROOT/scripts/lib/service-registry.sh" ]]; then
        log "Registering for local DNS ($LOCAL_SUBDOMAIN.${CLUSTER_DOMAIN}.local)..."
        if bash "$MYNODEONE_ROOT/scripts/lib/service-registry.sh" register \
            "$APP_NAME" "$LOCAL_SUBDOMAIN" "$APP_NAME" "$primary_service" "80" "false" &>/dev/null; then
            success "Registered with service registry"
        else
            warn "Registration failed (but app is still accessible via IP)"
        fi
    fi
    
    # Update DNS
    if [[ -f "$MYNODEONE_ROOT/scripts/domains/sync-dns.sh" ]]; then
        log "Updating local DNS..."
        if bash "$MYNODEONE_ROOT/scripts/domains/sync-dns.sh" &>/dev/null; then
            success "DNS updated"
        else
            warn "DNS sync failed (run manually: sudo bash $MYNODEONE_ROOT/scripts/domains/sync-dns.sh)"
        fi
    fi
    
    echo ""
    success "App registered: http://$LOCAL_SUBDOMAIN.${CLUSTER_DOMAIN}.local"
}

# Configure public domains with intelligent mapping
configure_public_domains() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Public Domain Setup (Simplified)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Choose how you want to configure public domains:"
    echo ""
    echo "  1. Auto-detect (Recommended)"
    echo "     • Just provide your base domain (e.g., myapp.com)"
    echo "     • Script auto-creates subdomains based on services"
    echo "     • Example: api.myapp.com, app.myapp.com, admin.myapp.com"
    echo ""
    echo "  2. Manual entry"
    echo "     • You specify exact domains for each service"
    echo "     • Use when you have custom domain structure"
    echo ""
    echo "  3. Single domain"
    echo "     • All traffic goes to one service (main app)"
    echo "     • Other services are internal only"
    echo ""
    
    read -p "Choice [1]: " domain_choice
    domain_choice=${domain_choice:-1}
    
    case $domain_choice in
        1)
            auto_configure_domains
            ;;
        2)
            manual_configure_domains
            ;;
        3)
            single_domain_configure
            ;;
        *)
            auto_configure_domains
            ;;
    esac
}

# Auto-configure domains based on service types
auto_configure_domains() {
    echo ""
    ask "What's your base domain?"
    echo "  Example: myapp.com"
    read -p "Base domain: " BASE_DOMAIN
    
    if [[ -z "$BASE_DOMAIN" ]]; then
        error "Base domain required"
        PUBLIC_DOMAINS=""
        return 1
    fi
    
    echo ""
    ask "How do you want to expose the main app?"
    echo "  1. Subdomain (voting.${BASE_DOMAIN})"
    echo "  2. Apex/Root domain (${BASE_DOMAIN})"
    echo ""
    read -p "Choice [1]: " domain_type_choice
    domain_type_choice=${domain_type_choice:-1}
    
    echo ""
    log "Auto-detecting subdomain mapping..."
    echo ""
    
    declare -a AUTO_DOMAINS
    declare -g -A DOMAIN_SERVICE_MAP
    
    # First, add main app domain (primary entry point)
    local main_domain=""
    if [[ "$domain_type_choice" == "2" ]]; then
        main_domain="${BASE_DOMAIN}"  # Apex domain
    else
        main_domain="${LOCAL_SUBDOMAIN}.${BASE_DOMAIN}"  # Subdomain
    fi
    local primary_service=""
    
    # Find primary frontend service
    for svc in "${SERVICE_ARRAY[@]}"; do
        local svc_type="${SERVICE_TYPES[$svc]:-internal}"
        if [[ "$svc_type" == "frontend" ]]; then
            if [[ -z "$primary_service" ]]; then
                primary_service="$svc"
            fi
        fi
    done
    
    if [[ -n "$primary_service" ]]; then
        AUTO_DOMAINS+=("$main_domain")
        DOMAIN_SERVICE_MAP["$main_domain"]="$primary_service"
        echo "  ✓ ${main_domain} → ${primary_service} (main app)"
    fi
    
    # Map additional frontend/backend services to conventional subdomains
    local exposed_count=0
    declare -a INTERNAL_SERVICES
    
    for svc in "${SERVICE_ARRAY[@]}"; do
        local svc_type="${SERVICE_TYPES[$svc]:-internal}"
        local subdomain=""
        
        case "$svc_type" in
            frontend)
                # If service is named "vote" or "result", use that name
                if [[ "$svc" =~ ^(vote|result|app|web|ui)$ ]]; then
                    subdomain="$svc"
                else
                    subdomain="app"
                fi
                exposed_count=$((exposed_count + 1))
                ;;
            backend)
                subdomain="api"
                exposed_count=$((exposed_count + 1))
                ;;
            admin)
                subdomain="admin"
                exposed_count=$((exposed_count + 1))
                ;;
            database|cache|worker|internal)
                # Internal services - no public domain
                INTERNAL_SERVICES+=("$svc")
                continue
                ;;
        esac
        
        local full_domain="${subdomain}.${BASE_DOMAIN}"
        AUTO_DOMAINS+=("$full_domain")
        DOMAIN_SERVICE_MAP["$full_domain"]="$svc"
        
        echo "  ✓ ${full_domain} → ${svc} (additional service)"
    done
    
    echo ""
    if [[ ${#INTERNAL_SERVICES[@]} -gt 0 ]]; then
        echo "  Internal services (not exposed):" 
        for internal_svc in "${INTERNAL_SERVICES[@]}"; do
            echo "    • $internal_svc (${SERVICE_TYPES[$internal_svc]:-internal})"
        done
    fi
    
    echo ""
    
    if [[ $exposed_count -eq 0 ]]; then
        warn "No public-facing services detected (all services are internal)"
        warn "Your app will only be accessible locally: http://${LOCAL_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        PUBLIC_DOMAINS=""
        return 1
    fi
    
    success "Auto-configured ${#AUTO_DOMAINS[@]} public domain(s)"
    
    PUBLIC_DOMAINS="${AUTO_DOMAINS[@]}"
    
    echo ""
    echo "📝 Next Steps After Deployment:"
    echo ""
    echo "  1. Configure DNS at your domain registrar (GoDaddy, Cloudflare, etc.):"
    echo ""
    for domain in "${AUTO_DOMAINS[@]}"; do
        echo "     Add A record: ${domain} → <YOUR_VPS_PUBLIC_IP>"
    done
    echo ""
    echo "  2. Run this command to enable public access + SSL:"
    echo "     sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh"
    echo ""
    echo "  3. Access your app (after DNS propagates ~5-30 min):"
    echo ""
    # Show main app first
    if [[ -n "$main_domain" ]]; then
        echo "     🌟 Main app: https://$main_domain"
    fi
    # Then show additional services
    for domain in "${AUTO_DOMAINS[@]}"; do
        if [[ "$domain" != "$main_domain" ]]; then
            echo "        https://$domain"
        fi
    done
    echo ""
    echo "  📖 See external-apps/DOMAIN-SSL-WORKFLOW.md for detailed explanation"
    echo ""
}

# Manual domain configuration
manual_configure_domains() {
    echo ""
    ask "Enter public domains (comma-separated)"
    echo "  Example: app.myapp.com,api.myapp.com,admin.myapp.com"
    read -p "Domains: " PUBLIC_DOMAINS
    
    if [[ -z "$PUBLIC_DOMAINS" ]]; then
        PUBLIC_DOMAINS=""
        return 1
    fi
    
    # Parse domains
    IFS=',' read -ra DOMAIN_ARRAY <<< "$PUBLIC_DOMAINS"
    declare -a CLEAN_DOMAINS
    for domain in "${DOMAIN_ARRAY[@]}"; do
        domain=$(echo "$domain" | xargs)
        CLEAN_DOMAINS+=("$domain")
    done
    
    # If we have services detected, try to map intelligently
    if [[ -n "${SERVICE_ARRAY:-}" ]]; then
        echo ""
        log "Mapping domains to services..."
        echo ""
        
        declare -g -A DOMAIN_SERVICE_MAP
        
        for domain in "${CLEAN_DOMAINS[@]}"; do
            # Try intelligent matching first
            local matched=false
            
            # Check domain for hints (api., app., admin., etc.)
            if [[ "$domain" =~ api\. ]]; then
                # Find backend service
                for svc in "${SERVICE_ARRAY[@]}"; do
                    if [[ "${SERVICE_TYPES[$svc]:-}" == "backend" ]]; then
                        DOMAIN_SERVICE_MAP["$domain"]="$svc"
                        echo "  ✓ $domain → $svc (auto-matched: backend)"
                        matched=true
                        break
                    fi
                done
            elif [[ "$domain" =~ (app\.|www\.) ]]; then
                # Find frontend service
                for svc in "${SERVICE_ARRAY[@]}"; do
                    if [[ "${SERVICE_TYPES[$svc]:-}" == "frontend" ]]; then
                        DOMAIN_SERVICE_MAP["$domain"]="$svc"
                        echo "  ✓ $domain → $svc (auto-matched: frontend)"
                        matched=true
                        break
                    fi
                done
            elif [[ "$domain" =~ admin\. ]]; then
                # Find admin service
                for svc in "${SERVICE_ARRAY[@]}"; do
                    if [[ "${SERVICE_TYPES[$svc]:-}" == "admin" ]]; then
                        DOMAIN_SERVICE_MAP["$domain"]="$svc"
                        echo "  ✓ $domain → $svc (auto-matched: admin)"
                        matched=true
                        break
                    fi
                done
            fi
            
            # If not auto-matched, ask user
            if [[ "$matched" == "false" ]]; then
                echo ""
                echo "Which service should handle: $domain?"
                for idx in "${!SERVICE_ARRAY[@]}"; do
                    local svc="${SERVICE_ARRAY[$idx]}"
                    local svc_type="${SERVICE_TYPES[$svc]:-unknown}"
                    echo "  $((idx+1)). $svc ($svc_type)"
                done
                
                read -p "Service # [1]: " svc_choice
                svc_choice=${svc_choice:-1}
                svc_idx=$((svc_choice-1))
                
                DOMAIN_SERVICE_MAP["$domain"]="${SERVICE_ARRAY[$svc_idx]}"
                echo "  ✓ $domain → ${SERVICE_ARRAY[$svc_idx]}"
            fi
        done
    fi
    
    PUBLIC_DOMAINS="${CLEAN_DOMAINS[@]}"
}

# Single domain configuration
single_domain_configure() {
    echo ""
    ask "What's your public domain?"
    read -p "Domain: " SINGLE_DOMAIN
    
    if [[ -z "$SINGLE_DOMAIN" ]]; then
        PUBLIC_DOMAINS=""
        return 1
    fi
    
    PUBLIC_DOMAINS="$SINGLE_DOMAIN"
    
    # Map to primary service (frontend or first service)
    if [[ -n "${SERVICE_ARRAY:-}" ]]; then
        local primary_svc=""
        
        # Try to find frontend
        for svc in "${SERVICE_ARRAY[@]}"; do
            if [[ "${SERVICE_TYPES[$svc]:-}" == "frontend" ]]; then
                primary_svc="$svc"
                break
            fi
        done
        
        # Fallback to first service
        if [[ -z "$primary_svc" ]]; then
            primary_svc="${SERVICE_ARRAY[0]}"
        fi
        
        declare -g -A DOMAIN_SERVICE_MAP
        DOMAIN_SERVICE_MAP["$SINGLE_DOMAIN"]="$primary_svc"
        
        echo ""
        success "$SINGLE_DOMAIN → $primary_svc"
    fi
}

# Configure public access with improved mapping
configure_public_access() {
    if [[ -z "$PUBLIC_DOMAINS" ]]; then
        return 0
    fi
    
    echo ""
    log "Finalizing public access configuration..."
    
    echo ""
    success "Public domains configured"
    echo ""
    echo "To complete public setup:"
    echo ""
    echo "  1. Add DNS A records at your domain registrar:"
    echo ""
    for domain in $PUBLIC_DOMAINS; do
        echo "     $domain    A    <YOUR_VPS_IP>"
    done
    echo ""
    echo "  2. Run the visibility manager:"
    echo "     sudo $MYNODEONE_ROOT/scripts/operations/manage-app-visibility.sh"
    echo ""
    echo "  3. Wait for DNS propagation (~5-30 minutes)"
    echo ""
}

# Show deployment summary
show_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Deployment Complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📦 App: $APP_NAME"
    echo ""
    
    # Check if we have LoadBalancer IP
    local has_lb_ip=false
    if kubectl get svc -n "$APP_NAME" -o json | jq -e '.items[] | select(.spec.type=="LoadBalancer" and .status.loadBalancer.ingress[0].ip)' &>/dev/null; then
        has_lb_ip=true
    fi
    
    echo "🌐 Access your app:"
    echo ""
    
    if [[ "$has_lb_ip" == "true" ]]; then
        echo "  ✓ Local DNS:  http://$LOCAL_SUBDOMAIN.${CLUSTER_DOMAIN}.local"
        echo "  ✓ Direct IP:  http://$(kubectl get svc -n "$APP_NAME" -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .status.loadBalancer.ingress[0].ip' | head -1)"
        echo ""
        echo "  ℹ️  Note: '$APP_NAME' is your app name (Kubernetes namespace)"
        echo "          Individual services: $(kubectl get svc -n "$APP_NAME" -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.name' | paste -sd, -)"
        echo "   2. Run: sudo $MYNODEONE_ROOT/scripts/operations/manage-app-visibility.sh"
        echo "   3. Access your app at: https://$(echo $PUBLIC_DOMAINS | awk '{print $1}')"
    else
        echo "   1. Access your app at: http://${LOCAL_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        echo "   2. To make it public, run: sudo $MYNODEONE_ROOT/scripts/operations/manage-app-visibility.sh"
    fi
    
    echo ""
    success "All done! 🚀"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    
    # Detect app structure
    APP_DIR="${1:-.}"
    detect_app_structure "$APP_DIR"
    
    case "$APP_TYPE" in
        docker-compose)
            if parse_docker_compose "$COMPOSE_FILE"; then
                if convert_docker_compose "$COMPOSE_FILE"; then
                    # Successfully converted
                    :
                else
                    # Fall back to interactive
                    interactive_setup
                    generate_manifests
                fi
            else
                interactive_setup
                generate_manifests
            fi
            ;;
        kubernetes)
            log "Using existing Kubernetes manifests"
            MANIFEST_DIR="$K8S_DIR"
            # Still ask for app name and domains
            ask "App name?"
            read -p "Name: " APP_NAME
            APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
            if [[ -z "$APP_NAME" ]]; then
                error "App name is required"
                exit 1
            fi
            LOCAL_SUBDOMAIN="$APP_NAME"
            ;;
        *)
            interactive_setup
            generate_manifests
            ;;
    esac
    
    # Deploy
    deploy_to_cluster "$MANIFEST_DIR"
    
    # Register
    register_app
    
    # Public access
    configure_public_access
    
    # Summary
    show_summary
}

# Run
main "$@"
