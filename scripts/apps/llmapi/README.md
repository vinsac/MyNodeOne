# LLM API Service

Self-hosted OpenAI-compatible LLM API for MyNodeOne infrastructure.

## Features

- ✅ **OpenAI-Compatible API** - Drop-in replacement for OpenAI clients
- ✅ **Horizontal Scaling** - Automatic routing: GPU1 → GPU2 → CPU (least-loaded first)
- ✅ **Multi-Backend** - vLLM (GPU), llama.cpp (CPU/RAM), dedicated embeddings
- ✅ **Priority Queue** - Realtime, high, normal, low, batch priorities
- ✅ **Rate Limiting** - Per-key request and token limits
- ✅ **Usage Metering** - Track tokens per API key for quotas
- ✅ **Backend Transparency** - Response includes `system_fingerprint` showing which backend handled it
- ✅ **Admin UI** - Web interface at `/admin` for key management and monitoring
- ✅ **API Key Scopes** - Granular permissions: `inference`, `metrics`, `admin`
- ✅ **Auto-Generated Keys** - Admin, Prometheus, and default keys created during install

## Quick Start

### Step 1: Pre-Download Models (Recommended)

Large language models can be 10-50GB. Pre-downloading them ensures faster installation and avoids pod timeouts:

```bash
# Download all recommended models (vLLM, llama.cpp, embedding)
sudo ./scripts/apps/llmapi/download-models.sh --model all

# Or download specific models interactively
sudo ./scripts/apps/llmapi/download-models.sh
```

**Why pre-download?**
- Downloads use `hf_transfer` with parallel connections (up to 500 MB/s)
- Models are persisted in `/var/lib/llmapi/models/` and survive reinstalls
- vLLM startup time: ~2 min (with pre-download) vs ~5-10 min (download from HuggingFace)
- Downloads once per node, shared by all pods via hostPath mount
- Can resume interrupted downloads

**How it works:**
```
1. Pre-download script → /var/lib/llmapi/models/vllm/qwen2.5-14b-awq
2. Install creates pods with hostPath mount → /predownload/vllm/
3. Init container detects pre-downloaded model → copies to pod PVC (~2 min)
4. vLLM loads from PVC and starts serving
```

**For production deployments**, see [Model Storage Architecture](./ARCHITECTURE.md#model-storage--caching) for S3-based model distribution using MinIO/Cloudflare R2.

### Step 2: Install the Service

```bash
# Install the LLM API service (will use pre-downloaded models if available)
sudo ./scripts/apps/llmapi/install-llmapi.sh

# Three API keys are automatically generated:
# - Admin key:      ~/.mynodeone/llmapi-admin-key
# - Prometheus key: ~/.mynodeone/llmapi-prometheus-key  
# - Default key:    ~/.mynodeone/llmapi-key

# Test the API
export LLMAPI_KEY=$(cat ~/.mynodeone/llmapi-key)
curl -H "Authorization: Bearer $LLMAPI_KEY" \
     http://llmapi.cluster.local/v1/models
```

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

## Admin Interface

**Access:** `http://llmapi.cluster.local/admin`

**Authentication:** API key with `admin` scope
```bash
# Use auto-generated admin key
ADMIN_KEY=$(cat ~/.mynodeone/llmapi-admin-key)
curl -H "Authorization: Bearer $ADMIN_KEY" \
     http://llmapi.minicloud.local/admin
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
     └── Always runs: Redis (queue + cache)
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

## Configuration

Default quotas can be configured in the installation:

```bash
# During install
sudo ./scripts/apps/llmapi/install-llmapi.sh \
  --default-quota 1000000 \      # tokens per month
  --default-rate-limit 100       # requests per minute
```

## Monitoring

Prometheus metrics are exposed at `/metrics`:

```bash
# Request rate
llmapi_requests_total{model="qwen2.5-14b", priority="normal"}

# Token usage
llmapi_tokens_total{model="qwen2.5-14b", direction="output"}

# Queue depth
llmapi_queue_depth{priority="batch"}
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
