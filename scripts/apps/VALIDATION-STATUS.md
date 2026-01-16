# App Installation Scripts - Validation Status

This document tracks which installation scripts have comprehensive pre-flight validation.

---

## Validation Library

**Location:** `scripts/apps/lib/validation.sh`

**Functions Available:**
- `validate_prerequisites()` - Checks kubectl, cluster, storage
- `validate_and_sanitize_subdomain()` - Input validation
- `check_namespace_exists()` - Namespace detection
- `warn_if_namespace_exists()` - Overwrite protection

---

## 📊 Validation Coverage Status

### **COMPLETE VALIDATION** (6/6 scripts - 100%!)

#### **Fully Implemented Scripts (6)**
| Script | Validation Type | Checks |
|--------|----------------|---------|
| `immich/install-immich.sh` | Inline | kubectl cluster storage subdomain |
| `jellyfin/install-jellyfin.sh` | Shared Library | kubectl cluster storage subdomain |
| `nextcloud/install-nextcloud.sh` | Shared Library | kubectl cluster storage namespace |
| `paperless/install-paperless.sh` | Shared Library | kubectl cluster storage subdomain |
| `homepage/install-homepage.sh` | Shared Library | kubectl cluster storage namespace |
| `mattermost/install-mattermost.sh` | Shared Library | kubectl cluster storage subdomain |

---

##  How to Add Validation to Remaining Scripts

### **Pattern to Apply:**

```bash
#!/bin/bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared validation library
source "$PROJECT_ROOT/scripts/apps/validation.sh"

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
- All scripts now have validation!

---

## 🎯 Validation Checks Performed

### **1. kubectl Available**
```
Error: kubectl not found. Please install Kubernetes first.
Run: sudo ./scripts/installation/bootstrap-control-plane.sh
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

##  Migration Plan for Immich & Jellyfin

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

- **Total Scripts:** 6
- **With Validation:** 6 (100%) 
- **Fully Implemented:** 6 (100%)
- **Placeholder (Ready):** 0 (0%)

**Goal:** 100% coverage with standardized validation **ACHIEVED!**

---

## Update This Document

When adding validation to a script, move it from "Needs Validation" to "Complete Validation" section.
