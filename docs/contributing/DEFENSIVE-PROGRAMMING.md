# Defensive Programming Guidelines

**Purpose:** This document outlines defensive programming techniques and patterns used throughout the MyNodeOne codebase to ensure robust, secure, and maintainable scripts.

---

## User Detection and Context Management

### The Problem
When scripts run with `sudo`, `whoami` returns `root` but we often need the actual user who invoked sudo for:
- Placing config files in the correct home directory
- Setting proper file ownership
- SSH operations with correct user context

### Standard Pattern
```bash
# Source the canonical user detection library
if [[ -f "$LIB_DIR/detect-actual-home.sh" ]]; then
    source "$LIB_DIR/detect-actual-home.sh"
else
    # Fallback: manual detection
    ACTUAL_USER="${SUDO_USER:-$(whoami)}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_HOME="$HOME"
    fi
    CONFIG_DIR="$ACTUAL_HOME/.mynodeone"
fi
```

### Key Principles
- **Never use `whoami` or `$HOME` directly** - use `$ACTUAL_USER` and `$ACTUAL_HOME`
- **Always handle `SUDO_USER`** - detect when running under sudo
- **Provide fallbacks** - scripts should work even if library is missing
- **Export variables** - ensure subshells inherit correct context

---

## File Ownership Management

### The Problem
When scripts create files while running under sudo, those files are owned by root, making them inaccessible to the actual user later.

### Standard Pattern
```bash
# Fix ownership when running as root
if [ "$ACTUAL_USER" != "root" ] && [ "$(whoami)" = "root" ]; then
    chown "$ACTUAL_USER:$ACTUAL_USER" "$FILE_PATH"
fi
```

### Key Principles
- **Check both conditions** - only chown when actual user is not root but current user is root
- **Use consistent ownership** - `$ACTUAL_USER:$ACTUAL_USER`
- **Apply to all created files** - credentials, configs, logs
- **Preserve permissions** - 600 for credentials, 700 for directories

---

## Script Invocation Patterns

### The Problem
Scripts calling other scripts need to handle:
- Environment variable inheritance
- Exit code propagation
- Subprocess isolation

### Standard Pattern
```bash
# Use bash, not source, for subscripts
bash "$SCRIPT_DIR/subscript.sh" || {
    echo "Error: Subscript failed"
    exit 1
}
```

### Key Principles
- **Use `bash` not `source`** - creates isolated subprocess
- **Handle exit codes** - use `||` operator for error handling
- **Environment inheritance** - subprocess inherits parent environment
- **Safe failure modes** - scripts can use `set -euo pipefail` without affecting parent

---

## Path Resolution and Project Root Management

### The Problem
Scripts need to reference:
- Cross-directory resources (manifests, libraries, configs in different directories)
- Co-located resources (manifests next to the script)
- Sibling helper scripts (other scripts in same directory)

Using relative paths like `../../manifests/app.yaml` is fragile and breaks when scripts are moved or called from different directories.

### Standard Patterns

#### Pattern 1: Bootstrap and Use PROJECT_ROOT (Most Common)
```bash
# Bootstrap: Auto-discover project root (no manual counting needed!)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try common paths - project-root.sh auto-discovers if path is wrong
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Now use PROJECT_ROOT for all cross-directory references
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"
kubectl apply -f "$PROJECT_ROOT/manifests/common/namespace.yaml"
bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh"
```

**Why this works:**
- `$SCRIPT_DIR` gives absolute path to script's directory
- `project-root.sh` **automatically searches upward** to find project root
- Even if you source from the wrong path, it self-corrects via upward search
- After bootstrap, use the **two-rule pattern** below

#### Pattern 2: Local Module Resources (Self-Contained Apps)
```bash
# For scripts that manage co-located resources
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/project-root.sh"

# Use SCRIPT_DIR for manifests/configs that live alongside the script
kubectl apply -f "$SCRIPT_DIR/manifests/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/redis.yaml"

# Use PROJECT_ROOT for cross-directory references
source "$PROJECT_ROOT/scripts/lib/service-registry.sh"
```

