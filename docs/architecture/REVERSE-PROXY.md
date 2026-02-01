# Reverse Proxy Architecture

This document explains how MyNodeOne routes traffic from the internet to your applications using Traefik as a reverse proxy on VPS edge nodes.

---

## Overview

When you host multiple domains (e.g., `example.com` and `test.org`) on the same VPS, Traefik uses **host-based routing** to direct each request to the correct backend service in your cluster.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           INTERNET                                       │
│                                                                          │
│  User visits: https://example.com                                 │
│  DNS resolves to: 192.0.2.100 (your VPS)                               │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         VPS Edge Node                                    │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                         TRAEFIK                                  │    │
│  │                                                                  │    │
│  │  1. TLS Termination (Let's Encrypt)                             │    │
│  │  2. Read Host header from request                               │    │
│  │  3. Match to router rule                                        │    │
│  │  4. Forward to backend via Tailscale                            │    │
│  └──────────────────────────────┬──────────────────────────────────┘    │
└─────────────────────────────────┼────────────────────────────────────────┘
                                  │
                                  ▼ (Tailscale tunnel)
┌─────────────────────────────────────────────────────────────────────────┐
│                         Your Home Cluster                                │
│                                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │  Blog Pod    │    │  App Pod     │    │  API Pod     │              │
│  │  100.x.x.1   │    │  100.x.x.2   │    │  100.x.x.3   │              │
│  └──────────────┘    └──────────────┘    └──────────────┘              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Host-Based Routing

### How It Works

Every HTTP/HTTPS request includes a **Host header** that specifies which domain the user is trying to reach. Traefik examines this header to decide where to route the request.

| Request | Host Header | Traefik Action |
|---------|-------------|----------------|
| `https://example.com/blog` | `example.com` | Route to blog service |
| `https://test.org/app` | `test.org` | Route to test service |
| `https://192.0.2.100/` | (none - IP only) | 404 or default page |

### Generated Traefik Configuration

The Node Agent generates this configuration on VPS nodes:

```yaml
# /path/to/traefik/config/mynodeone-routes.yml

http:
  routers:
    # Router for example.com
    blog:
      rule: "Host(`example.com`)"
      service: blog
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
    
    # Router for example.com
    example:
      rule: "Host(`example.com`)"
      service: example
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt

  services:
    blog:
      loadBalancer:
        servers:
          - url: "http://100.x.x.1:8080"  # Tailscale IP of blog pod
    
    curiios:
      loadBalancer:
        servers:
          - url: "http://100.x.x.2:8081"  # Tailscale IP of curiios pod
```

### Key Concepts

- **Router**: Matches incoming requests by domain (Host rule)
- **Service**: Defines the backend server(s) to forward requests to
- **EntryPoint**: The port Traefik listens on (`websecure` = 443)
- **TLS/certResolver**: Automatic Let's Encrypt certificate management

---

## Multiple Domains, One VPS

When multiple domains point to the same VPS IP address:

```
DNS Records:
  example.com    →  A  →  192.0.2.100
  test.org      →  A  →  192.0.2.100
  blog.example.com   →  A  →  192.0.2.100
```

**Request Flow:**

```
User: https://example.com
         │
         ▼
    ┌─────────────────────────────────────────────────────┐
    │              VPS (192.0.2.100)                     │
    │                                                     │
    │  Traefik receives request:                         │
    │    Host: example.com                         │
    │                                                     │
    │  Matches router rule:                              │
    │    rule: "Host(`example.com`)"               │
    │                                                     │
    │  Forwards to service:                              │
    │    url: "http://100.x.x.1:8080"                    │
    └─────────────────────────────────────────────────────┘
         │
         ▼
    Blog Pod (100.x.x.1:8080)
```

Each domain gets:
- Its own router rule
- Its own Let's Encrypt SSL certificate
- Its own backend service mapping

---

## Direct IP Access

### What happens when someone visits the VPS IP directly?

If a user types `http://192.0.2.100` in their browser:

1. **No Host header match** - The request contains an IP, not a domain
2. **No router rule matches** - Traefik has no rule for this "host"
3. **Result: 404 Not Found** - Or a default backend if configured

**This is a security feature:**
- Prevents discovery of services by IP scanning
- Only requests with valid domain names are routed
- Reduces attack surface

### Configuring a Default Backend (Optional)

If you want to show a custom page for direct IP access:

```yaml
http:
  routers:
    default:
      rule: "PathPrefix(`/`)"
      priority: 1  # Lowest priority - only matches if nothing else does
      service: default-page
      entryPoints:
        - web
        - websecure

  services:
    default-page:
      loadBalancer:
        servers:
          - url: "http://100.x.x.x:8080"  # Your default page service
```

---

## Multi-VPS Redundancy

For high availability, you can point a domain to multiple VPS nodes using DNS round-robin.

### DNS Configuration

```
example.com    →  A  →  192.0.2.100  (VPS A - EU)
example.com    →  A  →  167.99.1.1    (VPS B - US)
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           USER BROWSER                                   │
│                                                                          │
│  DNS query for example.com returns:                               │
│    - 192.0.2.100 (VPS A)                                               │
│    - 167.99.1.1   (VPS B)                                               │
│                                                                          │
│  Browser picks one (round-robin or random)                              │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
           ┌───────────────┐         ┌───────────────┐
           │    VPS A      │         │    VPS B      │
           │   (EU)        │         │   (US)        │
           │  192.0.2.100  │         │  167.99.1.1   │
           │               │         │               │
           │   Traefik     │         │   Traefik     │
           │   (identical  │         │   (identical  │
           │    config)    │         │    config)    │
           └───────┬───────┘         └───────┬───────┘
                   │                         │
                   └──────────┬──────────────┘
                              │
                              ▼ (via Tailscale)
                    ┌──────────────────┐
                    │  Your Cluster    │
                    │  (same backend)  │
                    └──────────────────┘
```

### How It Works

1. **Identical Configuration**: Node Agent syncs the same routes to all VPS nodes
2. **Independent SSL Certs**: Each VPS obtains its own Let's Encrypt certificate
3. **Same Backend**: Both VPS nodes route to the same cluster via Tailscale
4. **DNS Load Balancing**: Traffic is distributed across VPS nodes
5. **Automatic Failover**: If one VPS fails, DNS TTL expires and traffic shifts

### Benefits

| Benefit | Description |
|---------|-------------|
| **Redundancy** | If VPS A goes down, VPS B handles all traffic |
| **Geographic Distribution** | Users connect to nearest VPS (lower latency) |
| **Load Distribution** | Traffic split across multiple edge nodes |
| **DDoS Resilience** | Attack on one VPS doesn't affect the other |

---

## SSL/TLS Certificates

### Automatic Certificate Management

Traefik automatically obtains and renews SSL certificates from Let's Encrypt:

1. **Domain Verification**: Let's Encrypt sends HTTP challenge to your domain
2. **Traefik Responds**: Proves you control the domain
3. **Certificate Issued**: Valid for 90 days
4. **Auto-Renewal**: Traefik renews before expiration

### Multi-VPS Certificate Handling

When using multiple VPS nodes for the same domain:
- Each VPS obtains its own certificate independently
- Both certificates are valid for the same domain
- No certificate sharing required between VPS nodes

---

## Routing Summary

| Scenario | Host Header | Result |
|----------|-------------|--------|
| `https://example.com` | `example.com` | Routes to blog backend |
| `https://test.org` | `test.org` | Routes to test backend |
| `https://api.test.org` | `api.test.org` | Routes to API backend (if configured) |
| `http://192.0.2.100` | (none) | 404 Not Found |
| `https://unknown.com` → VPS IP | `unknown.com` | 404 (no matching rule) |

---

## Related Documentation

- [NETWORKING.md](NETWORKING.md) - Tailscale mesh networking
- [SYNC-CONTROLLER-V2.md](SYNC-CONTROLLER-V2.md) - How routes are synced to VPS
- [DNS.md](DNS.md) - DNS configuration for domains