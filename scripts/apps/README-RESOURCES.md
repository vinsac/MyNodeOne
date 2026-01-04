# Resource Optimization for Homelab Deployments

## Overview

MyNodeOne apps are optimized for **homelab environments with bursty traffic patterns**. This means apps typically have low baseline usage with occasional spikes during active use.

## Resource Strategy

### Philosophy

**Low Requests + High Limits = Maximum Pod Density**

- **Memory Requests:** Set very low (64-256 Mi) to allow maximum pod scheduling density
- **Memory Limits:** Set reasonably high (2-16 Gi) to handle bursts without OOM kills
- **CPU Requests:** Minimal (50-100m) to avoid over-provisioning
- **CPU Limits:** Removed to prevent throttling during bursts

### Why This Works

**Homelab Traffic Characteristics:**
- Most apps idle 90% of the time
- Traffic is bursty (e.g., photo upload, video transcode, LLM inference)
- Multiple apps rarely spike simultaneously
- Users tolerate slightly slower response during contention

**Benefits:**
- ✅ **Higher Pod Density:** More apps fit on limited nodes
- ✅ **No CPU Throttling:** Bursts use full CPU when available
- ✅ **Flexible Resource Sharing:** Idle apps consume minimal resources
- ✅ **Cost-Effective:** Maximize hardware utilization

**Trade-offs:**
- ⚠️ **Potential Contention:** Multiple simultaneous bursts may slow down
- ⚠️ **Eviction Risk:** Low memory requests mean pods may be evicted under pressure
- ⚠️ **Not Production-Grade:** Unsuitable for SLA-bound workloads

## Priority Classes

Two priority classes ensure critical infrastructure survives resource pressure:

### `mynodeone-infrastructure` (Priority: 2000)

**Purpose:** Infrastructure components that must stay running

**Used by:**
- PostgreSQL databases
- Redis caches
- Other backing services

**Resource Profile:**
- Requests: 64-128 Mi memory, 100m CPU
- Limits: 512 Mi - 2 Gi memory, no CPU limit

### `mynodeone-app` (Priority: 1000)

**Purpose:** User-facing applications

**Used by:**
- LLMAPI Gateway, vLLM, llama.cpp, embedding
- Immich, Nextcloud, Mattermost, Paperless
- Jellyfin, Open WebUI, Homepage

**Resource Profile:**
- Requests: 64-256 Mi memory, 50-100m CPU
- Limits: 2-128 Gi memory (varies by app), no CPU limit

## Per-App Configuration

### AI/LLM Workloads

**Gateway:** 64 Mi request → 2 Gi limit
**vLLM (GPU):** 2 Gi request → 32 Gi limit (+ 1 GPU)
**llama.cpp (CPU):** 4 Gi request → 180 Gi limit
**Embedding:** 512 Mi request → 8 Gi limit
**Ollama:** 1-2 Gi request → 16-128 Gi limit (depends on GPU/CPU mode)

**Rationale:** AI models need large limits for context windows, but idle most of the time.

### Photo/Media Apps

**Immich:** 1 Gi request → 16 Gi limit
**Jellyfin:** 256 Mi request → 4 Gi limit

**Rationale:** Photo uploads and video transcoding are sporadic but memory-intensive.

### Productivity Apps

**Nextcloud:** 256 Mi request → 2 Gi limit
**Mattermost:** 256 Mi request → 2 Gi limit
**Paperless:** 256 Mi request → 2 Gi limit

**Rationale:** WebDAV, chat, and OCR processing have moderate memory needs.

### Infrastructure

**PostgreSQL:** 128 Mi request → 512 Mi - 2 Gi limit
**Redis:** 64 Mi request → 256 Mi - 512 Mi limit

**Rationale:** Databases need guaranteed baseline memory, but don't burst much.

## Monitoring Recommendations

**Watch for:**
1. **OOM Kills:** If apps restart frequently, increase memory limits
2. **Pod Evictions:** Low memory requests may cause evictions under pressure
3. **Slow Response:** If multiple apps spike simultaneously, consider dedicated nodes

**Tools:**
```bash
# Check pod resource usage
kubectl top pods -A

# Watch for OOM kills
kubectl get events -A | grep OOM

# Monitor node pressure
kubectl describe nodes | grep -A 5 Conditions
```

## Tuning for Your Environment

### If You Have More RAM

Increase **memory requests** (not limits) to reduce eviction risk:
- Infrastructure: 256 Mi → 512 Mi
- Apps: 512 Mi → 1 Gi

### If You Experience Slowdowns

Identify resource hogs and increase their requests:
```bash
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu
```

### If You Want Production-Grade

Restore CPU limits and increase memory requests to match limits:
- Set `requests.memory` = `limits.memory` (guaranteed QoS)
- Set `limits.cpu` to reasonable values (prevent runaway processes)
- Use separate node pools for different workload types

## Implementation

PriorityClasses are automatically created during installation:

```bash
# Installed by: scripts/apps/lib/priorityclass.yaml
# Applied by: All app installation scripts
```

All apps reference these priority classes in their pod specs via:
```yaml
spec:
  priorityClassName: mynodeone-app  # or mynodeone-infrastructure
```

## Architecture Decision

**Chosen Strategy:** Optimized for homelab bursty traffic

**Rejected Alternatives:**
- **Guaranteed QoS:** Wastes resources, reduces pod density
- **Burstable with high requests:** Still over-provisions, defeats purpose
- **Best-effort (no limits):** Risk of OOM kills and resource starvation

**When to Reconsider:**
- Moving to production with SLAs
- Adding real-time/latency-sensitive workloads
- Experiencing frequent resource contention
