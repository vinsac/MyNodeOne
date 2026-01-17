# Universal Bootstrap Pattern

## Problem
Manual directory counting (`../../..`) in bootstrap is error-prone:
- Easy to get wrong when creating new scripts
- Breaks when scripts are moved
- Requires knowing exact directory depth

## Solution: Two Simple Rules

### Rule 1: Same Directory → Use SCRIPT_DIR
```bash
# Files co-located with the script
source "$SCRIPT_DIR/helper.sh"
kubectl apply -f "$SCRIPT_DIR/manifests/app.yaml"
```

### Rule 2: Cross-Directory → Use PROJECT_ROOT
```bash
# Files in different parts of the tree
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"
kubectl apply -f "$PROJECT_ROOT/manifests/common/config.yaml"
```

## Universal Bootstrap (No Counting!)

Every script starts with this **exact same pattern**:

```bash
#!/bin/bash
set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap: Auto-discover PROJECT_ROOT (no manual counting!)
source "$SCRIPT_DIR/../../scripts/lib/bootstrap.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/bootstrap.sh" 2>/dev/null || \
source "$SCRIPT_DIR/scripts/lib/bootstrap.sh" 2>/dev/null || {
    # Fallback: search upward for bootstrap.sh
    _dir="$SCRIPT_DIR"
    while [ "$_dir" != "/" ]; do
        if [ -f "$_dir/scripts/lib/bootstrap.sh" ]; then
            source "$_dir/scripts/lib/bootstrap.sh"
            break
        fi
        _dir="$(dirname "$_dir")"
    done
}

# Verify PROJECT_ROOT is set
if [ -z "${PROJECT_ROOT:-}" ]; then
    echo "ERROR: Failed to bootstrap project root" >&2
    exit 1
fi

# Now use the two-rule pattern:
# 1. Same directory
source "$SCRIPT_DIR/local-config.sh"  # If exists

# 2. Cross-directory
source "$PROJECT_ROOT/scripts/lib/helper.sh"
```

## Even Simpler: One-Line Bootstrap

For most scripts in the `scripts/` tree:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib/bootstrap.sh" 2>/dev/null || source "$(cd "$SCRIPT_DIR" && while [ ! -f scripts/lib/bootstrap.sh ] && [ "$PWD" != / ]; do cd ..; done && pwd)/scripts/lib/bootstrap.sh"

# Now PROJECT_ROOT is available, use the two rules
```

## Recommended: Standard Template

Copy this template for new scripts:

```bash
#!/bin/bash
set -euo pipefail

# Bootstrap pattern (works from any depth)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_find_bootstrap() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/scripts/lib/bootstrap.sh" ] && echo "$dir/scripts/lib/bootstrap.sh" && return 0
        dir="$(dirname "$dir")"
    done
    return 1
}
source "$(_find_bootstrap "$SCRIPT_DIR")" || { echo "ERROR: Cannot find bootstrap.sh" >&2; exit 1; }

# Colors (optional)
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }

# Main logic using two-rule pattern:

# Same directory resources
# (none in this example)

# Cross-directory resources
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"

# Your code here
log_info "Running from: $SCRIPT_DIR"
log_info "Project root: $PROJECT_ROOT"
```

## Benefits

✅ **No directory counting** - works from any depth
✅ **Self-documenting** - clear what's local vs global
✅ **Move-safe** - scripts can be relocated without breaking
✅ **Consistent** - same pattern everywhere

## Migration Path

### Old Pattern (Error-Prone)
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"  # ← Manual counting!
source "$PROJECT_ROOT/scripts/lib/project-root.sh"
```

### New Pattern (Robust)
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR" && while [ ! -f scripts/lib/bootstrap.sh ] && [ "$PWD" != / ]; do cd ..; done && pwd)/scripts/lib/bootstrap.sh"
# PROJECT_ROOT now available automatically
```

Or use the helper function version from the template above.