**When to use:**
- App install scripts (`scripts/apps/llmapi/install-llmapi.sh`)
- External app integration (`external-apps/myapp/deploy.sh`)
- Self-contained modules with their own resource directories

**Benefits:**
- Keeps module resources bundled together
- Makes modules portable and self-contained
- Clear separation: `$SCRIPT_DIR` = local, `$PROJECT_ROOT` = global

#### Pattern 3: Sibling Helper Scripts (Library Functions)
```bash
# For library scripts that need other scripts in same directory
local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local helper_script="$script_dir/setup-vps-ssh-keys.sh"

if [ ! -f "$helper_script" ]; then
    echo "Error: Helper script not found: $helper_script"
    return 1
fi

# Copy or execute the helper
scp "$helper_script" remote:/tmp/
bash "$helper_script"
```

**When to use:**
- Library functions in `scripts/lib/` that reference sibling utilities
- Helper scripts that come in pairs/groups

### The Two-Rule Pattern (REQUIRED)

After bootstrapping `$PROJECT_ROOT`, **ALL path references** must follow these two rules:

#### Rule 1: Same Directory → Use $SCRIPT_DIR
For files co-located with the current script:
```bash
# ✅ CORRECT - file is next to this script
source "$SCRIPT_DIR/local-helper.sh"
kubectl apply -f "$SCRIPT_DIR/manifests/namespace.yaml"
```

#### Rule 2: Cross-Directory → Use $PROJECT_ROOT  
For files in different parts of the project tree:
```bash
# ✅ CORRECT - file is in different directory
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"
kubectl apply -f "$PROJECT_ROOT/manifests/common/config.yaml"
bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh"
```

#### What NOT to Do
```bash
# ❌ WRONG - multi-level relative paths (fragile, breaks on moves)
source "$SCRIPT_DIR/../../lib/helper.sh"
kubectl apply -f "$SCRIPT_DIR/../../../manifests/app.yaml"

# ❌ WRONG - hardcoded absolute paths (not portable)
source "/home/user/MyNodeOne/scripts/lib/helper.sh"
```

### Key Principles

1. **Bootstrap is forgiving**
   - `project-root.sh` auto-discovers via upward search
   - Manual path counting errors are automatically corrected
   - Just source from any common location

2. **Two-rule pattern eliminates counting**
   - Same directory → `$SCRIPT_DIR`
   - Cross-directory → `$PROJECT_ROOT`
   - No more `../..` path arithmetic needed

3. **Self-documenting paths**
   - `$SCRIPT_DIR` clearly indicates "local resource"
   - `$PROJECT_ROOT` clearly indicates "shared resource"

4. **Never hardcode absolute paths**
   - ❌ `"/home/user/MyNodeOne/scripts/lib/helper.sh"` (not portable)
   - ✅ `"$PROJECT_ROOT/scripts/lib/helper.sh"` (portable)

5. **Export PROJECT_ROOT for subshells**
   - Ensure child scripts inherit `$PROJECT_ROOT`
   - Prevents duplicate detection in every script

### Directory Structure Context

```
MyNodeOne/                          # PROJECT_ROOT
├── scripts/
│   ├── lib/
│   │   ├── project-root.sh         # Detects and exports PROJECT_ROOT
│   │   └── cluster-resources.sh    # Cross-directory reference: "$PROJECT_ROOT/scripts/lib/..."
│   ├── apps/
│   │   └── llmapi/
│   │       ├── install-llmapi.sh   # Uses: SCRIPT_DIR for manifests/, PROJECT_ROOT for lib/
│   │       └── manifests/          # Co-located resources
│   │           ├── namespace.yaml  # Referenced via: "$SCRIPT_DIR/manifests/namespace.yaml"
│   │           └── redis.yaml
│   ├── operations/
│   │   └── manage-apps.sh          # Uses: PROJECT_ROOT for everything
│   └── domains/
│       └── sync-dns.sh
├── manifests/
│   └── common/                     # Shared resources: "$PROJECT_ROOT/manifests/common/..."
└── external-apps/
    └── myapp/
        ├── deploy.sh               # Bootstrap from different tree location
        └── k8s/                    # Co-located: "$SCRIPT_DIR/k8s/..."
```

