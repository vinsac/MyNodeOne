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
MYNODEONE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Get cluster domain from cluster-info ConfigMap (authoritative source)
CLUSTER_DOMAIN=""
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    CLUSTER_DOMAIN=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
fi

# If not found, use default
if [ -z "$CLUSTER_DOMAIN" ]; then
    CLUSTER_DOMAIN="mynodeone"
fi

log() { echo -e "${BLUE}▶${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
ask() { echo -e "${CYAN}?${NC} $1"; }

clear
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

# Detect service types based on naming conventions
detect_service_types() {
    declare -g -A SERVICE_TYPES
    
    for svc in "${SERVICE_ARRAY[@]}"; do
        local svc_lower=$(echo "$svc" | tr '[:upper:]' '[:lower:]')
        
        # Detect common service types
        if [[ "$svc_lower" =~ (vote|result) ]]; then
            # Voting app specific
            SERVICE_TYPES["$svc"]="frontend"
        elif [[ "$svc_lower" =~ (frontend|web|ui|client) ]]; then
            SERVICE_TYPES["$svc"]="frontend"
        elif [[ "$svc_lower" =~ (backend|api|server) ]]; then
            SERVICE_TYPES["$svc"]="backend"
        elif [[ "$svc_lower" =~ (admin|dashboard) ]]; then
            SERVICE_TYPES["$svc"]="admin"
        elif [[ "$svc_lower" =~ (db|database|postgres|mysql|mongo) ]]; then
            SERVICE_TYPES["$svc"]="database"
        elif [[ "$svc_lower" =~ (redis|cache|memcache) ]]; then
            SERVICE_TYPES["$svc"]="cache"
        elif [[ "$svc_lower" =~ (worker|queue|celery|seed) ]]; then
            SERVICE_TYPES["$svc"]="worker"
        else
            SERVICE_TYPES["$svc"]="internal"
        fi
    done
}

# Interactive app setup
interactive_setup() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Interactive App Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # App name
    ask "What's your app name? (lowercase, no spaces)"
    read -p "App name: " APP_NAME
    APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    
    if [[ -z "$APP_NAME" ]]; then
        error "App name required"
        exit 1
    fi
    
    success "App name: $APP_NAME"
    echo ""
    
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
    declare -a SERVICE_NAMES
    declare -a SERVICE_IMAGES
    declare -a SERVICE_PORTS
    
    for ((i=1; i<=NUM_SERVICES; i++)); do
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Service $i Configuration"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        ask "Service $i name? (e.g., frontend, backend, api)"
        read -p "Name: " svc_name
        svc_name=$(echo "$svc_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        SERVICE_NAMES+=("$svc_name")
        
        ask "Docker image for $svc_name?"
        echo "  Examples:"
        echo "  • your-registry/myapp:latest"
        echo "  • ghcr.io/username/myapp:v1.0"
        echo "  • docker.io/library/nginx:alpine"
        read -p "Image: " svc_image
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
    
    # Domains
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Domain Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    ask "Local subdomain for your app?"
    echo "  This will be: <subdomain>.${CLUSTER_DOMAIN}.local"
    read -p "Subdomain [$APP_NAME]: " LOCAL_SUBDOMAIN
    LOCAL_SUBDOMAIN=${LOCAL_SUBDOMAIN:-$APP_NAME}
    LOCAL_SUBDOMAIN=$(echo "$LOCAL_SUBDOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    
    success "Subdomain: $LOCAL_SUBDOMAIN"
    echo "  Access: http://$LOCAL_SUBDOMAIN.${CLUSTER_DOMAIN}.local"
    echo ""
    
    ask "Do you want public internet access?"
    read -p "Make public? [y/N]: " MAKE_PUBLIC
    
    if [[ "$MAKE_PUBLIC" =~ ^[Yy] ]]; then
        configure_public_domains
    else
        PUBLIC_DOMAINS=""
    fi
    
    echo ""
}

# Generate manifests from docker-compose extracted data
generate_manifests_from_compose() {
    local output_dir="/tmp/mynodeone-deploy-$$"
    mkdir -p "$output_dir"
    
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
    
    # Services and deployments
    for idx in "${!SERVICE_ARRAY[@]}"; do
        local svc_name="${SERVICE_ARRAY[$idx]}"
        local svc_image="${SERVICE_IMAGES[$idx]}"
        local svc_port="${SERVICE_PORTS[$idx]}"
        local svc_type="${SERVICE_TYPES[$svc_name]:-service}"
        local is_primary=$([[ $idx -eq 0 ]] && echo "true" || echo "false")
        
        # Skip internal services for LoadBalancer
        local service_type="ClusterIP"
        if [[ "$svc_type" == "frontend" || "$svc_type" == "backend" ]]; then
            service_type="LoadBalancer"
        fi
        
        cat > "$output_dir/20-${svc_name}.yaml" << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-${svc_name}
  namespace: $APP_NAME
spec:
  replicas: 2
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
            memory: "$(echo $MEMORY_REQ | sed 's/Mi$/*2Mi/;s/Gi$/*2Gi/' | bc 2>/dev/null || echo ${MEMORY_REQ})"
            cpu: "$(echo $CPU_REQ | sed 's/m$/*2m/' | bc 2>/dev/null || echo ${CPU_REQ})"
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

---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-${svc_name}
  namespace: $APP_NAME
$([[ "$is_primary" == "true" ]] && cat << ANNOTATIONS
  annotations:
    mynodeone.io/subdomain: "${LOCAL_SUBDOMAIN}"
    mynodeone.io/auto-register: "true"
ANNOTATIONS
)
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

# Generate Kubernetes manifests from interactive input
generate_manifests() {
    local output_dir="/tmp/mynodeone-deploy-$$"
    mkdir -p "$output_dir"
    
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
    
    # Services and deployments
    for idx in "${!SERVICE_NAMES[@]}"; do
        local svc_name="${SERVICE_NAMES[$idx]}"
        local svc_image="${SERVICE_IMAGES[$idx]}"
        local svc_port="${SERVICE_PORTS[$idx]}"
        local is_primary=$([[ $idx -eq 0 ]] && echo "true" || echo "false")
        
        cat > "$output_dir/20-${svc_name}.yaml" << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-${svc_name}
  namespace: $APP_NAME
spec:
  replicas: 2
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
            memory: "$(echo $MEMORY_REQ | sed 's/Mi/*2Mi/;s/Gi/*2Gi/' | bc 2>/dev/null || echo $MEMORY_REQ)"
            cpu: "$(echo $CPU_REQ | sed 's/m/*2m/' | bc 2>/dev/null || echo $CPU_REQ)"
$(if [[ "$STORAGE_SIZE" != "none" && "$is_primary" == "true" ]]; then
cat << 'VOLMOUNT'
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${APP_NAME}-data
VOLMOUNT
else
echo "        livenessProbe:"
echo "          httpGet:"
echo "            path: /"
echo "            port: ${svc_port}"
echo "          initialDelaySeconds: 30"
echo "        readinessProbe:"
echo "          httpGet:"
echo "            path: /"
echo "            port: ${svc_port}"
echo "          initialDelaySeconds: 10"
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
  type: $([[ "$is_primary" == "true" ]] && echo "LoadBalancer" || echo "ClusterIP")
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

# Extract service details from docker-compose
extract_service_details() {
    local compose_file="$1"
    local service_name="$2"
    
    # Extract image
    local image=$(grep -A 10 "^  ${service_name}:" "$compose_file" | grep "image:" | head -1 | awk '{print $2}' | tr -d '"')
    
    # Extract ports (first exposed port)
    local port=$(grep -A 20 "^  ${service_name}:" "$compose_file" | grep -E "^    - .*:.*" | head -1 | awk -F: '{print $NF}' | tr -d ' "')
    
    # If no port in standard format, try "expose" section
    if [[ -z "$port" ]]; then
        port=$(grep -A 20 "^  ${service_name}:" "$compose_file" | grep -A 5 "expose:" | grep "^    -" | head -1 | awk '{print $2}' | tr -d ' "')
    fi
    
    # Default port if not found
    if [[ -z "$port" ]]; then
        port="80"
    fi
    
    echo "${image}|${port}"
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
    for svc_file in "$output_dir"/*-service.yaml; do
        if [[ -f "$svc_file" ]]; then
            # Extract service name from filename
            local svc_name=$(basename "$svc_file" | sed 's/-service.yaml$//')
            
            # Check if this is a frontend or backend service
            if [[ -n "${SERVICE_TYPES[$svc_name]:-}" ]]; then
                local svc_type="${SERVICE_TYPES[$svc_name]}"
                
                if [[ "$svc_type" == "frontend" || "$svc_type" == "backend" ]]; then
                    # Change to LoadBalancer
                    sed -i 's/type: ClusterIP/type: LoadBalancer/' "$svc_file"
                    echo "  ✓ $svc_name: Changed to LoadBalancer (public-facing service)"
                fi
            fi
        fi
    done
    
    success "Manifests patched"
}

# Convert docker-compose to Kubernetes
convert_docker_compose() {
    local compose_file="$1"
    
    log "Converting docker-compose.yml to Kubernetes..."
    
    # Use kompose if available
    if command -v kompose &> /dev/null; then
        local output_dir="/tmp/mynodeone-deploy-$$"
        mkdir -p "$output_dir"
        
        cd "$(dirname "$compose_file")"
        kompose convert -f "$compose_file" -o "$output_dir" &>/dev/null
        
        if [[ $? -eq 0 ]]; then
            success "Converted with kompose"
            
            # Patch manifests for MyNodeOne compatibility
            patch_kompose_manifests "$output_dir"
            
            MANIFEST_DIR="$output_dir"
            
            # Ask for app name and basic config (kompose doesn't know about our conventions)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  App Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
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
            echo "  Access: http://$LOCAL_SUBDOMAIN.${CLUSTER_DOMAIN}.local"
            echo ""
            
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
            ask "Make this app publicly accessible?"
            read -p "Public access [y/N]: " MAKE_PUBLIC
            
            if [[ "$MAKE_PUBLIC" =~ ^[Yy] ]]; then
                configure_public_domains
            else
                PUBLIC_DOMAINS=""
            fi
            
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
    declare -a REAL_SERVICES
    declare -a SERVICE_IMAGES
    declare -a SERVICE_PORTS
    
    for svc in "${SERVICE_ARRAY[@]}"; do
        # Extract service details
        local details=$(extract_service_details "$compose_file" "$svc")
        local image=$(echo "$details" | cut -d'|' -f1)
        local port=$(echo "$details" | cut -d'|' -f2)
        
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
    
    # Ask for resource requirements only
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
    
    # Generate manifests with extracted data
    generate_manifests_from_compose
    
    return 0
}

# Deploy manifests to cluster
deploy_to_cluster() {
    local manifest_dir="$1"
    
    log "Deploying to MyNodeOne cluster..."
    echo ""
    
    # Apply manifests
    kubectl apply -f "$manifest_dir/" 2>&1 | grep -v "unchanged" || true
    
    echo ""
    log "Waiting for deployment..."
    
    # Wait for deployment
    sleep 5
    kubectl wait --for=condition=available --timeout=180s \
        deployment -n "$APP_NAME" --all 2>/dev/null || true
    
    echo ""
    success "Deployment complete!"
}

# Register with MyNodeOne
register_app() {
    log "Registering with MyNodeOne..."
    
    # Get the primary service name
    local primary_service=$(kubectl get svc -n "$APP_NAME" -o name | grep LoadBalancer | head -1 | cut -d'/' -f2 || \
                           kubectl get svc -n "$APP_NAME" -o name | head -1 | cut -d'/' -f2)
    
    if [[ -z "$primary_service" ]]; then
        warn "No service found to register"
        return 1
    fi
    
    # Wait for LoadBalancer IP
    log "Waiting for LoadBalancer IP..."
    local lb_ip=""
    for i in {1..30}; do
        lb_ip=$(kubectl get svc -n "$APP_NAME" "$primary_service" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$lb_ip" ]]; then
            break
        fi
        sleep 2
    done
    
    if [[ -z "$lb_ip" ]]; then
        warn "Could not get LoadBalancer IP"
        return 1
    fi
    
    success "LoadBalancer IP: $lb_ip"
    
    # Register with service registry
    if [[ -f "$MYNODEONE_ROOT/scripts/lib/service-registry.sh" ]]; then
        bash "$MYNODEONE_ROOT/scripts/lib/service-registry.sh" register \
            "$APP_NAME" "$LOCAL_SUBDOMAIN" "$APP_NAME" "$primary_service" "80" "false" &>/dev/null || true
    fi
    
    # Update DNS
    if [[ -f "$MYNODEONE_ROOT/scripts/sync-dns.sh" ]]; then
        bash "$MYNODEONE_ROOT/scripts/sync-dns.sh" &>/dev/null || true
    fi
    
    success "App registered with MyNodeOne"
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
    echo "  Example: myapp.com (we'll create api.myapp.com, app.myapp.com, etc.)"
    read -p "Base domain: " BASE_DOMAIN
    
    if [[ -z "$BASE_DOMAIN" ]]; then
        error "Base domain required"
        PUBLIC_DOMAINS=""
        return 1
    fi
    
    echo ""
    log "Auto-detecting subdomain mapping..."
    echo ""
    
    declare -a AUTO_DOMAINS
    declare -g -A DOMAIN_SERVICE_MAP
    
    # Map ONLY frontend/backend/admin services to conventional subdomains
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
                ;;
            backend)
                subdomain="api"
                ;;
            admin)
                subdomain="admin"
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
        exposed_count=$((exposed_count + 1))
        
        echo "  ✓ ${full_domain} → ${svc} (public)"
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
    echo "     sudo /path/to/MyNodeOne/scripts/manage-app-visibility.sh"
    echo ""
    echo "  3. Access your app (after DNS propagates ~5-30 min):"
    for domain in "${AUTO_DOMAINS[@]}"; do
        echo "     https://$domain  (SSL certificate auto-issued by Let's Encrypt)"
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
    echo "     sudo $MYNODEONE_ROOT/scripts/manage-app-visibility.sh"
    echo ""
    echo "  3. Wait for DNS propagation (~5-30 minutes)"
    echo ""
}

# Show deployment summary
show_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Deployment Complete!"
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
        echo "   2. Run: sudo $MYNODEONE_ROOT/scripts/manage-app-visibility.sh"
        echo "   3. Access your app at: https://$(echo $PUBLIC_DOMAINS | awk '{print $1}')"
    else
        echo "   1. Access your app at: http://${LOCAL_SUBDOMAIN}.mynodeone.local"
        echo "   2. To make it public, run: sudo $MYNODEONE_ROOT/scripts/manage-app-visibility.sh"
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
