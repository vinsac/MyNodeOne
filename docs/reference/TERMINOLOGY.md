# MyNodeOne Terminology Guide

This document standardizes technical terms used throughout MyNodeOne documentation.

---

## Network & Routing Terms

### Subnet Routes (plural) vs Subnet Route (singular)

**Use "subnet routes" (plural) when:**
- Referring to the feature/technology in general
- Example: "Tailscale subnet routes enable LoadBalancer access"
- Example: "Configure subnet routes for network access"

**Use "subnet route" (singular) when:**
- Referring to a specific route instance
- Talking about the approval action (one route per subnet)
- Example: "Approve the subnet route in Tailscale admin"
- Example: "The subnet route for 100.118.5.0/24"

---

## IP Address Terms

### Standard Usage

**LoadBalancer IPs** (preferred)
- Use when referring to IPs assigned by MetalLB to LoadBalancer-type services
- Technical accuracy: These are Kubernetes LoadBalancer service external IPs
- Example: "Services get LoadBalancer IPs from the 100.118.5.200-250 range"

**Service IPs** (acceptable informally)
- Use in simple explanations or casual context
- Example: "Your laptop needs permission to reach service IPs"
- Avoid in technical documentation where precision matters

**Cluster IPs** (different concept)
- Internal Kubernetes ClusterIP (10.43.x.x range)
- NOT the same as LoadBalancer IPs
- Only use when specifically referring to internal cluster networking

---

## Machine Type Terms

### Management Machines

**Management Laptop** (preferred for user-facing docs)
- Use in: Casual docs, tutorials, examples, troubleshooting
- Relatable to end users
- Example: "Run this on your management laptop"

**Management Workstation** (formal/technical contexts)
- Use in: Configuration options, official option names, technical specs
- Example: "Select option 4 (Management Workstation)"
- Example: "Step 5: Setup Management Workstation"

**Laptop** (acceptable shorthand)
- Use after "management laptop" has been established in context
- Example: "The laptop will connect to the control plane"

**Desktop** (use sparingly)
- Only when explicitly distinguishing from laptops
- Example: "Works on laptops, desktops, and workstations"

---

## Node Type Terms

**Control Plane** (always)
- NOT "master node" (deprecated in Kubernetes)
- NOT "control node"
- Example: "Install on the control plane"

**Worker Node** (always)
- NOT "worker" alone
- NOT "compute node"
- Example: "Add worker nodes for more capacity"

**Edge Node** (always)
- Specifically for VPS public-facing nodes
- Example: "Configure edge nodes for public access"

---

## Networking Technology Terms

**Tailscale** (always capitalized)
- Product name, always capitalize
- Example: "Connect via Tailscale"

**MetalLB** (camelCase)
- Product name, specific capitalization
- Example: "MetalLB assigns LoadBalancer IPs"

**WireGuard** (camelCase)
- Protocol name, specific capitalization
- Example: "Tailscale uses WireGuard encryption"

---

## Domain Terms

**.local domains** (lowercase)
- Use lowercase unless starting a sentence
- Example: "Access services via .local domains"
- Example: ".local domains provide friendly names"

**mynodeone.local** (all lowercase)
- Domain suffix, always lowercase
- Example: "http://grafana.mynodeone.local"

---

## Service Names

### Capitalization

- **Grafana** - Capitalize
- **ArgoCD** - Camel case (product name)
- **MinIO** - Camel case (product name)
- **Longhorn** - Capitalize
- **Traefik** - Capitalize
- **Kubernetes** - Always capitalize
- **kubectl** - Always lowercase (command name)

---

## Action Terms

### Setup vs Set Up

**setup** (noun)
- Example: "The laptop setup process"
- Example: "Complete the setup wizard"

**set up** (verb)
- Example: "Set up your laptop"
- Example: "We'll set up kubectl automatically"

### Login vs Log In

**login** (noun)
- Example: "Enter your login credentials"
- Example: "The login page appears"

**log in** (verb)
- Example: "Log in to Tailscale"
- Example: "You need to log in first"

---

## Documentation Cross-References

### Consistency in Referring to Other Docs