### Anti-Patterns to Avoid

#### ❌ Multi-Level Relative Paths
```bash
# WRONG - fragile, breaks when script moves
source "$SCRIPT_DIR/../../lib/helper.sh"
kubectl apply -f "$SCRIPT_DIR/../../../manifests/app.yaml"
```

#### ❌ Using SCRIPT_DIR for Cross-Directory References
```bash
# WRONG - couples script to specific directory structure
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/project-root.sh"  # Fragile!

# RIGHT - use PROJECT_ROOT after bootstrap
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/project-root.sh"  # Absolute from root
```

#### ❌ Skipping PROJECT_ROOT Detection
```bash
# WRONG - assumes script location
source ../../lib/helper.sh

# RIGHT - always detect project root first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/project-root.sh"
```

#### ❌ Hardcoded Absolute Paths
```bash
# WRONG - not portable across environments
MANIFESTS_DIR="/home/vinay/MyNodeOne/manifests"

# RIGHT - use PROJECT_ROOT
MANIFESTS_DIR="$PROJECT_ROOT/manifests"
```

### Complete Example: App Install Script

```bash
#!/bin/bash
set -euo pipefail

# Bootstrap: Detect project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/project-root.sh"

# Load cross-directory libraries using PROJECT_ROOT
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"
source "$PROJECT_ROOT/scripts/lib/service-registry.sh"

# Deploy co-located manifests using SCRIPT_DIR
echo "Deploying app resources..."
kubectl apply -f "$SCRIPT_DIR/manifests/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/redis.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/app.yaml"

# Call other scripts using PROJECT_ROOT
echo "Syncing DNS..."
bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh"

# Register service using cross-directory library
bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register "myapp" "myapp" "myapp" "myapp-svc" "80"

echo "✓ Installation complete"
```

### Why This Matters

**Maintainability:**
- Scripts can be moved without breaking paths
- Clear distinction between local and global resources
- Easy to understand file organization

**Portability:**
- Works regardless of where MyNodeOne is cloned
- No hardcoded paths or usernames
- Can be packaged and distributed

**Reliability:**
- Absolute paths prevent "file not found" errors
- Consistent path resolution across all scripts
- Works when called from any directory (`cd /tmp && bash ~/MyNodeOne/scripts/install.sh`)

---

## SSH Safety and Automation

### The Problem
Automated SSH operations can fail due to:
- Password prompts blocking execution
- Host key verification prompts
- Incorrect user context

### Standard Pattern
```bash
# For automated SSH operations
ssh -o BatchMode=yes -o StrictHostKeyChecking=no user@host "command"

# When running under sudo, preserve SSH context
sudo -u "$SUDO_USER" ssh user@host "command"
```

### Key Principles
- **Always use `BatchMode=yes`** - prevents password prompts
- **Use `StrictHostKeyChecking=no`** - for automated environments
- **Preserve user context** - use `sudo -u $SUDO_USER` when needed
- **Avoid nested SSH** - don't SSH from within SSH sessions

---

## Error Handling and Validation

### Standard Pattern
```bash
# Strict error handling
set -euo pipefail

# Validate prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found"
    exit 1
fi

# Provide fallbacks
if [[ -f "$LIB_DIR/helper.sh" ]]; then
    source "$LIB_DIR/helper.sh"
else
    echo "Warning: Helper library not found, using fallback"
fi
```

