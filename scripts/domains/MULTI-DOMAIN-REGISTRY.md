# Multi-Domain Registry

**Advanced multi-domain and multi-VPS management for MyNodeOne**

---

## 🎯 Overview

The `multi-domain-registry.sh` script provides advanced domain management capabilities for:

- **Multiple public domains** (e.g., `example.com`, `test.org`)
- **Multiple VPS edge nodes** for load balancing and failover
- **Advanced routing strategies** (round-robin, primary-backup)
- **Programmatic access** for automation and CI/CD

---

## 🔧 When to Use This vs. Standard Domain Scripts

### 👥 **Use Standard Domain Scripts For:**
- **Single domain addition** → `./scripts/domains/add-domain.sh`
- **Interactive domain management** → User-friendly prompts
- **Basic domain removal** → `./scripts/domains/remove-domain.sh`
- **Simple routing configuration** → `./scripts/domains/configure-domain-routing.sh`

### 🔧 **Use Multi-Domain Registry For:**
- **Batch domain operations** → Register multiple domains at once
- **Multi-VPS load balancing** → Distribute traffic across VPS nodes
- **Advanced routing strategies** → Custom failover and load balancing
- **Programmatic access** → Scripting, automation, CI/CD integration
- **Registry inspection** → Debugging and configuration management

---

## 📋 Prerequisites

- MyNodeOne cluster installed
- At least one VPS edge node configured
- Public domain(s) with DNS A records pointing to VPS

---

## 🚀 Quick Start

### 1. Initialize Registry

```bash
sudo ./scripts/domains/multi-domain-registry.sh init
```

### 2. Register Domains

```bash
sudo ./scripts/domains/multi-domain-registry.sh register-domain example.com "Main site"
sudo ./scripts/domains/multi-domain-registry.sh register-domain test.org "Test site"
```

### 3. Register VPS Nodes

```bash
# Format: register-vps <tailscale_ip> <public_ip> <region> <provider>
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.68.225.92 192.0.2.100 eu contabo

sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.70.123.45 167.99.1.1 us digitalocean
```

### 4. Configure Service Routing

```bash
# Format: configure-routing <service> "<domains>" "<vps_ips>" <strategy>
sudo ./scripts/domains/multi-domain-registry.sh configure-routing immich \
    "example.com,test.org" \
    "100.68.225.92,100.70.123.45" \
    round-robin
```

---

## 📚 Command Reference

### **Registry Management**

| **Command** | **Description** | **Example** |
|-------------|----------------|-------------|
| `init` | Initialize domain registry | `sudo ./scripts/domains/multi-domain-registry.sh init` |
| `show` | Display all configuration | `sudo ./scripts/domains/multi-domain-registry.sh show` |
| `export` | Export registry as JSON | `sudo ./scripts/domains/multi-domain-registry.sh export` |

### **Domain Operations**

| **Command** | **Description** | **Example** |
|-------------|----------------|-------------|
| `register-domain <domain> [description]` | Register a public domain | `register-domain example.com "Main site"` |
| `unregister-domain <domain>` | Remove a domain | `unregister-domain example.com` |
| `list-domains` | Show all registered domains | `list-domains` |

### **VPS Node Management**

| **Command** | **Description** | **Example** |
|-------------|----------------|-------------|
| `register-vps <tailscale_ip> <public_ip> <region> <provider>` | Register VPS edge node | `register-vps 100.68.225.92 192.0.2.100 eu contabo` |
| `unregister-vps <tailscale_ip>` | Remove VPS node | `unregister-vps 100.68.225.92` |
| `list-vps` | Show all VPS nodes | `list-vps` |

### **Service Routing**

| **Command** | **Description** | **Example** |
|-------------|----------------|-------------|
| `configure-routing <service> "<domains>" "<vps_ips>" <strategy>` | Configure service routing | `configure-routing immich "example.com,test.org" "100.68.225.92,100.70.123.45" round-robin` |
| `remove-routing <service>` | Remove service routing | `remove-routing immich` |
| `export-vps-routes <tailscale_ip> <public_ip>` | Export routes for specific VPS | `export-vps-routes 100.68.225.92 192.0.2.100` |

