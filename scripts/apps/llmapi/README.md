# LLM API Service

Self-hosted OpenAI-compatible LLM API for MyNodeOne infrastructure.

## Features

- ✅ **OpenAI-Compatible API** - Drop-in replacement for OpenAI clients
- ✅ **Horizontal Scaling** - Automatic routing: GPU1 → GPU2 → CPU (least-loaded first)
- ✅ **Multi-Backend** - vLLM (GPU), llama.cpp (CPU/RAM), dedicated embeddings
- ✅ **Priority Tagging** - Tag requests with `X-Priority` header (realtime/high/normal/low/batch) for metrics segmentation; queue-based scheduling planned
- ✅ **Enterprise Rate Limiting** - Three-layer protection: concurrency cap (GPU-aware) + RPM + TPM per key
- ✅ **Usage Metering** - Track tokens per API key for quotas
- ✅ **Durable State** - PostgreSQL stores API keys and usage logs
- ✅ **Backend Transparency** - Response includes `system_fingerprint` showing which backend handled it
- ✅ **Admin UI** - Web interface at `/admin` for key management and monitoring
- ✅ **API Key Scopes** - Granular permissions: `inference`, `metrics`, `admin`
- ✅ **Auto-Generated Keys** - Admin, Prometheus, and default keys created during install

## Quick Start

### Step 1: Install the Service

Models are downloaded automatically by init containers in the correct HuggingFace cache format:

```bash
# Install the LLM API service
sudo ./scripts/apps/llmapi/install-llmapi.sh

# Interactive prompts will ask:
# 1. Deployment Mode (Full Stack, GPU Only, CPU Only, Minimal)
# 2. Model selection (if applicable)
# 3. Worker node provisioning strategy
# 4. Public access configuration
```

Installation takes ~5-10 minutes:
- Deploys API Gateway, PostgreSQL, Redis, and backend pods
- Models download automatically on first pod startup
- vLLM: ~3-5 min | llama.cpp: ~5-10 min | Embedding: ~1 min

### Step 2: Access the API

```bash
# Get the gateway's LoadBalancer IP, reachable over the tailnet
kubectl get svc -n llmapi llmapi

# Test with curl
curl http://<loadbalancer-ip>/v1/models \
  -H "Authorization: Bearer <your-api-key>"
```

If you published the service, the public address serves the API but not the admin paths. See [Public and tailnet access](#public-and-tailnet-access).

## Automatic Model Downloads

Models download automatically via init containers on **first pod startup only**. All models persist in hostPath volumes and are reused across pod restarts and reinstalls.

### vLLM Models (GPU Inference)
- **Location**: `/var/lib/llmapi/models/vllm/`
- **Format**: HuggingFace cache structure (`models--Org--ModelName/snapshots/<hash>/`)
- **Download**: Uses `huggingface_hub` with `hf_transfer` for parallel downloads (~3-5 min)
- **Example**: `models--Qwen--Qwen3-14B-AWQ/snapshots/abc123/`

### llama.cpp Models (CPU Inference)
- **Location**: `/var/lib/llmapi/models/llamacpp/`
- **Format**: Single GGUF file per model
- **Download**: Uses `aria2c` or `wget` from HuggingFace URLs (~5-10 min for 70B)
- **Example**: `Llama-3.3-70B-Instruct-Q4_K_M.gguf`

### Embedding Models
- **Location**: `/var/lib/llmapi/models/embedding/`
- **Format**: Single GGUF file per model
- **Download**: Uses `aria2c` or `wget` (~1 min)
- **Example**: `nomic-embed-text-v1.5.Q8_0.gguf`

**Model Directory Standards (by backend):**

Different backends have different format requirements:

```
/var/lib/llmapi/models/
├── vllm/                                           # HuggingFace cache format
│   ├── models--Qwen--Qwen3-14B-AWQ/
│   │   ├── snapshots/abc123/
│   │   ├── blobs/
│   │   └── refs/main
│   └── hub/
├── llamacpp/                                       # Single GGUF file
│   └── Qwen3-14B-Q4_K_M.gguf
└── embedding/                                      # Single GGUF file
    └── nomic-embed-text-v1.5.Q8_0.gguf
```

**Why different formats?**
- **vLLM**: Uses `huggingface_hub` library, needs full HF cache structure for transformers/tokenizers
- **llama.cpp/embedding**: Use GGUF quantized format, single-file downloads via direct URL

**Verify Model Format:**
```bash
./scripts/apps/llmapi/verify-model-format.sh  # vLLM only
ls -lh /var/lib/llmapi/models/llamacpp/*.gguf
ls -lh /var/lib/llmapi/models/embedding/*.gguf
```

### Step 2: Worker Node Provisioning

**Worker Node Provisioning Strategies:**

1.  **Sync from Control Plane (Recommended for LAN)**
    *   **Pros:** Fast (uses local network), avoids duplicate downloads
    *   **Cons:** Requires SSH access (keys must be set up)
    *   **How it works:** Uses `rsync` to copy HuggingFace cache from control plane to workers
    *   **Validation:** Only syncs models in correct HuggingFace format (`models--Org--ModelName`)

2.  **Download from HuggingFace (Default)**
    *   **Pros:** Simple, robust, no SSH dependency
    *   **Cons:** Slower (depends on internet speed), uses external bandwidth per node
    *   **How it works:** Workers independently download models using `huggingface_hub`

**Important:** Models must be in HuggingFace cache format. Flat directory structures are not supported.

### Step 3: API Keys

## API Usage

### Chat Completions

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://llmapi.cluster.local/v1",
    api_key="sk-mynodeone-xxxx"
)