### Key Principles
- **Use `set -euo pipefail`** - strict error handling
- **Validate prerequisites** - check required commands and files
- **Provide fallbacks** - graceful degradation when dependencies missing
- **Clear error messages** - help users understand failures

---

## Common Anti-Patterns to Avoid

### ❌ Hardcoded User Information
```bash
# WRONG
HOME_DIR="/home/your-username"
USER_NAME="your-username"

# RIGHT
HOME_DIR="$ACTUAL_HOME"
USER_NAME="$ACTUAL_USER"
```

### ❌ Missing File Ownership
```bash
# WRONG
echo "secret" > ~/.credentials

# RIGHT
echo "secret" > ~/.credentials
if [ "$ACTUAL_USER" != "root" ] && [ "$(whoami)" = "root" ]; then
    chown "$ACTUAL_USER:$ACTUAL_USER" ~/.credentials
fi
```

### ❌ Nested Script Sourcing
```bash
# WRONG
source "$SCRIPT_DIR/subscript.sh"

# RIGHT
bash "$SCRIPT_DIR/subscript.sh"
```

### ❌ SSH Without BatchMode
```bash
# WRONG
ssh user@host "command"

# RIGHT
ssh -o BatchMode=yes -o StrictHostKeyChecking=no user@host "command"
```

---

## User and Group Management

### The Problem
When scripts create system users or groups for services (like MinIO), hardcoded UIDs/GIDs may not exist on the target system.

### Standard Pattern
```bash
# Validate or create service user/group
MINIO_USER="minio"
MINIO_GROUP="minio"
MINIO_UID=1000
MINIO_GID=1000

if ! getent group "$MINIO_GROUP" &>/dev/null; then
    echo "Creating $MINIO_GROUP group..."
    groupadd -g $MINIO_GID "$MINIO_GROUP" || echo "Warning: Group creation failed"
fi

if ! getent passwd "$MINIO_USER" &>/dev/null; then
    echo "Creating $MINIO_USER user..."
    useradd -u $MINIO_UID -g $MINIO_GID -s /bin/false -d /nonexistent "$MINIO_USER" || \
        echo "Warning: User creation failed"
fi
```

### Key Principles
- **Validate before using** - check if user/group exists before chown
- **Graceful fallbacks** - continue even if user creation fails
- **Use system accounts** - `/bin/false` shell, `/nonexistent` home for service accounts
- **Document assumptions** - clearly state required UIDs/GIDs

---

## Retry Logic and Network Operations

### Standard Pattern
```bash
retry_command() {
    local max_attempts=$1
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        echo "Attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 5
    done
    
    return 1
}
```

### Usage Examples
```bash
# Network downloads
retry_command 3 "curl -L -o velero.tar.gz https://github.com/velero/velero/releases/download/v1.13.2/velero-v1.13.2-linux-amd64.tar.gz"

# Helm operations
retry_command 3 "helm repo add longhorn https://charts.longhorn.io"

# External API calls
retry_command 5 "curl -f -s http://api.example.com/health"
```

### Key Principles
- **Configurable attempts** - allow different retry counts for different operations
- **Exponential backoff** - consider increasing sleep time for critical operations
- **Clear logging** - show attempt numbers and failure reasons
- **Graceful failure** - return non-zero exit code after all attempts exhausted

---

## Idempotency and Safe Re-runs

### Standard Pattern
```bash
# Check if already installed
if command -v velero &> /dev/null; then
    echo "Velero CLI already installed"
    return 0
fi

# Check if Kubernetes resource exists
if kubectl get namespace velero &>/dev/null; then
    echo "Velero namespace already exists"
else
    kubectl create namespace velero
fi

# Safe directory creation
mkdir -p "$CONFIG_DIR" 2>/dev/null || true
```

