# MyNodeOne Repository Structure

**Clean, organized documentation and code structure**

---

## 📂 Root Directory

```
/
├── README.md                   # Main entry point - start here!
├── LICENSE                     # MIT License
├── VERSION                     # Current version number
├── CHANGELOG.md                # Version history and release notes
├── CONTRIBUTING.md             # How to contribute
├── AUTHORS                     # Project contributors
├── .gitignore                  # Git ignore patterns
└── FOLDER-STRUCTURE.md        # This file
```

**Keep in root:** Only essential project files that users expect to find immediately.

---

## 📚 Documentation (`docs/`)

### User Guides (`docs/guides/`)

**Step-by-step guides for all skill levels:**

```
docs/guides/
├── BEGINNER-GUIDE.md          # Complete beginner tutorial (50+ pages)
├── GETTING-STARTED.md         # Guided introduction for new users
├── INSTALLATION.md            # Full installation documentation
├── MOBILE-ACCESS-GUIDE.md     # Phone/tablet setup guide
└── MY_CLUSTER_ACCESS.md       # Accessing your cluster
```

**Who uses these:**
- New users → Start with GETTING-STARTED.md
- Non-technical → BEGINNER-GUIDE.md
- Mobile users → MOBILE-ACCESS-GUIDE.md
- Technical users → INSTALLATION.md

---

### Reference Documentation (`docs/reference/`)

**Quick reference and detailed technical docs:**

```
docs/reference/
├── ACCESS-CHEAT-SHEET.md      # All app URLs (printable)
├── APP-STORE.md               # Application catalog
├── SUBDOMAIN-ACCESS.md        # DNS and subdomain guide
├── PORT-SIMPLIFICATION.md     # Why port 80 for all apps
├── DOCUMENTATION-INDEX.md     # Complete doc index
└── FAQ.md                     # Frequently asked questions
```

**Who uses these:**
- Need quick info → ACCESS-CHEAT-SHEET.md
- Choosing apps → APP-STORE.md
- Troubleshooting DNS → SUBDOMAIN-ACCESS.md
- Common questions → FAQ.md

---

### Use Cases (`docs/use-cases/`)

**Real-world deployment scenarios with ROI analysis:**

```
docs/use-cases/
├── README.md                  # Use cases overview (8 scenarios)
├── enterprise-saas.md         # Enterprise SaaS ($100K+/year savings)
└── devtest-qa.md              # Dev/Test/QA ($75K+/year savings)
```

**Coming soon:**
- education.md - Teaching & learning platforms
- personal-cloud.md - Home use (consolidated from BEGINNER-GUIDE)
- small-saas.md - Startup hosting
- api-products.md - API infrastructure
- data-analytics.md - Data processing clusters
- internal-tools.md - Company tool consolidation

**Who uses these:**
- Enterprises → enterprise-saas.md
- Dev teams → devtest-qa.md
- Decision makers → All (for ROI analysis)
- Students/educators → education.md (coming)

---

### Development Documentation (`docs/development/`)

**For contributors and developers:**

```
docs/development/
├── architecture.md            # System architecture
├── networking.md              # Network configuration
├── troubleshooting.md         # Troubleshooting guide
└── (other technical docs)
```

---

## 🎉 Release Notes (`releases/`)

**Version release documentation:**

```
releases/
├── v2.0.0.md                  # Version 2.0 release notes
└── DASHBOARD-AND-APPS-SUMMARY.md  # Dashboard implementation summary
```

**Each release includes:**
- New features
- Breaking changes
- Migration guides
- Known issues

---

## 🚀 Scripts (`scripts/`)

**Installation and management scripts:**

```
scripts/
├── bootstrap-control-plane.sh  # Main installation script
├── bootstrap-worker.sh         # Worker node setup
├── setup-laptop.sh             # Management laptop setup
├── app-store.sh                # Interactive app installer
├── configure-app-dns.sh        # DNS configuration
├── apps/                       # Individual app installers
│   ├── install-jellyfin.sh
│   ├── install-immich.sh
│   └── ...
└── (other management scripts)
```

---

## 📦 Kubernetes Manifests (`manifests/`)

**Kubernetes YAML configurations:**

```
manifests/
├── metallb/                    # LoadBalancer configuration
├── longhorn/                   # Storage configuration
├── argocd/                     # GitOps configuration
└── (other manifests)
```

---

## ⚙️ Configuration (`config/`)

**Configuration templates and examples:**

```
config/
├── example-configs/
└── templates/
```

---

## 🌐 Website (`website/`)

**Dashboard and web assets:**

```
website/
├── dashboard.html              # Main dashboard
├── deploy-dashboard.sh         # Dashboard deployment script
└── (other web assets)
```

**Access:** `http://mynodeone.local` after installation

---

## 📋 Finding What You Need