---

## 🎛️ Routing Strategies

### **Round-Robin** (Default)
Distributes traffic across all VPS nodes:

```bash
sudo ./scripts/domains/multi-domain-registry.sh configure-routing photos \
    "example.com,test.org" \
    "100.68.225.92,100.70.123.45" \
    round-robin
```

**Result:** 
- `photos.example.com` → VPS1
- `photos.test.org` → VPS2

### **Primary-Backup**
Use first VPS as primary, others as backup:

```bash
sudo ./scripts/domains/multi-domain-registry.sh configure-routing chat \
    "example.com,test.org" \
    "100.68.225.92,100.70.123.45" \
    primary-backup
```

**Result:** Both domains → VPS1 (primary), failover to VPS2

---

## 📊 Configuration Examples

### **Basic Multi-Domain Setup**

```bash
# Initialize
sudo ./scripts/domains/multi-domain-registry.sh init

# Register domains
sudo ./scripts/domains/multi-domain-registry.sh register-domain example.com "Main site"
sudo ./scripts/domains/multi-domain-registry.sh register-domain test.org "Test site"

# Register VPS
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.68.225.92 192.0.2.100 eu contabo

# Configure services
sudo ./scripts/domains/multi-domain-registry.sh configure-routing immich \
    "example.com,test.org" "100.68.225.92" round-robin
sudo ./scripts/domains/multi-domain-registry.sh configure-routing jellyfin \
    "example.com" "100.68.225.92" round-robin
```

### **Advanced Multi-VPS Load Balancing**

```bash
# Multiple VPS nodes
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.68.225.92 192.0.2.100 eu contabo
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.70.123.45 167.99.1.1 us digitalocean
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.72.200.50 203.0.113.100 asia linode

# Load balance critical services
sudo ./scripts/domains/multi-domain-registry.sh configure-routing immich \
    "example.com,test.org" \
    "100.68.225.92,100.70.123.45,100.72.200.50" \
    round-robin

# Primary-backup for management services
sudo ./scripts/domains/multi-domain-registry.sh configure-routing grafana \
    "example.com" \
    "100.68.225.92,100.70.123.45" \
    primary-backup
```

---

## 🔍 Viewing Configuration

### **Show All Configuration**

```bash
sudo ./scripts/domains/multi-domain-registry.sh show
```

**Output:**
```
Multi-Domain, Multi-VPS Configuration

Registered Domains:
  - example.com: Main site
  - test.org: Test site

Registered VPS Nodes:
  - 100.68.225.92 → 192.0.2.100 (eu)
  - 100.70.123.45 → 167.99.1.1 (us)

Service Routing:
  - immich:
    Domains: example.com, test.org
    VPS: 100.68.225.92, 100.70.123.45
    Strategy: round-robin
  - jellyfin:
    Domains: example.com
    VPS: 100.68.225.92
    Strategy: round-robin
```

### **Export as JSON**

```bash
sudo ./scripts/domains/multi-domain-registry.sh export
```

---

## 🛠️ Advanced Usage

### **Batch Domain Registration**

```bash
#!/bin/bash
# batch-domains.sh

DOMAINS=(
    "example.com:Main site"
    "test.org:Test environment"
    "staging.domain.com:Staging environment"
)

for domain_info in "${DOMAINS[@]}"; do
    IFS=':' read -r domain description <<< "$domain_info"
    sudo ./scripts/domains/multi-domain-registry.sh register-domain "$domain" "$description"
    echo "✓ Registered $domain"
done
```

### **Automated VPS Registration**

```bash
#!/bin/bash
# auto-register-vps.sh

VPS_CONFIGS=(
    "100.68.225.92:192.0.2.100:eu:contabo"
    "100.70.123.45:167.99.1.1:us:digitalocean"
)

for vps_config in "${VPS_CONFIGS[@]}"; do
    IFS=':' read -r tailscale_ip public_ip region provider <<< "$vps_config"
    sudo ./scripts/domains/multi-domain-registry.sh register-vps \
        "$tailscale_ip" "$public_ip" "$region" "$provider"
    echo "✓ Registered VPS $tailscale_ip"
done
```

### **Service Health Checks**

