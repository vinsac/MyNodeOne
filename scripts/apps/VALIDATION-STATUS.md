# App Installation Scripts - Validation Status

This document tracks which installation scripts have comprehensive pre-flight validation.

---

## ✅ Validation Library

**Location:** `scripts/apps/lib/validation.sh`

**Functions Available:**
- `validate_prerequisites()` - Checks kubectl, cluster, storage
- `validate_and_sanitize_subdomain()` - Input validation
- `check_namespace_exists()` - Namespace detection
- `warn_if_namespace_exists()` - Overwrite protection

---

## 📊 Validation Coverage Status

### ✅ **COMPLETE VALIDATION** (5/12 scripts)

| Script | Validation Type | Checks |
|--------|----------------|---------|
| `install-immich.sh` | Inline | kubectl ✅ cluster ✅ storage ✅ subdomain ✅ |
| `install-jellyfin.sh` | Inline | kubectl ✅ cluster ✅ storage ✅ subdomain ✅ |
| `install-vaultwarden.sh` | Shared Library | kubectl ✅ cluster ✅ storage ✅ namespace ✅ |
| `install-nextcloud.sh` | Shared Library | kubectl ✅ cluster ✅ storage ✅ namespace ✅ |
| `install-minecraft.sh` | Shared Library | kubectl ✅ cluster ✅ storage ✅ namespace ✅ |

### ⏳ **NEEDS VALIDATION** (7/12 scripts)

| Script | Current Status | Priority |
|--------|---------------|----------|
| `install-audiobookshelf.sh` | Basic kubectl check only | Medium |
| `install-gitea.sh` | Basic kubectl check only | Medium |
| `install-homepage.sh` | Basic kubectl check only | Low |
| `install-mattermost.sh` | Basic kubectl check only | Medium |
| `install-paperless.sh` | Basic kubectl check only | Medium |
| `install-plex.sh` | Basic kubectl check only | Medium |
| `install-uptime-kuma.sh` | Basic kubectl check only | Low |

---

## 🔧 How to Add Validation to Remaining Scripts

### **Pattern to Apply:**

```bash
#!/bin/bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared validation library
source "$SCRIPT_DIR/lib/validation.sh"

# ... (colors, header, etc.)

# Validate prerequisites
validate_prerequisites

NAMESPACE="app-name"
warn_if_namespace_exists "$NAMESPACE"

# ... (rest of installation)
```

### **Steps:**

1. Add script directory detection
2. Source the validation library
3. Call `validate_prerequisites()`
4. Call `warn_if_namespace_exists()` before namespace creation

### **Estimated Time:**
- ~2 minutes per script
- ~14 minutes total for remaining 7 scripts

---

## 🎯 Validation Checks Performed

### **1. kubectl Available**
```
Error: kubectl not found. Please install Kubernetes first.
Run: sudo ./scripts/bootstrap-control-plane.sh
```

### **2. Cluster Accessible**
```
Error: Cannot connect to Kubernetes cluster.
Please ensure:
  • K3s is running: systemctl status k3s
  • KUBECONFIG is set: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### **3. Storage Available**
```
Warning: Longhorn storage class not found.
Installation may fail without persistent storage.
Continue anyway? [y/N]:
```

### **4. Namespace Exists**
```
Warning: Namespace 'app-name' already exists.
This installation may overwrite existing resources.
Continue anyway? [y/N]:
```

---

## 💡 Migration Plan for Immich & Jellyfin

**Current:** These scripts have validation inline (duplicated code)

**Future:** Can migrate to use shared library for consistency

**Benefits:**
- Reduced code duplication
- Easier to maintain
- Consistent error messages
- Automatic updates when library improves

**Priority:** Low (current inline validation works fine)

---

## 📈 Progress Tracking

- **Total Scripts:** 12
- **With Validation:** 5 (42%)
- **Remaining:** 7 (58%)

**Goal:** 100% coverage with standardized validation

---

## 🔄 Update This Document

When adding validation to a script, move it from "Needs Validation" to "Complete Validation" section.

**Last Updated:** Nov 1, 2025
