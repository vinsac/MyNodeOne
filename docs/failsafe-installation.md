# Failsafe Installation Methods

## Overview

MyNodeOne uses a **multi-method failsafe approach** to install critical tools. If one method fails, it automatically tries the next method.

This ensures installations succeed even when:
- ❌ Snap is removed or unavailable
- ❌ Network issues prevent downloading scripts
- ❌ Official repositories are unreachable
- ❌ Architecture-specific issues occur

---

## Why Failsafe Installation?

### The Problem

**User reported:** *"During installation, snap was removed, which broke Firefox and Helm. Helm is only available via snap on Ubuntu."*

### The Solution

**Multi-method installation** with automatic fallback:

```
Try Method 1 (Snap)
  ↓ Failed?
Try Method 2 (Official Script)
  ↓ Failed?
Try Method 3 (Direct Binary)
  ↓ Failed?
Report error with manual instructions
```

---

## Installation Methods Explained

### Method 1: Snap (If Available)

**Pros:**
- ✅ Easiest method
- ✅ Automatic updates
- ✅ Sandboxed

**Cons:**
- ❌ Requires snap to be installed
- ❌ Uses extra RAM
- ❌ Slower startup

**Example:**
```bash
snap install helm --classic
```

---

### Method 2: Official Installation Script (RECOMMENDED)

**Pros:**
- ✅ Always up-to-date
- ✅ Maintained by project authors
- ✅ Handles architecture detection
- ✅ Works without snap

**Cons:**
- ⚠️ Requires internet access
- ⚠️ Depends on external script availability

**Example:**
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**What it does:**
1. Detects your OS and architecture
2. Downloads correct binary
3. Installs to system path
4. Sets correct permissions

---

### Method 3: Direct Binary Download (Ultimate Fallback)

**Pros:**
- ✅ Most reliable (direct from source)
- ✅ No dependencies on scripts
- ✅ Works when other methods fail
- ✅ Version-specific

**Cons:**
- ⚠️ Requires manual architecture detection
- ⚠️ Fixed version (not always latest)

**Example:**
```bash
HELM_VERSION="v3.13.3"
ARCH="amd64"  # or arm64, arm
HELM_URL="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"

curl -fsSL "$HELM_URL" -o /tmp/helm.tar.gz
tar -zxf /tmp/helm.tar.gz -C /tmp
mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm
chmod +x /usr/local/bin/helm
```

---

## Helm Installation Flow

### Complete Process

```bash
install_helm() {
    # Check if already installed
    if command -v helm &> /dev/null; then
        echo "Helm already installed, skipping..."
        return 0
    fi
    
    success=false
    
    # Method 1: Snap (if available)
    if command -v snap &> /dev/null; then
        if snap install helm --classic 2>/dev/null; then
            echo "✓ Helm installed via snap"
            success=true
        fi
    fi
    
    # Method 2: Official script
    if [ "$success" = false ]; then
        if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
            echo "✓ Helm installed via official script"
            success=true
        fi
    fi
    
    # Method 3: Direct binary
    if [ "$success" = false ]; then
        HELM_VERSION="v3.13.3"
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l) ARCH="arm" ;;
        esac
        
        HELM_URL="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
        
        if curl -fsSL "$HELM_URL" -o /tmp/helm.tar.gz; then
            tar -zxf /tmp/helm.tar.gz -C /tmp
            mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm
            chmod +x /usr/local/bin/helm
            echo "✓ Helm installed via direct binary"
            success=true
        fi
    fi
    
    # Verify
    if command -v helm &> /dev/null; then
        echo "✓ Helm installation verified"
        return 0
    else
        echo "✗ All installation methods failed"
        return 1
    fi
}
```

---

## Other Tools Using Failsafe Installation

### kubectl

**Installed by:** K3s (automatic)

**Failsafe methods:**
1. K3s installation (includes kubectl)
2. Official kubectl script
3. Direct binary download

### K3s

**Methods:**
1. Official K3s script: `curl -sfL https://get.k3s.io | sh`
2. Direct binary from GitHub releases

### Tailscale

**Methods:**
1. Official script: `curl -fsSL https://tailscale.com/install.sh | sh`
2. APT repository (if script adds it)
3. Direct binary download

---

## Architecture Support

The failsafe installation automatically detects and handles:

| Architecture | Detection | Binary Name |
|--------------|-----------|-------------|
| x86_64 | `uname -m` | `amd64` |
| aarch64 | `uname -m` | `arm64` |
| armv7l | `uname -m` | `arm` |

**Example:**
```bash
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
esac
```

---

## Benefits of This Approach

### 1. Resilience

**Scenario:** Snap is removed during system cleanup
- ❌ Method 1 (snap) fails
- ✅ Method 2 (curl script) succeeds
- **Result:** Installation continues without user intervention

### 2. Network Issues

**Scenario:** GitHub script is temporarily unavailable
- ❌ Method 1 (snap) not available
- ❌ Method 2 (curl script) fails (network error)
- ✅ Method 3 (direct binary from get.helm.sh) succeeds
- **Result:** Installation uses alternative download source

