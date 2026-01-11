# Domain & DNS Management Scripts

This directory contains scripts for managing domains, DNS configuration, and name resolution across the cluster.

## Domain Management

### `add-domain.sh`
Add a new domain for public access through VPS edge nodes.

**Usage:**
```bash
sudo ./scripts/domains/add-domain.sh
```

**Features:**
- Domain registration
- DNS configuration
- SSL certificate setup
- VPS routing configuration

### `remove-domain.sh`
Remove a domain from the cluster.

**Usage:**
```bash
sudo ./scripts/domains/remove-domain.sh <domain>
```

### `configure-domain-routing.sh`
Configure routing rules for a specific domain.

**Usage:**
```bash
sudo ./scripts/domains/configure-domain-routing.sh <domain>
```

## DNS Configuration

### `setup-local-dns.sh`
Configure local DNS resolution for `.local` domains.

**Usage:**
```bash
sudo ./scripts/domains/setup-local-dns.sh
```

### `sync-dns.sh`
Synchronize DNS entries across all nodes.

**Usage:**
```bash
sudo ./scripts/domains/sync-dns.sh
```

### `update-laptop-dns.sh`
Update DNS configuration on management laptops.

### `configure-app-dns.sh`
Configure DNS entries for deployed applications.

**Usage:**
```bash
sudo ./scripts/domains/configure-app-dns.sh
```

## DNS Troubleshooting

### `check-dns-ready.sh`
Check if DNS is properly configured and responding.

**Usage:**
```bash
./scripts/domains/check-dns-ready.sh <domain>
```

### `fix-duplicate-dns.sh`
Fix duplicate DNS entries in CoreDNS configuration.

**Usage:**
```bash
sudo ./scripts/domains/fix-duplicate-dns.sh
```

### `fix-tailscale-dns-permanent.sh`
Permanently fix Tailscale DNS conflicts.

### `coredns-dns-guardian.sh`
Monitor and auto-fix DNS issues (daemon mode).

## Notes

- DNS changes may take a few seconds to propagate
- `.local` domains work only within Tailscale network
- Public domains require VPS edge node
- Use `check-dns-ready.sh` to verify DNS configuration
- DNS sync happens automatically via sync controller
