# Application Scaling Patterns in MyNodeOne

**Understanding how storage, compute, and networking interact in Kubernetes**

---

## Table of Contents

1. [The Core Question: How Do Multiple Pods Share Data?](#the-core-question)
2. [Storage Access Modes Explained](#storage-access-modes)
3. [Three Fundamental Scaling Patterns](#three-fundamental-scaling-patterns)
4. [How PostgreSQL Scales with RWO Storage](#how-postgresql-scales-with-rwo-storage)
5. [Real-World Examples in MyNodeOne](#real-world-examples)
6. [When to Use Each Pattern](#when-to-use-each-pattern)
7. [Advanced: RWX and Object Storage](#advanced-patterns)

---

## The Core Question

**Q: If PostgreSQL uses RWO (ReadWriteOnce) storage and only ONE pod can mount it, how can multiple application pods write to the database?**

**A: Network API vs Direct File Access**

```
❌ WRONG (Direct File Access):
[Gateway Pod] → Mounts PVC → Writes files directly
[Redis Pod]   → Mounts PVC → Writes files directly
❌ CONFLICT: Both pods trying to mount same RWO volume

✅ CORRECT (Network API):
[Gateway Pod] ─┐
[Redis Pod]   ─┼→ Network (TCP) → [PostgreSQL Pod] → PVC (RWO)
[vLLM Pod]    ─┘

✓ Only PostgreSQL pod mounts the PVC
✓ Other pods connect via network protocol (port 5432)
✓ PostgreSQL handles concurrent writes internally
```

---

## Storage Access Modes

### RWO (ReadWriteOnce) - Default in MyNodeOne

**Definition:** Volume can be mounted by **one node at a time**

**Key Points:**
- ✅ Can be mounted by ANY node in the cluster
- ✅ When pod moves to different node, volume detaches and reattaches
- ❌ Cannot be mounted by multiple pods simultaneously

**Example:**
```yaml
accessModes:
  - ReadWriteOnce
capacity:
  storage: 100Gi
```

**Used by:** Databases, single-instance apps (Paperless, Immich)

---

### RWX (ReadWriteMany) - Available in Longhorn

**Definition:** Volume can be mounted by **multiple nodes simultaneously**

**Key Points:**
- ✅ Multiple pods can read/write to same filesystem
- ⚠️ Requires NFS-like protocol (slower than RWO)
- ⚠️ Application must handle concurrent file writes

**Used by:** Shared file servers, legacy WordPress with file uploads

---

### ROX (ReadOnlyMany)

**Definition:** Volume can be mounted read-only by multiple nodes

**Used by:** Configuration files, shared static assets

---

## Three Fundamental Scaling Patterns

### Pattern 1: Stateless Applications (Preferred)

**Characteristics:**
- No persistent storage attached to app pods
- All data stored in centralized database or object storage
- Scales horizontally without storage constraints

**Architecture:**
```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ Gateway-1   │  │ Gateway-2   │  │ Gateway-3   │  ← Stateless
│ (No PVC)    │  │ (No PVC)    │  │ (No PVC)    │     (Scale to 100s)
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       └────────────────┼────────────────┘
                        ▼
                  ┌──────────────┐
                  │ PostgreSQL   │  ← Stateful
                  │ (RWO PVC)    │     (1 replica)
                  └──────────────┘
```

**How it works:**
1. User request → LoadBalancer → Any gateway pod
2. Gateway pod connects to PostgreSQL via **network** (TCP port 5432)
3. PostgreSQL pod is the **only** one accessing disk files
4. Other pods are **network clients** (like your laptop connecting to database)

**Examples in MyNodeOne:**
- Gateway (2 replicas)
- Embedding service (1 replica, can scale to 5+)
- Future: Web servers, API services

**Scaling:**
```bash
# Scale gateway to 5 replicas (no storage changes needed)
kubectl scale deployment gateway -n llmapi --replicas=5
```

---

### Pattern 2: Single-Instance Stateful Applications

**Characteristics:**
- App writes directly to filesystem
- 1 replica with RWO storage
- Doesn't need to scale horizontally

**Architecture:**
```
┌──────────────────┐
│ Paperless Pod    │  ← Single instance
│ ┌──────────────┐ │
│ │ RWO PVC      │ │  ← Direct file access
│ │ 100Gi docs   │ │
│ └──────────────┘ │
└──────────────────┘
```

**How it works:**
1. User uploads document
2. Paperless pod writes file directly to PVC
3. Only 1 pod runs at a time
4. Pod can run on any node (storage follows via network-attached Longhorn)

**Examples in MyNodeOne:**
- Paperless (document management)
- Immich (photo storage)
- Redis (in-memory cache with persistence)

**Why 1 replica is sufficient:**
- Personal/family use = low concurrent users
- Single pod can handle 100s of users
- File-based apps don't need horizontal scaling

**Vertical scaling:**
```yaml
resources:
  requests:
    cpu: "2"      # Increase CPU
    memory: "4Gi" # Increase RAM
  limits:
    cpu: "4"
    memory: "8Gi"
```

---

### Pattern 3: Network Service with Storage Backend

**Characteristics:**
- Service pod manages storage
- Other pods connect via network API
- Service handles concurrent access internally

**Architecture:**
```
┌────────────┐  ┌────────────┐  ┌────────────┐
│ App Pod 1  │  │ App Pod 2  │  │ App Pod 3  │
└─────┬──────┘  └─────┬──────┘  └─────┬──────┘
      │               │               │
      └───────────────┼───────────────┘
                      ▼ (Network: TCP/IP)
              ┌───────────────────┐
              │ PostgreSQL Pod    │
              │ Port: 5432        │
              │ ┌───────────────┐ │
              │ │ RWO PVC       │ │  ← Only this pod
              │ │ Database files│ │     touches files
              │ └───────────────┘ │
              └───────────────────┘
```

**Examples in MyNodeOne:**
- PostgreSQL (database server)
- Redis (cache server)
- MinIO (object storage server)

---

## How PostgreSQL Scales with RWO Storage

### The Network Protocol Layer

**PostgreSQL is a network service:**

```
Client Application (Python, Node.js, etc.)
         ↓
PostgreSQL Wire Protocol (TCP port 5432)
         ↓
PostgreSQL Server Process
         ↓
Direct File I/O
         ↓
RWO PVC (only PostgreSQL pod can mount)
```

### Detailed Example: LLMAPI Gateway → PostgreSQL

**Step 1: Gateway pod connects via network**
```python
# Inside Gateway pod
import psycopg2

# Connects via Kubernetes Service (network)
conn = psycopg2.connect(
    host="llmapi-postgres",  # DNS name (resolves to 10.43.106.234)
    port=5432,                # TCP port
    database="llmapi",
    user="llmapi"
)

# Gateway NEVER touches the PVC files directly
# It sends SQL commands over the network
cursor.execute("INSERT INTO api_keys ...")
```

**Step 2: PostgreSQL pod receives network request**
```
PostgreSQL Server (inside llmapi-postgres pod):
1. Listens on 0.0.0.0:5432
2. Receives connection from Gateway pod (10.42.2.18)
3. Authenticates user
4. Executes SQL: INSERT INTO api_keys ...
5. Writes data to /var/lib/postgresql/data (mounted from PVC)
6. Returns success to Gateway
```

**Step 3: Only PostgreSQL touches the files**
```bash
# Inside PostgreSQL pod:
$ ls /var/lib/postgresql/data/
base/  pg_wal/  pg_xlog/  # ← RWO PVC mounted here

# Inside Gateway pod:
$ ls /
# No /var/lib/postgresql - doesn't exist!
# Gateway has NO access to PostgreSQL files
```

### Concurrency Handling

**PostgreSQL handles concurrent writes internally:**

```
[Gateway-1] ──┐
              ├─→ [PostgreSQL] → Handles locking, transactions, ACID
[Gateway-2] ──┘                   ↓
                              File writes serialized internally
```

PostgreSQL uses:
- **Multi-Version Concurrency Control (MVCC)**
- **Write-Ahead Logging (WAL)**
- **Transaction isolation**

**Result:** Multiple clients can write simultaneously, but only PostgreSQL pod touches disk files.

---

## Real-World Examples in MyNodeOne

### Example 1: LLMAPI Service

**Components:**
```
Stateless Layer (Can scale to 100s of pods):
├─ Gateway (2 replicas) → No PVC
├─ Embedding (1 replica) → No PVC
└─ vLLM (1 replica) → RWO PVC (model files, read-only after download)

Stateful Layer (Managed separately):
├─ PostgreSQL (1 replica) → RWO PVC (5Gi)
└─ Redis (1 replica) → RWO PVC (1Gi)
```

**How scaling works:**
```bash
# Scale gateway from 2 to 10 replicas
kubectl scale deployment gateway -n llmapi --replicas=10

# All 10 pods connect to same PostgreSQL
# PostgreSQL handles concurrent connections
# No storage conflicts because network API
```

---

### Example 2: Paperless Document Management

**Components:**
```
Single-Instance (Does NOT need to scale):
└─ Paperless (1 replica) → RWO PVC (100Gi documents)

Supporting Services (Stateful):
├─ PostgreSQL (1 replica) → RWO PVC (5Gi metadata)
└─ Redis (1 replica) → RWO PVC (1Gi cache)
```

**Why 1 replica is fine:**
- Personal/family use = 5-10 concurrent users max
- Single pod can handle 100+ users easily
- Document uploads = I/O bound, not CPU bound
- If needed, scale vertically (more CPU/RAM to pod)

---

### Example 3: Cross-Node Storage Access

**Scenario:** Pod on Node 1, Storage replica on Node 2

```
┌──────────────────┐              ┌──────────────────┐
│ Node 1 (Control) │              │ Node 2 (Worker)  │
│                  │              │                  │
│ ┌──────────────┐ │  Longhorn    │ ┌──────────────┐ │
│ │Paperless Pod │─┼──iSCSI───────┼→│ Storage      │ │
│ │              │ │  (Network)   │ │ Replica      │ │
│ └──────────────┘ │              │ └──────────────┘ │
└──────────────────┘              └──────────────────┘
```

**How it works:**
1. Pod scheduled on Node 1 (CPU/RAM available)
2. Longhorn presents storage via iSCSI (network protocol)
3. Storage replica physically on Node 2
4. Pod sees it as local disk (/var/lib/paperless/data)
5. Longhorn handles network I/O transparently

**Performance impact:**
- Network latency: ~1-5ms (on Tailscale mesh)
- Still fast enough for most workloads
- For critical apps, use `dataLocality: best-effort` to prefer local storage

---

## When to Use Each Pattern

### Use Stateless Pattern When:

✅ Building web applications, APIs, microservices  
✅ Need to handle variable load (scale up/down)  
✅ Data can be stored in database or object storage  
✅ Want high availability (multiple replicas)  

**Examples:**
- REST APIs
- Web servers (React, Next.js)
- Background workers
- Serverless functions

---

### Use Single-Instance Pattern When:

✅ App writes directly to filesystem  
✅ Personal/family use (low concurrent users)  
✅ App doesn't support clustering  
✅ Simplicity is more important than high availability  

**Examples:**
- Paperless (document management)
- Immich (photo storage)
- Home Assistant
- Media servers (Jellyfin, Plex)

---

### Use Network Service Pattern When:

✅ Building databases, caches, message queues  
✅ Need to share data between multiple apps  
✅ Service handles concurrent access internally  
✅ Standard protocol (SQL, Redis, S3)  

**Examples:**
- PostgreSQL
- Redis
- MinIO (S3 storage)
- RabbitMQ

---

## Advanced: RWX and Object Storage

### When You Need Multiple Pods Writing to Same Files

**Option 1: Use RWX Storage (Longhorn supports this)**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-uploads
spec:
  accessModes:
    - ReadWriteMany  # ← Multiple pods can mount
  storageClassName: longhorn
  resources:
    requests:
      storage: 50Gi
```

**Use cases:**
- Shared file servers
- Legacy WordPress with file uploads
- Multi-instance file processing

**Limitations:**
- Slower than RWO (NFS protocol overhead)
- Apps must handle file locking
- Not all apps support concurrent file writes

---

### Option 2: Object Storage (MinIO) - Recommended

**Why object storage is better than shared filesystem:**

```
Traditional Shared Filesystem (RWX):
[Pod-1] ──┐
[Pod-2] ──┼─→ NFS Volume → Files (slow, complex locking)
[Pod-3] ──┘

Object Storage (S3 API):
[Pod-1] ──┐
[Pod-2] ──┼─→ MinIO API → Objects (fast, built for concurrency)
[Pod-3] ──┘
```

**Benefits:**
- ✅ Designed for concurrent access
- ✅ S3 API is industry standard
- ✅ Better performance than NFS
- ✅ Versioning, replication built-in

**Example: File Uploads with MinIO**

```python
# App pod writes to MinIO (S3-compatible)
from minio import Minio

client = Minio(
    "minio.space.local",
    access_key="...",
    secret_key="..."
)

# Multiple pods can upload simultaneously
client.put_object("uploads", "photo.jpg", data)
```

**MinIO is already installed on your nodes:**
```bash
# Check MinIO status
kubectl get pods -A | grep minio
```

---

## Storage Decision Tree

```
Do multiple pods need to access the data?
│
├─ NO → Single pod with RWO storage
│        Examples: Paperless, Immich
│
└─ YES → Is it structured data (rows/documents)?
         │
         ├─ YES → Use Database (PostgreSQL, MongoDB)
         │        Pods connect via network API
         │
         └─ NO → Is it files/objects?
                  │
                  ├─ Small files, simple access
                  │  → Use RWX shared filesystem
                  │
                  └─ Large files, high concurrency
                     → Use Object Storage (MinIO/S3)
```

---

## Summary: Key Concepts

### 1. Storage Access vs Network Access

**Direct Storage Access (RWO):**
- Only 1 pod can mount
- Pod writes files directly
- Examples: Paperless, databases

**Network API Access:**
- Multiple pods connect via TCP/IP
- Service pod manages storage
- Examples: PostgreSQL clients, MinIO clients

---

### 2. Scaling Strategies

| Pattern | Replicas | Storage | Scales By |
|---------|----------|---------|-----------|
| **Stateless** | Many | None | Adding pods |
| **Single-Instance** | 1 | RWO | Adding CPU/RAM |
| **Network Service** | 1 | RWO | Client apps scale, service handles concurrency |

---

### 3. PostgreSQL: The Answer to Your Question

**Q: How can multiple pods write to PostgreSQL if it uses RWO storage?**

**A: Network Protocol Layer**

```
App Pods (Many)
    ↓ (Network: TCP 5432)
PostgreSQL Pod (1) ← Only this pod mounts PVC
    ↓ (Direct file I/O)
RWO PVC ← Only PostgreSQL accesses these files
```

**PostgreSQL pod:**
- Listens on network port 5432
- Receives SQL commands from many clients
- Translates SQL to file operations
- Only pod that touches disk files
- Handles concurrent writes with MVCC/locks

**App pods:**
- Connect to PostgreSQL over network (like remote database)
- Never mount the PVC
- Never see the database files
- Send SQL, receive results

---

## Further Reading

- **Kubernetes Storage:** [docs/architecture/STORAGE.md](./STORAGE.md)
- **Longhorn Configuration:** [docs/architecture/LONGHORN-SETTINGS.md](./LONGHORN-SETTINGS.md)
- **MinIO Setup:** [scripts/apps/README.md](../../scripts/apps/README.md)
- **Service Registry:** [docs/architecture/SERVICE-REGISTRY.md](./SERVICE-REGISTRY.md)

---

## Questions?

**Common misconceptions:**
1. ❌ "RWO means storage is tied to one node" → ✅ Can be accessed from any node, but one at a time
2. ❌ "Databases can't scale with RWO" → ✅ Client apps scale, database handles concurrency
3. ❌ "Need RWX for any multi-pod app" → ✅ Most apps use stateless pattern with centralized data

**Need help?**
- Check existing app deployments: `kubectl get deploy -A`
- View storage classes: `kubectl get sc`
- See PVC access modes: `kubectl get pvc -A`
