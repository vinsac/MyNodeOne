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
# Get API Gateway endpoint
kubectl get svc -n llmapi llmapi-gateway

# Test with curl
curl http://<gateway-ip>:8000/v1/models \
  -H "Authorization: Bearer <your-api-key>"
```

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

**State storage:** API keys and usage logs are stored in PostgreSQL (`llmapi-postgres`). Redis is used only for request queues, caching, and rate-limit counters.

## Admin Interface

**Access:** `http://llmapi.cluster.local/admin`

**Authentication:** API key with `admin` scope
```bash
# Use auto-generated admin key
ADMIN_KEY=$(cat ~/.mynodeone/llmapi-admin-key)
curl -H "Authorization: Bearer $ADMIN_KEY" \
     http://llmapi.mynodeone.local/admin
```

**Features:**

| Feature | Description |
|---------|-------------|
| **Download Ollama Models** | Enter model name (e.g., `qwen3:14b`), click Download |
| **Change vLLM Model** | Enter HuggingFace model ID, triggers pod restart (~10-30 min) |
| **Change llama.cpp Model** | Enter GGUF URL, triggers pod restart (~5-15 min) |
| **Start/Stop llama.cpp** | Free RAM when not needed (model stays loaded otherwise) |
| **Set HuggingFace Token** | Required for gated models such as Llama on vLLM |
| **Manage API Keys** | Create, view, and revoke keys |
| **View Usage Stats** | Track token consumption per key |
| **Backend Status** | Check health of all 4 backends |

**No SSH required** - all model management via web UI.

## Default Models

| Model | Type | Backend | Purpose |
|-------|------|---------|---------|
| `Qwen3-14B-AWQ` | Chat | vLLM (GPU) | Primary - fast GPU inference |
| `Qwen3-14B-Q4` | Chat | llama.cpp (CPU) | Overflow - same model on CPU |
| `bge-m3` | Embedding | Dedicated | Document indexing |

**Same model on GPU and CPU**: Using the same model family ensures consistent responses regardless of which backend handles the request.

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

## Rate Limiting

The gateway enforces three layers of protection per API key, checked in order:

| Layer | Mechanism | Default | Configurable? |
|-------|-----------|---------|---------------|
| **1. Concurrency** | Max simultaneous in-flight requests | `1 × GPU count` | `CONCURRENCY_PER_GPU`, `CONCURRENCY_PER_KEY_DEFAULT` |
| **2. RPM** | Requests per minute (Redis sliding window) | `60 RPM` | `DEFAULT_REQUESTS_PER_MINUTE` (per-key via `manage-keys.sh`) |
| **3. TPM** | Tokens per minute (Redis sliding window) | `40,000 TPM` | `DEFAULT_TOKENS_PER_MINUTE` (per-key via `manage-keys.sh`) |

**All limits return HTTP 429 immediately** with a structured error body and accurate `Retry-After` header — the same pattern used by OpenAI, Anthropic, and Azure OpenAI. There is no server-side queuing (which would be a DDoS vector).

**Concurrency scales automatically with GPUs:**
- 1 GPU → cap = 1 concurrent request per key
- 2 GPUs → cap = 2 concurrent requests per key
- N GPUs → cap = N × 1 (override with `CONCURRENCY_PER_GPU`)

**Self-healing concurrency leases:** In-flight slots are tracked as timestamped leases, not permanent counters. If a handler crashes or a client disconnect edge case misses cleanup, the gateway prunes stale leases after `CONCURRENCY_LEASE_TTL_SECONDS` (default `600`) instead of blocking the key forever.

**429 error body format:**
```json
{
  "detail": {
    "error": {
      "type": "concurrency_limit_exceeded",
      "message": "You have 1 request in-flight. Limit is 1 (1 GPU × 1 slot). Retry in ~5s.",
      "current_inflight": 1,
      "limit": 1,
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

**Resilience:** All Redis-backed checks (RPM, TPM) **fail-open** — if Redis is unavailable, requests are allowed through. Only the in-process concurrency cap (no Redis dependency) remains enforced.

## Configuration

Rate limiting defaults are set in the `gateway-config` ConfigMap (managed by the install script):

| Env Var | Default | Description |
|---------|---------|-------------|
| `DEFAULT_REQUESTS_PER_MINUTE` | `60` | RPM limit for new keys |
| `DEFAULT_TOKENS_PER_DAY` | `100000` | Daily token quota for new keys |
| `DEFAULT_TOKENS_PER_MINUTE` | `40000` | TPM limit for new keys |
| `CONCURRENCY_PER_GPU` | `1` | Concurrency slots per healthy GPU |
| `CONCURRENCY_PER_KEY_DEFAULT` | `1` | Base concurrency when no GPUs detected |
| `CONCURRENCY_LEASE_TTL_SECONDS` | `600` | Max age before an in-flight slot is considered stale and pruned |
| `HORIZONTAL_SCALING` | `true` | Route to least-loaded backend |
| `MAX_INFLIGHT_PER_BACKEND` | `32` | Requests before routing to next backend |

Override at install time via environment variables or edit the ConfigMap directly:
```bash
kubectl edit configmap gateway-config -n llmapi
kubectl rollout restart deployment/gateway -n llmapi
```

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
     http://llmapi.cluster.local/health/backends
# Returns: backends, inflight, rate_limiter.per_key_inflight,
#          rate_limiter.healthy_gpus, rate_limiter.concurrency_cap_per_key
```

**Reset this gateway process's limiter state** (requires `admin` scope):
```bash
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     http://llmapi.cluster.local/admin/rate-limiter/reset
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

# Check backend health
curl http://llmapi.cluster.local/health/backends
```

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