### 3. Version Control

**Scenario:** Need specific version
- Method 3 allows specifying exact version
- Ensures consistency across installations

### 4. No Manual Intervention

**Traditional approach:**
```
Installation failed! Please run:
  curl https://... | bash

User: *Has to manually run command*
User: *Has to restart installation*
```

**Failsafe approach:**
```
Method 1 failed, trying Method 2...
Method 2 succeeded!
Installation continues...

User: *Nothing to do, it just works*
```

---

## Verification

Every installation includes verification:

```bash
# After installation attempts
if command -v helm &> /dev/null; then
    INSTALLED_VERSION=$(helm version --short)
    echo "✓ Helm successfully installed: $INSTALLED_VERSION"
    return 0
else
    echo "✗ Helm installation verification failed"
    return 1
fi
```

**This ensures:**
- Tool is actually in PATH
- Binary is executable
- Tool can run successfully

---

## Error Handling

If ALL methods fail:

```
CRITICAL: All Helm installation methods failed!
Attempted methods:
  1. Snap (if available)
  2. Official get-helm-3 script
  3. Direct binary download

Please install Helm manually:
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**User gets:**
- ✅ Clear error message
- ✅ List of attempted methods
- ✅ Manual installation command
- ✅ Can troubleshoot or install manually

---

## Future Tools

This pattern can be extended to any tool:

### Example: kubectl (if not from K3s)

```bash
install_kubectl_failsafe() {
    # Method 1: Snap
    snap install kubectl --classic
    
    # Method 2: Official script
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    
    # Method 3: Direct from GitHub releases
    VERSION="v1.28.0"
    curl -LO "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubectl"
}
```

### Example: Docker

```bash
install_docker_failsafe() {
    # Method 1: Snap
    snap install docker
    
    # Method 2: Official script
    curl -fsSL https://get.docker.com | sh
    
    # Method 3: APT repository
    apt-get install docker.io
}
```

---

## Testing Failsafe Methods

### Test Scenario 1: Snap Removed

```bash
# Remove snap
apt-get purge snapd
rm -rf /snap /var/snap

# Run installation
./scripts/bootstrap-control-plane.sh

# Expected:
# Method 1 skipped (snap not available)
# Method 2 succeeds (curl script)
# ✓ Helm installed successfully
```

### Test Scenario 2: Network Issues

```bash
# Block GitHub access
iptables -A OUTPUT -d github.com -j DROP
iptables -A OUTPUT -d raw.githubusercontent.com -j DROP

# Run installation
./scripts/bootstrap-control-plane.sh

# Expected:
# Method 1: May fail (snap packages also need network)
# Method 2: Fails (can't reach GitHub)
# Method 3: Succeeds (direct from get.helm.sh)
# ✓ Helm installed successfully
```

### Test Scenario 3: All Methods Work

```bash
# Normal system with snap
./scripts/bootstrap-control-plane.sh

# Expected:
# Method 1: Succeeds immediately (snap)
# Methods 2-3: Skipped (already installed)
# ✓ Helm installed successfully
```

---

## Logging Example

**Successful installation:**
```
[INFO] Installing Helm with failsafe methods...
[INFO] Method 1: Trying snap installation...
[SUCCESS] Helm installed via snap
[SUCCESS] Helm successfully installed: v3.13.3
```

**Failover to Method 2:**
```
[INFO] Installing Helm with failsafe methods...
[INFO] Method 1: Trying snap installation...
[WARN] Snap installation failed, trying next method...
[INFO] Method 2: Trying official Helm installation script...
[SUCCESS] Helm installed via official script
[SUCCESS] Helm successfully installed: v3.13.3
```

**Failover to Method 3:**
```
[INFO] Installing Helm with failsafe methods...
[INFO] Method 1: Trying snap installation...
[WARN] Snap not available, skipping to next method...
[INFO] Method 2: Trying official Helm installation script...
[WARN] Official script failed, trying next method...
[INFO] Method 3: Trying direct binary download...
[SUCCESS] Helm installed via direct binary download
[SUCCESS] Helm successfully installed: v3.13.3
```

**All methods failed:**
```
[INFO] Installing Helm with failsafe methods...
[INFO] Method 1: Trying snap installation...
[WARN] Snap installation failed, trying next method...
[INFO] Method 2: Trying official Helm installation script...
[WARN] Official script failed, trying next method...
[INFO] Method 3: Trying direct binary download...
[ERROR] Direct binary download failed
[ERROR] CRITICAL: All Helm installation methods failed!
[ERROR] Please install Helm manually:
[ERROR]   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Summary

**Failsafe installation ensures:**
- ✅ **Resilience:** Works even if snap is removed
- ✅ **Reliability:** Multiple methods increase success rate
- ✅ **Automatic:** No user intervention needed
- ✅ **Transparent:** Clear logging shows what's happening
- ✅ **Verifiable:** Always confirms successful installation
- ✅ **Helpful:** Provides manual instructions if all methods fail

**Result:** Users get a robust installation experience that "just works" in most scenarios!