### Key Principles
- **Check before acting** - verify resource doesn't exist before creating
- **Use existing resources** - don't fail if resources already exist
- **Safe to re-run** - scripts should be idempotent
- **Clear status reporting** - tell user when skipping existing resources

---

## Verification and Validation

### Standard Pattern
```bash
# Verify installation
verify_installation() {
    # Check binary availability
    if ! command -v velero &> /dev/null; then
        echo "Error: Velero CLI not found after installation"
        return 1
    fi
    
    # Check Kubernetes resources
    if ! kubectl get namespace velero &>/dev/null; then
        echo "Error: Velero namespace not found"
        return 1
    fi
    
    # Check pod status
    if ! kubectl get pods -n velero --field-selector=status.phase=Running | grep -q velero; then
        echo "Warning: Velero pods not running yet"
    fi
    
    # Check service availability
    if ! kubectl get svc velero -n velero &>/dev/null; then
        echo "Warning: Velero service not found"
    fi
    
    return 0
}
```

### Key Principles
- **Multi-layer verification** - binary, resources, pods, services
- **Graceful degradation** - warnings for non-critical issues
- **Clear error messages** - specific information about what failed
- **Return status codes** - allow callers to handle verification failures

---

## Logging and User Feedback

### Standard Pattern
```bash
# Color-coded logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Progress indicators
log_info "Installing Velero CLI..."
if retry_command 3 "curl -L -o velero.tar.gz $URL"; then
    log_success "Velero CLI downloaded"
else
    log_error "Failed to download Velero CLI"
    exit 1
fi
```

### Key Principles
- **Consistent formatting** - use same log format throughout
- **Color coding** - visual distinction for message types
- **Progress indication** - show what's happening during long operations
- **Clear success/failure** - explicit feedback about operation results

---

## Testing Checklist

### User Detection Tests
- [ ] Script works when run as regular user
- [ ] Script works when run with `sudo`
- [ ] Config files placed in correct home directory
- [ ] Environment variables properly exported

### File Ownership Tests
- [ ] Created files owned by actual user, not root
- [ ] Credentials files have correct permissions (600)
- [ ] Directories have correct permissions (700)

### User/Group Management Tests
- [ ] Service users created with correct UIDs/GIDs
- [ ] Scripts handle missing users gracefully
- [ ] chown operations succeed after user creation

### Retry Logic Tests
- [ ] Network failures trigger retries
- [ ] Maximum retry limits respected
- [ ] Clear logging during retry attempts

### Idempotency Tests
- [ ] Scripts can be run multiple times safely
- [ ] Existing resources detected and skipped
- [ ] No duplicate resources created

### Verification Tests
- [ ] All installation steps verified
- [ ] Clear error messages for verification failures
- [ ] Appropriate warnings for non-critical issues

---

## Implementation Examples

### Complete Script Template
```bash
#!/bin/bash

# Defensive programming setup
set -euo pipefail

# Detect actual user context
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib/project-root.sh"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

if [[ -f "$LIB_DIR/detect-actual-home.sh" ]]; then
    source "$LIB_DIR/detect-actual-home.sh"
else
    ACTUAL_USER="${SUDO_USER:-$(whoami)}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_HOME="$HOME"
    fi
    CONFIG_DIR="$ACTUAL_HOME/.mynodeone"
fi

# Validate prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found"
    exit 1
fi

# Main logic with error handling
main() {
    local config_file="$CONFIG_DIR/app-config.txt"
    
    # Create config file
    echo "configuration" > "$config_file"
    
    # Fix ownership if running as root
    if [ "$ACTUAL_USER" != "root" ] && [ "$(whoami)" = "root" ]; then
        chown "$ACTUAL_USER:$ACTUAL_USER" "$config_file"
        chmod 600 "$config_file"
    fi
    
    echo "Configuration created at $config_file"
}

# Execute main function
main "$@"
```

---

**Last Updated:** January 16, 2026  
**Maintained by:** MyNodeOne Contributors