```bash
#!/bin/bash
# check-routing-health.sh

# Get routing configuration
config=$(sudo ./scripts/domains/multi-domain-registry.sh export)

# Check each service
echo "Checking service routing health..."
echo "$config" | jq -r '.routing | keys[]' | while read service; do
    domains=$(echo "$config" | jq -r ".routing[\"$service\"].domains[]?")
    vps_nodes=$(echo "$config" | jq -r ".routing[\"$service\"].vps_nodes[]?")
    
    echo "🔍 $service:"
    echo "  Domains: $domains"
    echo "  VPS Nodes: $vps_nodes"
    
    # Test connectivity to each VPS
    for vps in $vps_nodes; do
        if ping -c 1 "$vps" &>/dev/null; then
            echo "  ✅ $vps - reachable"
        else
            echo "  ❌ $vps - unreachable"
        fi
    done
done
```

---

## 🔧 Integration with Other Scripts

### **Standard Domain Scripts Use This Registry**

The standard domain scripts (`add-domain.sh`, `remove-domain.sh`, etc.) automatically call this registry:

```bash
# When you run:
sudo ./scripts/domains/add-domain.sh

# It internally calls:
sudo ./scripts/domains/multi-domain-registry.sh register-domain "$domain" "$description"
sudo ./scripts/domains/multi-domain-registry.sh configure-routing "$service" "$domains" "$vps" "round-robin"
```

### **Sync Controller Integration**

The registry integrates with the sync controller for automatic propagation:

```bash
# Push changes to all nodes
sudo ./scripts/lib/sync-controller.sh push
```

---

## 🚨 Troubleshooting

### **Registry Not Initialized**

```bash
Error: Domain registry not found
Solution: sudo ./scripts/domains/multi-domain-registry.sh init
```

### **VPS Not Registered**

```bash
Error: VPS node not found in registry
Solution: sudo ./scripts/domains/multi-domain-registry.sh register-vps <tailscale_ip> <public_ip> <region> <provider>
```

### **Service Not Found**

```bash
Error: Service not registered
Solution: Install the service first, then configure routing
```

### **Check Registry Status**

```bash
# View complete registry
sudo ./scripts/domains/multi-domain-registry.sh show

# Check specific service
sudo ./scripts/domains/multi-domain-registry.sh show | grep -A 10 "immich"
```

---

## 📝 Best Practices

1. **Initialize First**: Always run `init` before other operations
2. **Use Descriptive Names**: Provide clear descriptions for domains
3. **Test DNS First**: Ensure DNS A records point to VPS before registration
4. **Monitor Health**: Regularly check VPS connectivity and service status
5. **Backup Configuration**: Export registry before major changes
6. **Use Consistent Naming**: Follow naming conventions for domains and services

---

## 🔄 Migration from Single Domain

If you're migrating from single-domain setup:

```bash
# 1. Initialize multi-domain registry
sudo ./scripts/domains/multi-domain-registry.sh init

# 2. Register existing domain
sudo ./scripts/domains/multi-domain-registry.sh register-domain yourdomain.com "Main site"

# 3. Register existing VPS
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    $(tailscale ip -4) $(curl -s ifconfig.me) us your-provider

# 4. Migrate existing services
for service in immich jellyfin nextcloud; do
    sudo ./scripts/domains/multi-domain-registry.sh configure-routing \
        "$service" "yourdomain.com" "$(tailscale ip -4)" round-robin
done
```

---

## 📚 Related Documentation

- [Domain and Public Access](../operations/DOMAIN-AND-PUBLIC-ACCESS.md) - Standard domain setup
- [Multi-Domain Setup](../operations/MULTI-DOMAIN-SETUP.md) - Advanced configuration
- [Sync Controller](../architecture/SYNC-CONTROLLER.md) - Automatic synchronization
- [VPS Edge Node Setup](../installation/INSTALLATION.md) - VPS installation

---

## 🆘 Getting Help

```bash
# Show help
sudo ./scripts/domains/multi-domain-registry.sh help

# Check registry status
sudo ./scripts/domains/multi-domain-registry.sh show

# View logs
sudo journalctl -u mynodeone-sync-controller -f
```
