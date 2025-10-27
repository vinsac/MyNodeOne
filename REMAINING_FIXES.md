# Remaining Fixes for Non-Technical User Readiness

**Status:** 2/6 critical documentation files fixed  
**Next:** Complete remaining files before fresh install test

---

## ✅ COMPLETED (Just Now)

1. ✅ **docs/operations.md** - All toronto/vivobook references replaced
2. ✅ **docs/scaling.md** - Generic node names, updated examples  
3. ✅ **AUDIT_REPORT.md** - Created comprehensive audit

---

## 🔧 IN PROGRESS (Need to Complete)

### High Priority Files:

**1. docs/architecture.md** - Multiple toronto references
```bash
# Search results show:
- toronto-0001 (control plane references)
- toronto-000x (worker references)
- Toronto nodes (examples)
- Specific RAM/CPU specs (256GB, Ryzen 9950X)

# Need to replace with:
- control-plane or node-001
- worker-001, worker-002
- Generic examples
- Reasonable specs (16GB, 4 cores)
```

**2. docs/troubleshooting.md** - toronto-0002, toronto references
```bash
# Occurrences:
- Line 67: "Or add toronto-0002 node"
- Line 520: "ping <toronto-tailscale-ip>"
- Line 609: "ssh <toronto-0001-tailscale-ip>"

# Replace with:
- "Or add node-002"
- "ping <control-plane-tailscale-ip>"
- "ssh <control-plane-ip>"
```

**3. docs/setup-options-guide.md** - toronto examples
```bash
# Lines:
- 29: "like toronto-0001"
- 57: "toronto-0002"
- 114: "vinay-vivobook"

# Replace:
- "example: control-plane with 16GB RAM"
- "worker-001"
- "your-laptop"
```

**4. docs/networking.md** - toronto-001, toronto-002
```bash
# Lines:
- 362: toronto-001
- 372: toronto-002

# In network diagrams - replace with:
- node-001
- node-002
```

**5. GLOSSARY.md** - toronto examples
```bash
# Lines:
- 42: toronto-0001
- 51: toronto-0002, toronto-0003

# Replace with:
- control-plane
- worker-001, worker-002
```

**6. FAQ.md** - References to toronto
```bash
# Line 442: "Node names like `toronto-0001`, `node-001`, etc. are just examples"

# Good! Just verify this is clear enough
```

---

## 📋 ADDITIONAL CRITICAL FIXES

### A. INSTALLATION.md - Outdated Credential Flow

**Location:** Lines 301-306

**Current:**
```markdown
> 💡 **Password Management:** After installation completes:
> 1. Copy all credentials from `/root/mynodeone-*.txt` to a password manager
> 2. **DO NOT** self-host password manager on MyNodeOne
> 3. Delete credential files: `sudo rm /root/mynodeone-*.txt`
> 
> See `docs/password-management.md` for detailed guide.
```

**Should be:**
```markdown
> 💡 **Password Management:** The installation wizard will:
> 1. Display all credentials in the terminal
> 2. Prompt you to save them to a password manager
> 3. **Automatically delete credential files** after you confirm
> 4. Keep only the join token (needed for adding worker nodes)
> 
> **Recommended password managers:** Bitwarden (free), 1Password, KeePassXC
> 
> See `SECURITY_CREDENTIALS_GUIDE.md` for detailed security guide.
```

**Also Update:** Lines 270-276 (Step 3 header)
```markdown
## 🔒 Step 3: Security (Prompted During Installation)

> **Note:** The installation now prompts you to enable security hardening automatically.
> You can also run it manually after installation if you skipped it.
```

---

### B. docs/password-management.md - May Have Outdated Info

**Action Required:**
1. Review entire file
2. Update to match automatic deletion flow
3. Remove references to manual `rm` commands
4. Point to SECURITY_CREDENTIALS_GUIDE.md as primary doc

---

### C. POST_INSTALLATION_GUIDE.md - Quick Review

**Check for:**
- Any toronto/vivobook references (unlikely but verify)
- Outdated credential file references
- Old script names

---

## 🎯 SCRIPT FIX TEMPLATE

For quick bulk replacement, here's the pattern:

```bash
# In each file, replace:
toronto-0001     → control-plane (or node-001 for examples)
toronto-0002     → worker-001 (or node-002)
toronto-0003     → worker-002 (or node-003)
toronto-000x     → node-00x
vivobook         → your laptop
vinay-vivobook   → your-laptop

# Specific hardware examples:
256GB RAM, Ryzen 9950X  → 16GB+ RAM, 4+ cores (realistic)
4TB NVMe + 36TB HDD     → 100GB+ storage (realistic)
```

---

## 🔍 VERIFICATION CHECKLIST

After all fixes, verify:

- [ ] `grep -r "toronto" docs/ *.md` returns only FAQ explanation
- [ ] `grep -r "vivobook" docs/ *.md` returns nothing
- [ ] All examples use generic names
- [ ] All hardware specs are reasonable for target users
- [ ] No personal/specific machine references
- [ ] INSTALLATION.md matches current script flow
- [ ] All scripts referenced in docs exist
- [ ] All docs referenced in scripts exist

---

## 🧪 TEST SEQUENCE

After fixes complete:

### 1. Documentation Test
```bash
# From fresh clone:
cd MyNodeOne
cat GETTING-STARTED.md    # Start here
cat INSTALLATION.md        # Follow steps
cat POST_INSTALLATION_GUIDE.md  # After install
```

### 2. Script Test (Dry Run)
```bash
# Don't actually run, just check syntax:
bash -n scripts/bootstrap-control-plane.sh
bash -n scripts/setup-laptop.sh
bash -n scripts/deploy-llm-chat.sh
bash -n scripts/setup-local-dns.sh
```

### 3. Fresh Install Test
```bash
# On clean Ubuntu 24.04 machine:
sudo ./scripts/mynodeone

# Follow ALL prompts
# Note any confusion
# Test each optional feature:
# - Security hardening
# - Local DNS
# - Demo app
# - LLM chat
```

### 4. Laptop Setup Test
```bash
# On your actual laptop:
sudo bash scripts/setup-laptop.sh

# Test each feature:
# - kubectl access
# - Local DNS (optional)
# - k9s/helm install (optional)
```

---

## 📊 ESTIMATED TIME

- **Remaining doc fixes:** 30-45 minutes
- **Testing/verification:** 15-20 minutes
- **Fresh install test:** 30-45 minutes
- **Total:** ~2 hours

---

## 🎓 USER EXPERIENCE GOALS

After all fixes, a complete beginner should be able to:

1. ✅ Read README and understand what MyNodeOne is
2. ✅ Follow GETTING-STARTED without confusion
3. ✅ Run installation and answer prompts successfully
4. ✅ Save credentials when prompted
5. ✅ Access services from laptop
6. ✅ Deploy demo app or LLM chat
7. ✅ Feel confident they did it right

**Failure points to eliminate:**
- ❌ "What's toronto-0001?" (use generic names)
- ❌ "Do I need to delete files?" (auto-deleted now)
- ❌ "How do I access from laptop?" (setup-laptop.sh)
- ❌ "What's my cluster's IP?" (show-credentials.sh)
- ❌ "Did it work?" (clear success messages)

---

## 📝 NEXT ACTIONS

1. **Complete remaining doc fixes** (use multi_edit for efficiency)
2. **Update INSTALLATION.md credential flow**
3. **Review password-management.md**
4. **Run verification checklist**
5. **Commit all changes**
6. **Ready for fresh install test!**

---

**Current Status:** Good progress! 2 major docs fixed, audit complete, remaining work identified.
