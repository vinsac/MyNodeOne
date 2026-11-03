#!/bin/bash

# MyNodeOne Application Management Script
# One-click deployment and removal of common applications

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null
APPS_DIR="$PROJECT_ROOT/manifests/apps"
source "$PROJECT_ROOT/scripts/apps/lib/install-helpers.sh"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install Kubernetes first."
        exit 1
    fi
    
    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        exit 1
    fi
}

# Password for a database in the "databases" namespace, stored in a Secret and reused
# on every re-run. Earlier versions wrote the password directly into the Deployment,
# and the data on disk still depends on it, so such a password is carried over.
# Usage: load_db_password <var> <deployment> <container> <env_name> <secret> <pvc>
load_db_password() {
    local target_var="$1" deployment="$2" container="$3" env_name="$4" db_secret="$5" db_pvc="$6"
    local inline_password=""

    if [ -z "$(kubectl get secret "$db_secret" -n databases --ignore-not-found -o name)" ]; then
        inline_password=$(kubectl get deployment "$deployment" -n databases --ignore-not-found \
            -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$container\")].env[?(@.name==\"$env_name\")].value}")
    fi

    if [ -n "$inline_password" ]; then
        log_warn "$deployment keeps its existing password, moved into Secret '$db_secret'."
        log_warn "If this is the old default, change it inside the database and update the Secret."
        printf -v "$target_var" '%s' "$inline_password"
    else
        app_load_or_create_secret_value "$target_var" databases "$db_secret" password "$db_pvc" -- openssl rand -hex 24
    fi

    # Sent on stdin and base64 encoded, so it is neither in argv nor needs YAML escaping
    kubectl apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $db_secret
  namespace: databases
type: Opaque
data:
  password: $(printf '%s' "${!target_var}" | base64 -w0)
EOF
}

# ===== Available Applications =====

deploy_postgresql() {
    print_header "Deploying PostgreSQL Database"
    
    log_info "Creating namespace..."
    kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -
    
    # shellcheck disable=SC2034  # load_db_password sets and uses the password by name
    local POSTGRES_PASSWORD POSTGRESQL_IMAGE_RESOLVED
    load_db_password POSTGRES_PASSWORD postgresql postgres POSTGRES_PASSWORD postgresql-credentials postgres-pvc
    app_resolve_image POSTGRESQL_IMAGE_RESOLVED databases postgresql postgres "postgres:16.15-alpine" "${POSTGRESQL_IMAGE:-}"

    log_info "Deploying PostgreSQL..."
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  namespace: databases
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgres
        image: $POSTGRESQL_IMAGE_RESOLVED
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-credentials
              key: password
        - name: POSTGRES_USER
          value: "postgres"
        - name: POSTGRES_DB
          value: "myapp"
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: databases
spec:
  type: ClusterIP
  selector:
    app: postgresql
  ports:
  - port: 5432
    targetPort: 5432
EOF
    
    log_success "PostgreSQL deployed"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PostgreSQL Connection Info"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Host: postgresql.databases.svc.cluster.local"
    echo "  Port: 5432"
    echo "  Database: myapp"
    echo "  Username: postgres"
    echo "  Password: kubectl get secret postgresql-credentials -n databases -o jsonpath='{.data.password}' | base64 -d"
    echo
    echo "  To remove: kubectl delete namespace databases"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

deploy_redis() {
    print_header "Deploying Redis Cache"
    
    log_info "Creating namespace..."
    kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -
    
    local REDIS_IMAGE_RESOLVED
    app_resolve_image REDIS_IMAGE_RESOLVED databases redis redis "redis:7.4.12-alpine" "${REDIS_IMAGE:-}"

    log_info "Deploying Redis..."
    cat <<EOF | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: databases
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: $REDIS_IMAGE_RESOLVED
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: databases
spec:
  type: ClusterIP
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF
    
    log_success "Redis deployed"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Redis Connection Info"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Host: redis.databases.svc.cluster.local"
    echo "  Port: 6379"
    echo
    echo "  To remove: kubectl delete deployment redis -n databases"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

deploy_mysql() {
    print_header "Deploying MySQL Database"
    
    log_info "Creating namespace..."
    kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -
    
    # shellcheck disable=SC2034  # load_db_password sets and uses the password by name
    local MYSQL_ROOT_PASSWORD MYSQL_IMAGE_RESOLVED
    load_db_password MYSQL_ROOT_PASSWORD mysql mysql MYSQL_ROOT_PASSWORD mysql-credentials mysql-pvc
    app_resolve_image MYSQL_IMAGE_RESOLVED databases mysql mysql "mysql:8.0.46" "${MYSQL_IMAGE:-}"

    log_info "Deploying MySQL..."
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: databases
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: $MYSQL_IMAGE_RESOLVED
        ports:
        - containerPort: 3306
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-credentials
              key: password
        - name: MYSQL_DATABASE
          value: "myapp"
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: mysql-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: databases
spec:
  type: ClusterIP
  selector:
    app: mysql
  ports:
  - port: 3306
    targetPort: 3306
EOF
    
    log_success "MySQL deployed"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MySQL Connection Info"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Host: mysql.databases.svc.cluster.local"
    echo "  Port: 3306"
    echo "  Database: myapp"
    echo "  Root Password: kubectl get secret mysql-credentials -n databases -o jsonpath='{.data.password}' | base64 -d"
    echo
    echo "  To remove: kubectl delete deployment mysql -n databases"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

list_apps() {
    print_header "Available Applications"
    
    echo "Databases:"
    echo "  postgresql  - PostgreSQL 16 database"
    echo "  mysql       - MySQL 8.0 database"
    echo "  redis       - Redis 7 cache"
    echo
    echo "Demo:"
    echo "  demo        - MyNodeOne demo web app"
    echo
    echo "Usage:"
    echo "  Deploy:  sudo $0 deploy <app-name>"
    echo "  Remove:  sudo $0 remove <app-name>"
    echo "  List:    sudo $0 list"
    echo
    echo "Examples:"
    echo "  sudo $0 deploy postgresql"
    echo "  sudo $0 remove postgresql"
}

show_status() {
    print_header "Deployed Applications Status"
    
    echo "Checking for deployed applications..."
    echo
    
    # Check databases
    if kubectl get namespace databases &> /dev/null; then
        echo "📦 Databases namespace:"
        kubectl get pods,svc -n databases 2>/dev/null || echo "  (empty)"
        echo
    fi
    
    # Check demo
    if kubectl get namespace demo-apps &> /dev/null; then
        echo "📦 Demo Apps namespace:"
        kubectl get pods,svc -n demo-apps 2>/dev/null || echo "  (empty)"
        echo
    fi
    
    echo "To see all namespaces: kubectl get namespaces"
}

deploy_app() {
    local app="$1"
    
    case "$app" in
        postgresql|postgres)
            deploy_postgresql
            ;;
        mysql)
            deploy_mysql
            ;;
        redis)
            deploy_redis
            ;;
        demo)
            bash "$PROJECT_ROOT/scripts/operations/deploy-demo-app.sh" deploy
            ;;
        *)
            log_error "Unknown application: $app"
            echo
            list_apps
            exit 1
            ;;
    esac
}