**Use full relative paths:**
- Example: "See `docs/guides/POST_INSTALLATION_GUIDE.md`"
- NOT: "See POST_INSTALLATION_GUIDE.md" (ambiguous location)

**Use descriptive link text:**
- Example: "[Post-Installation Guide](docs/guides/POST_INSTALLATION_GUIDE.md)"
- NOT: "See [here](link)" (poor accessibility)

---

## Common Phrases

### Standardized Phrases

**When describing what scripts do:**
- ✅ "This automatically configures..."
- ✅ "The script will..."
- ❌ "We automatically configure..." (avoid "we")

**When giving instructions:**
- ✅ "Run this command:"
- ✅ "On your control plane, execute:"
- ❌ "Please run..." (avoid "please", be direct)

**When explaining technical concepts:**
- ✅ "**Simple:** [simple explanation]"
- ✅ "**Technical:** [technical explanation]"
- ✅ "**What This Means:**" (title case for headings)

---

## Checklist Items

### Formatting

**Use checkmarks consistently:**
- ✅ for completed or working states
- ❌ for errors or not working
- ⚠️ for warnings or important notes

**Example:**
```
- ✅ Services accessible
- ❌ Connection timeout
- ⚠️ Action required
```

---

## Version Numbers

**Format:** vX.Y.Z
- Example: "v1.0.0"
- Example: "Version 1.2.3"
- Use "v" prefix in casual context
- Use "Version X.Y.Z" in formal docs

---

## Common Abbreviations

**Acceptable:**
- IP (Internet Protocol)
- DNS (Domain Name System)
- SSH (Secure Shell)
- VPN (Virtual Private Network)
- UI (User Interface)
- CLI (Command Line Interface)
- API (Application Programming Interface)

**Avoid or spell out first time:**
- LB (LoadBalancer) - spell out
- k8s (Kubernetes) - spell out in user docs
- CP (Control Plane) - spell out

---

## Number Formatting

**Use digits for:**
- Technical measurements: "100 GB", "8 cores"
- IP addresses: "100.118.5.203"
- Versions: "v1.0.0"
- Time: "30 seconds", "5 minutes"

**Spell out for:**
- Starting sentences: "Three steps are required"
- Small numbers in casual text: "one machine", "two options"

---

## Code and Commands

### Formatting

**Inline code:** Use backticks for commands, file paths, variables
- Example: Run `kubectl get nodes` to check status
- Example: Edit `/etc/hosts` file

**Code blocks:** Use fenced code blocks with language
```bash
kubectl get nodes
```

**File paths:** Always use absolute paths or clear relative paths
- ✅ `/home/user/mynodeone/scripts/setup.sh`
- ✅ `./scripts/setup.sh` (from project root)
- ❌ `scripts/setup.sh` (ambiguous)

---

## Audience-Specific Terms

### For Non-Technical Users

**Prefer:**
- "Services" over "pods"
- "Install" over "deploy"
- "Connect" over "establish connection"
- "Set up" over "configure"
- "Turn on" over "enable"

**Example:**
> "Install MyNodeOne on your laptop to connect to the cluster"

### For Technical Users

**Use precise terms:**
- "LoadBalancer service"
- "Deploy workload"
- "Configure networking"
- "Enable feature flags"

**Example:**
> "Configure the LoadBalancer service to expose the application"

---

## Consistency Checklist

When writing or editing documentation:

- [ ] Check capitalization of product names (Grafana, ArgoCD, MinIO)
- [ ] Use "LoadBalancer IPs" for technical accuracy
- [ ] Use "subnet routes" (plural) for the feature, "subnet route" (singular) for specific instances
- [ ] Use "management laptop" in casual docs, "management workstation" in formal contexts
- [ ] Provide both simple and technical explanations
- [ ] Use ✅ ❌ ⚠️ consistently for status indicators
- [ ] Format code/commands/paths correctly
- [ ] Use proper heading case (Title Case for major headings)
- [ ] Cross-reference other docs with full paths

---

**Last Updated:** October 27, 2025  
**Maintained By:** MyNodeOne Documentation Team
