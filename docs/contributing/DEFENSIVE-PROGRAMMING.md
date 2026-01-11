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
HOME_DIR="/home/vinay"
USER_NAME="vinay"

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

### Script Invocation Tests
- [ ] Subscripts inherit environment correctly
- [ ] Exit codes properly propagated
- [ ] Parent script continues after subscript failure (if intended)

### SSH Tests (if applicable)
- [ ] No password prompts in automated execution
- [ ] Correct user context preserved
- [ ] Host key verification handled

---

## Implementation Examples

### Complete Script Template
```bash
#!/bin/bash

# Defensive programming setup
set -euo pipefail

# Detect actual user context
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

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

**Last Updated:** January 11, 2026  
**Maintained by:** MyNodeOne Contributors