response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True
)

for chunk in response:
    print(chunk.choices[0].delta.content, end="")
```

### Embeddings

```python
response = client.embeddings.create(
    model="nomic-embed-text",
    input=["Document text to embed"]
)
print(response.data[0].embedding)
```

### Priority Tagging

```bash
# Tag a request with a priority level (tracked in Prometheus metrics)
curl -H "Authorization: Bearer $API_KEY" \
     -H "X-Priority: high" \
     http://llmapi.cluster.local/v1/chat/completions

# Batch workload (tagged for metrics; processed immediately like all requests)
curl -H "Authorization: Bearer $API_KEY" \
     -H "X-Priority: batch" \
     http://llmapi.cluster.local/v1/embeddings
```

**Note:** `X-Priority` is accepted and reflected in Prometheus metrics (`llmapi_requests_total{priority=...}`), but does **not** affect processing order. All requests are forwarded to backends immediately. Priority-based queue scheduling is planned for a future release.

## Discovering Available Models

**Important**: Always query available models first before making requests:

```python
# List available models
models = client.models.list()
for model in models.data:
    print(f"{model.id} ({model.backend})")

# Then use a model from the list
response = client.chat.completions.create(
    model=models.data[0].id,  # Use first available model
    messages=[...]
)
```

If you request a model that isn't loaded, you'll get a 404 with available alternatives.

## API Key Management

**Auto-generated keys** (created during installation):
```bash
cat ~/.mynodeone/llmapi-key              # inference scope - for API usage
cat ~/.mynodeone/llmapi-admin-key        # admin scope - for admin UI
cat ~/.mynodeone/llmapi-prometheus-key   # metrics scope - for Prometheus
```

**Create additional keys:**
```bash
# Inference key (for applications)
./scripts/apps/llmapi/manage-keys.sh create \
  --name "my-app" \
  --scopes "inference" \
  --tokens 1000000 \
  --rpm 100

# Metrics key (for Prometheus)
./scripts/apps/llmapi/manage-keys.sh create \
  --name "prometheus" \
  --scopes "metrics"

# Admin key (for management)
./scripts/apps/llmapi/manage-keys.sh create \
  --name "admin-user" \
  --scopes "admin"