### I want to...

**Get started quickly:**
→ `docs/guides/DEMO_APP_GUIDE.md` (10 minutes)

**Learn from scratch:**
→ `docs/guides/BEGINNER-GUIDE.md` (complete tutorial)

**Understand use cases:**
→ `docs/use-cases/README.md` (8 scenarios with ROI)

**Install apps:**
→ `docs/reference/APP-STORE.md` or `sudo ./scripts/app-store.sh`

**Troubleshoot:**
→ `docs/reference/FAQ.md` or `docs/development/troubleshooting.md`

**Access my apps:**
→ `docs/reference/ACCESS-CHEAT-SHEET.md` (print this!)

**Set up mobile:**
→ `docs/guides/MOBILE-ACCESS-GUIDE.md`

**Understand architecture:**
→ `docs/development/architecture.md`

**See what's new:**
→ `CHANGELOG.md` or `releases/v2.0.0.md`

**Contribute:**
→ `CONTRIBUTING.md`

---

## 🔄 Navigation Patterns

### New Users (First Time)

1. `README.md` → Overview and quick links
2. `docs/guides/GETTING-STARTED.md` → Introduction
3. `docs/guides/DEMO_APP_GUIDE.md` → Get hands-on
4. `docs/guides/BEGINNER-GUIDE.md` → Deep dive

### Returning Users

1. `docs/reference/ACCESS-CHEAT-SHEET.md` → Quick reference
2. `docs/reference/APP-STORE.md` → Find new apps
3. `docs/reference/FAQ.md` → Solve issues

### Decision Makers

1. `README.md` → Project overview
2. `docs/use-cases/README.md` → ROI analysis
3. Specific use case → Detailed implementation
4. `CHANGELOG.md` → Version history

### Contributors

1. `CONTRIBUTING.md` → How to contribute
2. `docs/development/architecture.md` → Technical details
3. Source code → Implementation

---

## 🎯 Design Principles

### Root Directory
**Rule:** Keep it minimal - only essential project files
**Why:** Clean first impression, easy navigation

### Documentation
**Rule:** Organized by audience and purpose
**Why:** Users find what they need quickly

### Guides
**Rule:** Task-oriented, step-by-step
**Why:** Action-oriented, immediate value

### Reference
**Rule:** Comprehensive, searchable
**Why:** Quick lookups, detailed info

### Use Cases
**Rule:** Problem → Solution → ROI
**Why:** Business justification, implementation ready

---

## 📊 Benefits of This Structure

### For Users
✅ Easy to find documentation  
✅ Clear navigation paths  
✅ Appropriate depth for skill level  
✅ No clutter in root directory  

### For Contributors
✅ Clear organization  
✅ Easy to add new docs  
✅ Consistent patterns  
✅ Logical groupings  

### For Maintainers
✅ Scalable structure  
✅ Easy to update  
✅ Version control friendly  
✅ Professional appearance  

---

## 🔗 Link Patterns

### Internal Links

**From root (README.md, CHANGELOG.md):**
```markdown
[Guide](docs/guides/GUIDE.md)
[Reference](docs/reference/REF.md)
[Use Case](docs/use-cases/CASE.md)
```

**From docs/guides/:**
```markdown
[Other Guide](GUIDE.md)                    # Same folder
[Reference](../reference/REF.md)           # Up and over
[Use Case](../use-cases/CASE.md)           # Up and over
[Root](../../README.md)                    # Up twice
```

**From docs/use-cases/:**
```markdown
[Overview](README.md)                      # Same folder (index)
[Other Case](other-case.md)                # Same folder
[Guide](../guides/GUIDE.md)                # Up and over
```

### Absolute vs Relative

**Use relative links:**
- Works in local clones
- Works on GitHub
- Works in different branches
- No broken links on forks

---

## 🚀 Future Growth

### Easy to Add

**New guide:**
→ Add to `docs/guides/`
→ Update README.md links

**New reference doc:**
→ Add to `docs/reference/`
→ Update DOCUMENTATION-INDEX.md

**New use case:**
→ Add to `docs/use-cases/`
→ Update use-cases/README.md
→ Update main README.md

**New release:**
→ Add to `releases/vX.Y.Z.md`
→ Update CHANGELOG.md

### Scalable Structure

**Can accommodate:**
- 100+ guides
- 50+ use cases
- Multilingual docs (docs/guides/en/, docs/guides/es/)
- Video tutorials (docs/videos/)
- Examples (examples/)
- Templates (templates/)

---

## ✅ Summary

**Clean root directory** → Professional first impression  
**Organized documentation** → Easy to navigate  
**Clear categorization** → Find what you need fast  
**Scalable structure** → Grows with project  
**Consistent patterns** → Predictable locations  

**Everything has its place. Everything in its place.** 📂✨
