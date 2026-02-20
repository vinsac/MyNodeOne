# LLM API Service

Self-hosted OpenAI-compatible LLM API for MyNodeOne infrastructure.

## Features

- ✅ **OpenAI-Compatible API** - Drop-in replacement for OpenAI clients
- ✅ **Horizontal Scaling** - Automatic routing: GPU1 → GPU2 → CPU (least-loaded first)
- ✅ **Multi-Backend** - vLLM (GPU), llama.cpp (CPU/RAM), dedicated embeddings
- ✅ **Priority Routing** - Realtime, high, normal, low, batch request priorities via `X-Priority` header
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
- **Example**: `models--Qwen--Qwen2.5-14B-Instruct-AWQ/snapshots/abc123/`

### llama.cpp Models (CPU Inference)
- **Location**: `/var/lib/llmapi/models/llamacpp/`
- **Format**: Single GGUF file per model
- **Download**: Uses `aria2c` or `wget` from HuggingFace URLs (~5-10 min for 70B)
- **Example**: `Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf`

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
│   ├── models--Qwen--Qwen2.5-14B-Instruct-AWQ/
│   │   ├── snapshots/abc123/
│   │   ├── blobs/
│   │   └── refs/main
│   └── hub/
├── llamacpp/                                       # Single GGUF file
│   └── Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf
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
    model="qwen2.5-14b",
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

### Priority Requests

```bash
# Autocomplete (realtime priority)
curl -H "Authorization: Bearer $API_KEY" \
     -H "X-Priority: realtime" \
     http://llmapi.cluster.local/v1/chat/completions

# Batch processing (low priority, runs during idle time)
curl -H "Authorization: Bearer $API_KEY" \
     -H "X-Priority: batch" \
     http://llmapi.cluster.local/v1/embeddings
```

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
| **Download Ollama Models** | Enter model name (e.g., `llama3.2`), click Download |
| **Change vLLM Model** | Enter HuggingFace model ID, triggers pod restart (~10-30 min) |
| **Change llama.cpp Model** | Enter GGUF URL, triggers pod restart (~5-15 min) |
| **Start/Stop llama.cpp** | Free RAM when not needed (model stays loaded otherwise) |
| **Set HuggingFace Token** | Required for gated models (Llama-3, CodeLlama) on vLLM |
| **Manage API Keys** | Create, view, and revoke keys |
| **View Usage Stats** | Track token consumption per key |
| **Backend Status** | Check health of all 4 backends |

**No SSH required** - all model management via web UI.

## Default Models

| Model | Type | Backend | Purpose |
|-------|------|---------|---------|
| `Qwen2.5-14B-AWQ` | Chat | vLLM (GPU) | Primary - fast GPU inference |
| `Qwen2.5-14B-Q4` | Chat | llama.cpp (CPU) | Overflow - same model on CPU |
| `bge-m3` | Embedding | Dedicated | Document indexing |

**Same model on GPU and CPU**: Using the same model family ensures consistent responses regardless of which backend handles the request.

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
./scripts/apps/llmapi/manage-models.sh add qwen2.5-7b
./scripts/apps/llmapi/manage-models.sh remove codellama-34b
```

## Rate Limiting

The gateway enforces three layers of protection per API key, checked in order:

| Layer | Mechanism | Default | Configurable? |
|-------|-----------|---------|---------------|
| **1. Concurrency** | Max simultaneous in-flight requests | `4 × GPU count` | `CONCURRENCY_PER_GPU`, `CONCURRENCY_PER_KEY_DEFAULT` |
| **2. RPM** | Requests per minute (Redis sliding window) | `60 RPM` | `DEFAULT_REQUESTS_PER_MINUTE` (per-key via `manage-keys.sh`) |
| **3. TPM** | Tokens per minute (Redis sliding window) | `40,000 TPM` | `DEFAULT_TOKENS_PER_MINUTE` (per-key via `manage-keys.sh`) |

**All limits return HTTP 429 immediately** with a structured error body and accurate `Retry-After` header — the same pattern used by OpenAI, Anthropic, and Azure OpenAI. There is no server-side queuing (which would be a DDoS vector).

**Concurrency scales automatically with GPUs:**
- 1 GPU → cap = 4 concurrent requests per key
- 2 GPUs → cap = 8 concurrent requests per key
- N GPUs → cap = N × 4 (override with `CONCURRENCY_PER_GPU`)

**429 error body format:**
```json
{
  "detail": {
    "error": {
      "type": "concurrency_limit_exceeded",
      "message": "You have 4 requests in-flight. Limit is 4 (1 GPU × 4 slots). Retry in ~5s.",
      "current_inflight": 4,
      "limit": 4,
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
| `CONCURRENCY_PER_GPU` | `4` | Concurrency slots per healthy GPU |
| `CONCURRENCY_PER_KEY_DEFAULT` | `4` | Base concurrency when no GPUs detected |
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
llmapi_requests_total{model="qwen2.5-14b", priority="normal", status="success", endpoint="chat"}

# Token usage
llmapi_tokens_total{model="qwen2.5-14b", direction="output"}

# Concurrency rejections (DDoS / burst protection)
llmapi_concurrency_rejected_total{endpoint="chat"}

# TPM rejections (token-rate protection)
llmapi_tpm_rejected_total{endpoint="chat"}

# Backend in-flight requests
llmapi_backend_requests_inflight{backend="vllm:http://vllm-0.vllm:8000"}

# Request duration histogram
llmapi_request_duration_seconds{model="qwen2.5-14b", endpoint="chat"}
```

**Live rate limiter state** (requires `metrics` scope):
```bash
curl -H "Authorization: Bearer $PROMETHEUS_KEY" \
     http://llmapi.cluster.local/health/backends
# Returns: backends, inflight, rate_limiter.per_key_inflight,
#          rate_limiter.healthy_gpus, rate_limiter.concurrency_cap_per_key
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

## Uninstall

```bash
sudo ./scripts/apps/llmapi/uninstall-llmapi.sh
```