remove_app() {
    local app="$1"
    
    case "$app" in
        postgresql|postgres)
            log_info "Removing PostgreSQL..."
            kubectl delete deployment postgresql -n databases --ignore-not-found=true
            kubectl delete svc postgresql -n databases --ignore-not-found=true
            kubectl delete pvc postgres-pvc -n databases --ignore-not-found=true
            kubectl delete secret postgresql-credentials -n databases --ignore-not-found=true
            log_success "PostgreSQL removed"
            ;;
        mysql)
            log_info "Removing MySQL..."
            kubectl delete deployment mysql -n databases --ignore-not-found=true
            kubectl delete svc mysql -n databases --ignore-not-found=true
            kubectl delete pvc mysql-pvc -n databases --ignore-not-found=true
            kubectl delete secret mysql-credentials -n databases --ignore-not-found=true
            log_success "MySQL removed"
            ;;
        redis)
            log_info "Removing Redis..."
            kubectl delete deployment redis -n databases --ignore-not-found=true
            kubectl delete svc redis -n databases --ignore-not-found=true
            log_success "Redis removed"
            ;;
        demo)
            bash "$PROJECT_ROOT/scripts/operations/deploy-demo-app.sh" remove
            ;;
        *)
            log_error "Unknown application: $app"
            echo
            list_apps
            exit 1
            ;;
    esac
}

show_help() {
    cat <<EOF
MyNodeOne Application Management Script

Usage: $0 <command> [options]

Commands:
  list                List available applications
  deploy <app>        Deploy an application
  remove <app>        Remove an application
  status              Show status of deployed apps
  help                Show this help message

Available Applications:
  postgresql          PostgreSQL 16 database
  mysql               MySQL 8.0 database
  redis               Redis 7 cache
  demo                Demo web application

Examples:
  # List available apps
  sudo $0 list
  
  # Deploy PostgreSQL
  sudo $0 deploy postgresql
  
  # Remove PostgreSQL
  sudo $0 remove postgresql
  
  # Check status
  sudo $0 status

EOF
}

main() {
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        list)
            list_apps
            ;;
        deploy|install)
            check_kubectl
            if [ $# -eq 0 ]; then
                log_error "Please specify an application to deploy"
                echo
                list_apps
                exit 1
            fi
            deploy_app "$1"
            ;;
        remove|delete|uninstall)
            check_kubectl
            if [ $# -eq 0 ]; then
                log_error "Please specify an application to remove"
                echo
                list_apps
                exit 1
            fi
            remove_app "$1"
            ;;
        status)
            check_kubectl
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