# List all keys with scopes
./scripts/apps/llmapi/manage-keys.sh list
```

**API Key Scopes:**

| Scope | Endpoints | Purpose |
|-------|-----------|----------|
| `inference` | `/v1/*` | LLM API usage (chat, embeddings, models) |
| `metrics` | `/metrics`, `/health/backends` | Prometheus monitoring |
| `admin` | `/admin/*` | Full administrative access |

**Note:** Admin scope grants all permissions (includes inference + metrics).

**How keys are stored:** Only a hash is stored. PostgreSQL's `api_keys.api_key` column holds the key id (`sha256:` plus the SHA-256 of the raw key), and `key_prefix` holds a short prefix for display. A raw key can't be recovered, so it's shown once, when it's created. The installer's copies are the files above: if one is lost, create a new key and revoke the old one. Rows from an older version are hashed when the gateway starts.

`manage-keys.sh list` shows prefixes, and `list --full` shows key ids. Commands that take a key, such as `revoke`, accept the raw key, its key id, or its prefix as `list` prints it.

**State storage:** API keys and usage logs are stored in PostgreSQL (`llmapi-postgres`). Redis, which requires the password in Secret `llmapi-redis-auth`, holds rate-limit counters, the embedding cache, a cache of key settings, and some Admin UI settings.

## Public and tailnet access

`/admin` and `/openapi.json` are currently reachable on the public address, and over the tailnet at the LoadBalancer IP:

```bash
kubectl get svc -n llmapi llmapi    # EXTERNAL-IP
```

**To do:** move `/admin` and `/openapi.json` behind the VPN. Use a stable tailnet name for access, not the LoadBalancer or Tailscale IP, which can change when a machine is reinstalled. Then set `public_blocked_paths` on the `llmapi` registry entry to `["/admin", "/openapi.json"]`.

The gateway doesn't serve `/docs` and `/redoc` at all, on any address: they're disabled. `API-REFERENCE.md` takes their place.

## Admin Interface

**Access:** `/admin` on the public address, or `http://<loadbalancer-ip>/admin` over the tailnet.

**Authentication:** API key with `admin` scope
```bash
# Use auto-generated admin key
ADMIN_KEY=$(cat ~/.mynodeone/llmapi-admin-key)
curl -H "Authorization: Bearer $ADMIN_KEY" \
     http://<loadbalancer-ip>/admin/keys
```

**Features:**

| Feature | Description |
|---------|-------------|
| **Download Ollama Models** | Enter model name (e.g., `qwen3:14b`), click Download |
| **Change vLLM Model** | Enter HuggingFace model ID, triggers pod restart (~10-30 min) |
| **Change llama.cpp Model** | Enter GGUF URL, triggers pod restart (~5-15 min) |
| **Start/Stop llama.cpp** | Free RAM when not needed (model stays loaded otherwise) |
| **Set HuggingFace Token** | Required for gated models such as Llama on vLLM. Updates a Secret that must already exist; see [HuggingFace token](#huggingface-token) |
| **Manage API Keys** | Create, view, and revoke keys |
| **View Usage Stats** | Track token consumption per key |
| **Backend Status** | Check health of all 4 backends |

**No SSH required** - all model management via web UI, apart from creating the HuggingFace token Secret the first time.

The models page also shows what vLLM's model download is doing, read from the `model-downloader` init containers. It says "status unavailable" if the gateway can't read the pods.

### HuggingFace token

The Admin UI can update Secret `hf-token` but not create it, so the first time, run this on the control node:

```bash
./scripts/apps/llmapi/lib/hf-token.sh set    # Prompts, so the token stays out of your shell history
```

The installer does the same if you give it a token. Without a token the Secret stays absent, and until it exists a save in the Admin UI returns 409 and points at this command.

Pods read the token when they start, so a new one needs a restart:

```bash
kubectl rollout restart statefulset/vllm -n llmapi
```

Ollama doesn't use this Secret.

## Default Models

| Model | Type | Backend | Purpose |
|-------|------|---------|---------|
| `Qwen3-14B-AWQ` | Chat | vLLM (GPU) | Primary - fast GPU inference |
| `Qwen3-14B-Q4` | Chat | llama.cpp (CPU) | Overflow - same model on CPU |
| `bge-m3` | Embedding | Dedicated | Document indexing |

**Same logical model name on GPU and CPU**: Using the same model family ensures
consistent responses, but spillover only happens when both backends expose the
same API model name (for example, both `qwen3-14b`). If llama.cpp exposes
`qwen3-14b-q4-k-m` while vLLM exposes `qwen3-14b`, the gateway treats them as
separate models and will not route a `qwen3-14b` request to llama.cpp.

### Default vLLM Runtime

The installer uses a conservative RTX 3090 profile for the default Qwen3 GPU backend:

| Setting | Default | Purpose |
|---------|---------|---------|
| Model | `Qwen/Qwen3-14B-AWQ` | 4-bit AWQ Qwen3 14B |
| Served name | `qwen3-14b` | OpenAI-compatible API model name |
| Context length | `32768` | Native Qwen3 context window |
| Max sequences | `1` | One active sequence per GPU for 32K stability |
| Max batched tokens | `32768` | Allows one full-context prefill |
| GPU memory utilization | `0.90` | Leaves VRAM headroom on 24GB cards |
| Reasoning parser | `qwen3` | Exposes Qwen3 thinking content through vLLM reasoning fields |
| vLLM image | `vllm/vllm-openai:v0.10.2` | Verified on RTX 3090 nodes with NVIDIA 580.142 |

**Remote code**: `TRUST_REMOTE_CODE` in `vllm-config` is `false` by default, so vLLM won't run Python shipped in a model's repo. That code would run in a pod holding the HuggingFace token. The installer asks when you enter a custom model, and the Admin UI never turns it on. To enable it for a model you trust that fails to load without it, set the key to `"true"` and restart vLLM.

**vLLM image compatibility**: The image tag is intentionally pinned. `vllm/vllm-openai:v0.15.1` was tested on the RTX 3090 cluster and failed during PyTorch CUDA initialization with `cudaGetDeviceCount()` error 803, even though `nvidia-smi` worked in the pod. Do not upgrade the vLLM image without running a Kubernetes GPU smoke test that confirms `torch.cuda.is_available()` is `True` and vLLM can start the default Qwen3 model.

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed design.

```
                         ┌─────────────────┐
                         │   API Gateway   │
                         │  Load Balancer  │
                         └────────┬────────┘
                                  │
               Route to least-loaded backend
                    (GPU preferred)
                                  │
     ┌────────────────────────────┼────────────────────────────┐
     ▼                            ▼                            ▼
┌─────────┐                 ┌───────────┐                ┌───────────┐
│  vLLM   │  ──load-bal──▶  │ llama.cpp │  ──fallback──▶ │  Ollama   │
│  (GPU)  │                 │   (CPU)   │                │  (Flex)   │
│Priority │                 │ Priority  │                │ Priority  │
│   1     │                 │    2      │                │    3      │
└─────────┘                 └───────────┘                └───────────┘
     │
     ├── Always runs: Embedding Service (dedicated)
     ├── Always runs: Redis (queue + cache, rate limits)
     └── Always runs: PostgreSQL (API keys + usage logs)
```

**Intelligent Load Balancing**:
- Routes to **least-loaded** backend (fewest concurrent requests)
- **GPU instances checked first** (vLLM) - fastest response times
- **CPU overflow** (llamacpp) - when all GPUs busy (≥32 concurrent requests)
- **Ollama fallback** - last resort for lazy-loaded models
- Response includes `system_fingerprint: "vllm"` or `"llamacpp"` showing which backend handled it

## Management

```bash
# Check service status
./scripts/apps/llmapi/monitor-llmapi.sh

# Upgrade an existing install to what's in this checkout
./scripts/apps/llmapi/upgrade-llmapi.sh

# Manage API keys
./scripts/apps/llmapi/manage-keys.sh list
./scripts/apps/llmapi/manage-keys.sh create --name "new-app"
./scripts/apps/llmapi/manage-keys.sh revoke sk-mynodeone-xxxx

# Scale backends
./scripts/apps/llmapi/scale-backends.sh vllm 2      # Add vLLM replica
./scripts/apps/llmapi/scale-backends.sh llamacpp 1  # Scale llama.cpp

# Manage models
./scripts/apps/llmapi/manage-models.sh list
./scripts/apps/llmapi/manage-models.sh add-vllm --model Qwen/Qwen3-8B --name qwen3-8b --quantization none
./scripts/apps/llmapi/manage-models.sh add-llamacpp --url https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/main/Ministral-3-14B-Instruct-2512-Q4_K_M.gguf --name ministral3-14b-q4
```

## Upgrading

`upgrade-llmapi.sh` brings an existing install to the state in this checkout: the Redis password Secret, RBAC, Redis, the gateway, and the NetworkPolicy. It's safe to re-run. It never changes PVCs, the Postgres password, or the model settings in ConfigMaps. Use `install-llmapi.sh` for a first install.

**Expect an outage of about 1 to 2 minutes, and no way back except restoring a backup.** The new gateway hashes the API keys in Postgres when it starts, and the old gateway can't read them after that: every key, including admin keys, gets a 401.

| Flag | Effect |
|------|--------|
| `--with-backends` | Also applies the vLLM, llama.cpp, embedding and Ollama manifests. Running backends restart, and vLLM reloads its model onto the GPU. |
| `--skip-network-policy` | Doesn't apply `manifests/networkpolicy.yaml`. |
| `--skip-backup` | Doesn't take the backup. There's then nothing to roll back to, so use it only when a dump already exists. |
| `--skip-deps-check` | Doesn't test the pip lock and images in a throwaway pod first, for when that pod can't run. |
| `--allow-health-monitor` | Starts even though `llmapi-health-monitor.timer` is active. An installed older monitor can restart pods during the upgrade. |
| `--rollback <dir>` | Goes back to a saved backup. See below. Takes `--yes` to skip the confirmation. |

Set `LLMAPI_UPGRADE_BACKUP_DIR` to choose where backups go. The default is `~/.mynodeone/llmapi-upgrades`.

### What it does, in order

1. **Refuses to start**, changing nothing, if the Secret `llmapi-db`, the namespace or the gateway Deployment is missing, or the health monitor is active. To stop the monitor: `sudo systemctl stop llmapi-health-monitor.timer`.
2. **Checks what could fail later**, while the old gateway still serves: manifests through a server-side dry run, the static files ConfigMap, and in a throwaway pod the Redis image, the Python image, the pip lock, and that `main.py` imports with it.
3. **Backs up**, through `kubectl exec`, so a NetworkPolicy can't get in the way: `pg_dump -Fc`, mode 600, checked by reading it back with `pg_restore`, plus the gateway and Redis Deployments, ConfigMaps, RBAC and NetworkPolicies. A failure here stops the upgrade with nothing changed.
4. **Stops the old gateway and waits for it to be gone. The outage starts here.** This has to come first: an old gateway can't authenticate to a Redis that requires a password, and its requests then hang rather than fail, while `/health` keeps answering 200 so Kubernetes keeps sending it traffic.
5. **Restarts Redis** with the password, then applies RBAC.
6. **Starts the new gateway** and waits until it's ready. It hashes the keys on startup. **The outage ends here.**
7. **Applies the backends if asked, then the NetworkPolicy** last, so a bad policy can't be mistaken for a failed gateway, and so the gateway is up to test it against.

During the outage clients get a 5xx from Traefik, not a hang. A run through a throwaway API server with real Redis, Postgres and the real old and new `main.py` took 64 seconds from stopping the old pod to the new one being ready: 32 waiting for the old pod to exit, then Redis, a 12 second pip install, and startup. A slow Longhorn reattach or image pull adds to that, up to about 5 minutes.

Once Redis and the gateway both use the password, a re-run has no cut. It rolls the gateway normally.

### If it stops partway

The script prints what stopped it, the state of the gateway, Redis and Postgres, and the commands to go on or go back. Running it again carries on and keeps the backup from the first attempt, the one taken before any key was hashed.

### Rolling back

```bash
./scripts/apps/llmapi/upgrade-llmapi.sh --rollback ~/.mynodeone/llmapi-upgrades/<timestamp>
```

This asks for confirmation, then stops the gateway, restores Postgres from the dump in one transaction, and puts Redis, RBAC, the gateway's ConfigMaps, the gateway Deployment and the NetworkPolicies back as they were saved. The same test measured 95 seconds of outage, 60 of them the old template's readiness delay.

- **It loses what happened after the dump:** keys created or revoked since then, and usage recorded since then.
- **Never use `kubectl rollout undo` alone.** It brings back the old pod template but not the `gateway-code` ConfigMap, so old templates would load the new `main.py`, and the old code couldn't read the hashed keys anyway.
- Roll back only to a backup taken before the keys were hashed if you want the older gateway back. A later run's backup holds a database the older gateway can't use, and the script says so when it takes one.
- It doesn't touch the backends, even if you ran with `--with-backends`, or `gateway-config`. The Secret `llmapi-redis-auth` stays, unused.

**A backup holds raw API keys until they've been hashed, so treat it like a password file.** Delete it once you're sure you won't go back.

The hashing isn't held back until the new pod is healthy. The new gateway authenticates against the hashed rows, so it can't serve until they exist, and checking both forms during the wait would put a plaintext lookup back into the auth path for one upgrade. The dump covers the same risk and gives an exact way back.

`deploy-gateway.sh` only ships the gateway, for a code change. A release that changes RBAC or the NetworkPolicy needs `upgrade-llmapi.sh`.

## Rate Limiting

The gateway enforces three layers of protection per API key, checked in order:

| Layer | Mechanism | Default | Configurable? |
|-------|-----------|---------|---------------|
| **1. Concurrency** | Max simultaneous in-flight requests per service pool | vLLM: `1 x GPU count`; embeddings: `4 x replica count`; llama.cpp/Ollama: `1 x replica count` | `CONCURRENCY_PER_GPU`, `CONCURRENCY_PER_EMBEDDING_REPLICA`, `CONCURRENCY_PER_LLAMACPP_REPLICA`, `CONCURRENCY_PER_OLLAMA_REPLICA` |
| **2. RPM** | Requests per minute (Redis fixed window) per service pool | `60 RPM` per pool | `DEFAULT_REQUESTS_PER_MINUTE`, `DEFAULT_EMBEDDING_REQUESTS_PER_MINUTE`, `DEFAULT_LLAMACPP_REQUESTS_PER_MINUTE`, `DEFAULT_OLLAMA_REQUESTS_PER_MINUTE` |
| **3. TPM** | Tokens per minute (Redis fixed window) per service pool | `200,000 TPM` per pool | `DEFAULT_TOKENS_PER_MINUTE`, `DEFAULT_EMBEDDING_TOKENS_PER_MINUTE`, `DEFAULT_LLAMACPP_TOKENS_PER_MINUTE`, `DEFAULT_OLLAMA_TOKENS_PER_MINUTE` |

**All limits return HTTP 429 immediately** with a structured error body and accurate `Retry-After` header — the same pattern used by OpenAI, Anthropic, and Azure OpenAI. There is no server-side queuing (which would be a DDoS vector).

**Concurrency is split by service pool:**
- vLLM uses the GPU pool, scaled by configured vLLM URLs: 2 URLs -> 2 concurrent Qwen requests per key by default, with 1 request routed to each GPU backend.
- Embeddings use the embedding pool: 1 embedding replica -> 4 concurrent embedding requests per key by default.
- llama.cpp and Ollama have independent fallback pools, so CPU/Ollama traffic cannot consume vLLM or embedding slots.
- A full embedding pool does not block Qwen/vLLM, and a full GPU pool does not block embeddings.

RPM/TPM windows are also separated by service pool. A key's `tokens_per_minute` applies independently to vLLM, embedding, llama.cpp, and Ollama unless a service-specific TPM override is present.

**Self-healing concurrency leases:** In-flight slots are tracked as `Slot`/`Lease` objects tied to the owning `asyncio.Task`, not as permanent counters or wall-clock TTL lists. If a handler crashes, a client disconnects, or a cancellation interrupts cleanup, the reconciler reaps any lease whose task has ended within `SLOT_RECONCILE_INTERVAL_SECONDS` (default `5`) instead of blocking clients forever.

The default gateway deployment runs one replica so the in-process concurrency leases are authoritative for the backend pool. If you scale the gateway horizontally, each gateway pod maintains its own local leases unless a distributed lease store is added.

**429 error body format:**
```json
{
  "detail": {
    "error": {
	      "type": "concurrency_limit_exceeded",
	      "message": "You have 2 vllm request(s) in-flight. Limit is 2 (vLLM pool: 2 GPU(s) x 1 slots). Retry in ~5s when an in-flight request completes.",
	      "limit_bucket": "vllm",
	      "current_inflight": 2,
	      "limit": 2,
	      "retry_after": 5
    }
  }
}
```

**Daily token quota** (PostgreSQL-backed, separate from TPM):
```bash
./scripts/apps/llmapi/manage-keys.sh create \
  --name "my-app" \
  --scopes "inference" \
  --tokens 1000000 \   # daily token quota
  --rpm 100            # requests per minute
```

**Resilience:** During an outage a request gets its answer within a few seconds, and no request waits on a store while it holds a slot.

| Outage | What happens |
|--------|--------------|
| Redis down, Postgres up | Auth and scopes come from Postgres, so requests work. RPM and TPM aren't enforced (fail open). The concurrency cap is, as it needs no store. |
| Postgres down, Redis up | Keys in the Redis cache keep working. The daily quota isn't enforced and those requests' usage isn't recorded. A key not in the cache gets a 503, not a 401, as it can't be checked. So do `/v1/usage` and admin endpoints that need Postgres, such as creating or revoking a key, or `/admin/stats`. |
| Both down | Every authenticated endpoint gets a 503 with `Retry-After`. Auth fails closed: nothing is authorized. |

`/health` uses neither store, so an outage doesn't restart the gateway.

## Configuration

Rate limiting defaults are set in the `gateway-config` ConfigMap (managed by the install script):

| Env Var | Default | Description |
|---------|---------|-------------|
| `DEFAULT_REQUESTS_PER_MINUTE` | `60` | RPM limit for new keys |
| `DEFAULT_TOKENS_PER_DAY` | `100000` | Daily token quota for new keys |
| `DEFAULT_TOKENS_PER_MINUTE` | `200000` | TPM limit for new keys |
| `MIN_TOKENS_PER_MINUTE` | `200000` | Runtime floor for any configured TPM below this value |
| `DEFAULT_EMBEDDING_REQUESTS_PER_MINUTE` | `60` | Separate embedding RPM limit for new keys |
| `DEFAULT_EMBEDDING_TOKENS_PER_MINUTE` | `200000` | Separate embedding TPM limit for new keys |
| `DEFAULT_LLAMACPP_REQUESTS_PER_MINUTE` | `60` | Separate llama.cpp RPM limit for new keys |
| `DEFAULT_LLAMACPP_TOKENS_PER_MINUTE` | `200000` | Separate llama.cpp TPM limit for new keys |
| `DEFAULT_OLLAMA_REQUESTS_PER_MINUTE` | `60` | Separate Ollama RPM limit for new keys |
| `DEFAULT_OLLAMA_TOKENS_PER_MINUTE` | `200000` | Separate Ollama TPM limit for new keys |
| `CONCURRENCY_PER_GPU` | `1` | Legacy name retained for docs/admin messages; vLLM per-key cap uses `CONCURRENCY_PER_KEY_DEFAULT x len(VLLM_URLS)` |
| `CONCURRENCY_PER_KEY_DEFAULT` | `1` | Per-key vLLM concurrency multiplier per configured vLLM URL |
| `CONCURRENCY_PER_EMBEDDING_REPLICA` | `4` | Per-key embedding concurrency |
| `CONCURRENCY_PER_LLAMACPP_REPLICA` | `1` | Per-key llama.cpp concurrency |
| `CONCURRENCY_PER_OLLAMA_REPLICA` | `1` | Per-key Ollama concurrency |
| `SLOT_RECONCILE_INTERVAL_SECONDS` | `5` | Reap leases whose owning `asyncio.Task` has ended |
| `CONCURRENCY_LEASE_TTL_SECONDS` | `600` | No effect. The limiter doesn't use it, and it can't make an older gateway work: see [Rolling back](#rolling-back) |
| `BACKEND_INFLIGHT_LEASE_TTL_SECONDS` | `600` | No effect. The limiter doesn't use it, and it can't make an older gateway work: see [Rolling back](#rolling-back) |
| `HORIZONTAL_SCALING` | `true` | Route to least-loaded backend that serves the requested model |
| `MAX_INFLIGHT_PER_VLLM_BACKEND` | `1` | Max simultaneous requests routed to each vLLM backend |
| `MAX_INFLIGHT_PER_EMBEDDING_BACKEND` | `4` | Max simultaneous requests routed to each embedding backend |
| `MAX_INFLIGHT_PER_LLAMACPP_BACKEND` | `1` | Max simultaneous requests routed to each llama.cpp backend |
| `MAX_INFLIGHT_PER_OLLAMA_BACKEND` | `1` | Max simultaneous requests routed to each Ollama backend |
| `MAX_INFLIGHT_PER_BACKEND` | `32` | Legacy fallback when a backend type has no specific cap |

Override at install time via environment variables or edit the ConfigMap directly:
```bash
kubectl edit configmap gateway-config -n llmapi
kubectl rollout restart deployment/gateway -n llmapi
```

Request limits and connections:

| Env Var | Default | Description |
|---------|---------|-------------|
| `MAX_REQUEST_BODY_BYTES` | `10485760` | Largest accepted request body. Larger ones get a 413 |
| `GGUF_MODEL_ALLOWED_HOSTS` | `huggingface.co,hf.co` | Hosts an admin-supplied GGUF URL may point at. The download sends the HuggingFace token to that URL, so keep this short |
| `REDIS_URL` | `redis://redis:6379/0` | Holds no credentials, because the gateway logs it |
| `REDIS_PASSWORD` | Empty | Set on the Deployment from Secret `llmapi-redis-auth`, key `password`. Not in `gateway-config` |

Outage and stream limits, in seconds:

| Env Var | Default | Description |
|---------|---------|-------------|
| `REDIS_CONNECT_TIMEOUT_SECONDS` | `2` | Connecting to Redis |
| `REDIS_OP_TIMEOUT_SECONDS` | `2` | One Redis operation |
| `REDIS_BULK_OP_TIMEOUT_SECONDS` | `30` | Redis operations that cover many keys |
| `POSTGRES_CONNECT_TIMEOUT_SECONDS` | `3` | Connecting to PostgreSQL |
| `POSTGRES_RECONNECT_TIMEOUT_SECONDS` | `10` | One whole reconnect: opening the pool and re-checking the schema |
| `POSTGRES_OP_TIMEOUT_SECONDS` | `5` | One PostgreSQL operation |
| `POSTGRES_BULK_OP_TIMEOUT_SECONDS` | `30` | Admin statistics, key sync and migrations, which can scan whole tables |
| `STORE_RECONNECT_MAX_BACKOFF_SECONDS` | `30` | Between reconnect attempts: starts at 1s and doubles up to this |
| `K8S_REQUEST_TIMEOUT_SECONDS` | `15` | Read timeout of one Kubernetes API call. The gateway gives up at twice this overall |
| `STREAM_CLIENT_STALL_TIMEOUT_SECONDS` | `300` | Ends a stream when one write to the client stays blocked this long. A slow client whose writes complete isn't affected. `0` disables it |
| `STREAM_MAX_DURATION_SECONDS` | `14400` | Last resort for a stream that keeps its slots however slowly it progresses. `0` disables it |

The gateway uses these defaults for any key missing from `gateway-config`. `upgrade-llmapi.sh` doesn't add keys to it, and re-running the installer adds new keys and keeps the existing values.

Embedding defaults are set in the `embedding-config` ConfigMap:

| Env Var | Default | Description |
|---------|---------|-------------|
| `CONTEXT_SIZE` | `8192` | Maximum embedding context window |
| `BATCH_SIZE` | `8192` | llama.cpp logical and physical eval batch; passed to both `--batch-size` and `--ubatch-size` so long chunks under the context limit are accepted |
| `THREADS` | `4` | CPU threads for embedding inference |

## Monitoring

Prometheus metrics are exposed at `/metrics` (requires `metrics` scope):

```bash
# Request rate by status (success, rate_limited, concurrency_exceeded, tpm_exceeded)
llmapi_requests_total{model="qwen3-14b", priority="normal", status="success", endpoint="chat"}

# Token usage
llmapi_tokens_total{model="qwen3-14b", direction="output"}

# Concurrency rejections (DDoS / burst protection)
llmapi_concurrency_rejected_total{endpoint="chat"}

# TPM rejections (token-rate protection)
llmapi_tpm_rejected_total{endpoint="chat"}

# Backend in-flight requests
llmapi_backend_requests_inflight{backend="vllm:http://vllm-0.vllm:8000"}

# Request duration histogram
llmapi_request_duration_seconds{model="qwen3-14b", endpoint="chat"}
```

**Live rate limiter state** (requires `metrics` scope):
```bash
curl -H "Authorization: Bearer $PROMETHEUS_KEY" \
     http://<loadbalancer-ip>/health/backends
# Returns: backends, inflight, rate_limiter.per_key_inflight,
#          rate_limiter.healthy_gpus, rate_limiter.concurrency_cap_per_key
```

**Reset this gateway process's limiter state** (requires `admin` scope):
```bash
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     http://<loadbalancer-ip>/admin/rate-limiter/reset
```

With multiple gateway replicas, roll the deployment to clear every process immediately:
```bash
kubectl rollout restart deployment/gateway -n llmapi
```

## Troubleshooting

```bash
# Check pod status
kubectl get pods -n llmapi

# View gateway logs
kubectl logs -n llmapi -l app=llmapi-gateway -f

# View vLLM logs
kubectl logs -n llmapi -l app=vllm -f

# Check backend health (metrics or admin scope)
curl -H "Authorization: Bearer $(cat ~/.mynodeone/llmapi-prometheus-key)" \
     http://<loadbalancer-ip>/health/backends

# Why a vLLM model download failed
kubectl logs -n llmapi vllm-0 -c model-downloader
```

### A connection hangs or times out inside the namespace

`manifests/networkpolicy.yaml` denies ingress to every pod in the namespace except for the traffic it lists. The gateway accepts any source on port 8000. Redis and Postgres accept the gateway, and Postgres also accepts pods labelled `app: llmapi-postgres-backup`. The backends accept only the gateway. Egress isn't restricted. A new pod that connects to one of these needs its own rule.

To back the policies out while you debug:

```bash
kubectl delete networkpolicy -n llmapi --all
```

`upgrade-llmapi.sh` applies them again, unless given `--skip-network-policy`. `--rollback` puts back the ones saved in its backup.

### vLLM CUDA Version Mismatch

If vLLM exits with an error like:

```text
RuntimeError: Unexpected error from cudaGetDeviceCount()
Error 803: system has unsupported display driver / cuda driver combination
```

first test whether Kubernetes GPU access works with a plain CUDA image. If that succeeds but vLLM fails, the vLLM image's bundled PyTorch CUDA runtime is likely incompatible with the node driver. The current default, `vllm/vllm-openai:v0.10.2`, was validated on the RTX 3090 nodes and should not be replaced by a newer tag until the new image passes the same smoke test.

## Uninstall

```bash
sudo ./scripts/apps/llmapi/uninstall-llmapi.sh
```
