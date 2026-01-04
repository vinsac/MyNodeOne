# LLM API Service Architecture

A production-ready, self-hosted LLM API platform for MyNodeOne that provides OpenAI-compatible endpoints with intelligent load balancing, priority queuing, and multi-backend support.

---

## Quick Answers (FAQ)

### Where do models come from?

Models are downloaded from **HuggingFace** automatically when the service starts:

| Backend | Source | Format | Account Required? |
|---------|--------|--------|-------------------|
| vLLM | HuggingFace Hub | Transformers / AWQ / GPTQ | Only for gated models (Llama, etc.) |
| llama.cpp | HuggingFace (direct URL) | GGUF files | No |
| Embedding | HuggingFace (direct URL) | GGUF files | No |

**HuggingFace Account:**
- **Not required** for most models (Qwen, Mistral, etc.)
- **Required** for gated models (Llama-3, some Code models)
- If using a gated model, create a free account at huggingface.co, accept the model license, then set `HF_TOKEN` in the deployment

### How does quantization work?

**We download pre-quantized models** - no quantization happens on the cluster:

```
Pre-quantized model options:
├── AWQ (vLLM)       → "Qwen/Qwen2.5-14B-Instruct-AWQ"     # 4-bit, good quality
├── GPTQ (vLLM)      → "TheBloke/Llama-2-13B-GPTQ"        # 4-bit, compatible
└── GGUF (llama.cpp) → "...Q4_K_M.gguf"                   # Q4=4-bit, Q8=8-bit
```

**Choosing quantization** (during installation):
- The install script offers preset models with appropriate quantization
- For custom models, choose the quantization level you want from HuggingFace

### What happens when a user requests an unavailable model?

The API returns a **404 error** with the list of available models:

```json
{
  "error": "Model 'deepseek-coder' is not currently loaded",
  "available_models": ["qwen2.5-14b", "embedding"],
  "hint": "Call GET /v1/models first to see available models"
}
```

**Best practice for apps:**
1. Call `GET /v1/models` on startup to discover available models
2. Use a model from the returned list in requests
3. Handle 404 gracefully (fallback to another model or queue)

### What does the API response look like?

Responses follow the **OpenAI API format** with an additional `system_fingerprint` field indicating which backend handled the request:

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1703123456,
  "model": "qwen2.5-14b",
  "system_fingerprint": "vllm",    // ← Backend that handled request
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 8,
    "total_tokens": 18
  }
}
```

**Possible `system_fingerprint` values:**
| Value | Meaning |
|-------|---------|
| `vllm` | Handled by GPU backend (fastest) |
| `llamacpp` | Handled by CPU backend (overflow) |
| `ollama` | Handled by Ollama (lazy-loaded) |
| `embedding` | Handled by embedding service |

**Streaming responses** also include `X-Backend` HTTP header with the same value.

### Can multiple apps use different models?

**Yes**, but with constraints:

| Scenario | Supported? | How |
|----------|------------|-----|
| App A uses Qwen, App B uses same Qwen | ✅ Yes | Same model, both use it |
| App A uses Qwen, App B uses Mistral | ⚠️ Partially | Only if both are loaded (needs 2 GPUs or one on CPU) |
| App wants a model not loaded | ❌ No | Returns 404, must query /v1/models first |

**Industry standard**: OpenAI, Anthropic, etc. expose multiple models simultaneously. For us:
- vLLM loads **one model per GPU** (optimal performance)
- To serve multiple chat models: add GPUs OR use llama.cpp for secondary models
- Embedding model is separate (runs on CPU)

### How do I access the Admin UI?

**URL:** `http://llmapi.<cluster>.local/admin`

**Authentication:** API Key with `admin` scope
- **Header:** `Authorization: Bearer sk-mynodeone-xxxx`
- **Admin Key:** Auto-generated during installation (saved to `~/.mynodeone/llmapi-admin-key`)

```bash
# Access admin UI
ADMIN_KEY=$(cat ~/.mynodeone/llmapi-admin-key)
curl -H "Authorization: Bearer $ADMIN_KEY" \
     http://llmapi.minicloud.local/admin
```

To create additional admin keys:
```bash
./scripts/apps/llmapi/manage-keys.sh create --name "admin-user" --scopes "admin"
```

### Who can change backend settings?

| Endpoint | Required Scope | Description |
|----------|---------------|-------------|
| `/v1/*` | `inference` | Standard OpenAI-compatible API |
| `/admin/*` | `admin` | Model management, config, keys |
| `/health` | Public | Basic health check (no auth) |
| `/health/backends` | `metrics` | Detailed backend health status |
| `/metrics` | `metrics` | Prometheus metrics |

**API Key Scopes:**
- **`inference`**: Access to LLM API (`/v1/*` endpoints) - default for user keys
- **`metrics`**: Access to monitoring endpoints (`/metrics`, `/health/backends`) - for Prometheus
- **`admin`**: Full administrative access - grants all permissions

**Regular users** with `inference` scope can only use the API. They **cannot** access admin endpoints or metrics.

### How do I change models as an admin?

**Everything is in the Web Admin UI** at `/admin`:

| Action | How | Downtime |
|--------|-----|----------|
| Change vLLM model | Enter HuggingFace model ID, click "Change Model" | ~10-30 min |
| Change llama.cpp model | Enter GGUF URL, click "Change Model" | ~5-15 min |
| Download Ollama model | Enter model name (e.g., `llama3.2`), click "Download" | None |
| Start/Stop llama.cpp | Click "Start/Stop" toggle | Immediate |
| Set HuggingFace token | Paste token, click "Save" | None |
| **Change context/memory** | Advanced Config section | Requires restart |

**Note:** vLLM and llama.cpp require pod restarts to change models OR configuration.

### Why is embedding separate from chat models?

**Industry standard** - OpenAI has separate `/v1/embeddings` endpoint because:

1. **Different output**: Embeddings return vectors, chat returns text
2. **Different models**: Embedding models are specialized and smaller
3. **Can cache**: Same input = same embedding (deterministic)
4. **Resource isolation**: Keeps GPU free for latency-sensitive chat

**Your use case** (skill extraction from articles):
- LLM analyzes articles → use `/v1/chat/completions` (GPU)
- Generate skill embeddings → use `/v1/embeddings` (CPU, fast for small inputs)

Embeddings on CPU is fine because:
- Embedding models are small (~300MB-1GB)
- Your skill names are short strings
- CPU can handle thousands of embeddings/minute

### How does horizontal scaling work?

**Automatic load balancing**: The gateway routes chat requests to the least-loaded backend.

**Request routing priority**:
1. **GPU instances first** (vLLM) - fastest response times
2. **CPU fallback** (llama.cpp) - when all GPUs are busy
3. **Ollama** - last resort for lazy-loaded models

```
Request → Gateway → Check vLLM load
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
     GPU 1 (vLLM)    GPU 2 (vLLM)    CPU (llama.cpp)
     [3 inflight]    [5 inflight]    [0 inflight]
         │               │               │
         └───────────────┴───────────────┘
                         │
              Route to least-loaded
              (GPU 1 in this example)
```

**Recommended setup**: Run the **same model** on both GPU and CPU for consistent responses:
- **GPU**: `Qwen2.5-14B-AWQ` (fast, default)
- **CPU**: `Qwen2.5-14B-Q4_K_M` (same model, GGUF format)

**Configuration**:
```yaml
HORIZONTAL_SCALING: "true"          # Enable load-based routing (default)
MAX_INFLIGHT_PER_BACKEND: "32"      # Requests before routing to next backend
```

### Can I download/switch models from the Admin UI?

**Yes!** The Admin UI (`/admin`) supports:

| Backend | Download | Change Model | Caching |
|---------|----------|--------------|--------|
| **vLLM** | Via HuggingFace ID | Yes (restarts pod) | No cache - downloads fresh each time |
| **llama.cpp** | Via GGUF URL | Yes (restarts pod) | No cache - downloads fresh each time |
| **Ollama** | Click "Download" | Automatic (lazy load) | ✅ Cached in 1TB PVC |

### What happens when I change a vLLM/llama.cpp model?

**The old model is effectively deleted:**

```
Current: vLLM running with Qwen-14B in GPU memory
    │
    ▼  [Admin UI: Change to Mistral-7B]
    │
Pod Restart Triggered
    │
    ├─ Old pod terminates → Qwen-14B freed from VRAM
    │
    └─ New pod starts → Downloads Mistral-7B from HuggingFace (~10-30 min)
                       → Loads into VRAM
```

**Key points:**
- vLLM/llama.cpp don't have persistent model caches
- Every model change re-downloads from HuggingFace
- Ollama models ARE cached on disk (1TB PVC)

### What happens to Ollama downloaded models?

Models are **cached persistently** on disk:
- Downloaded models stored in `/models` PVC (1TB PersistentVolumeClaim)
- Switching models doesn't delete old ones
- Can switch back instantly (no re-download)
- Admin can manually delete unused models to free space

### What if an app requests a model not loaded on GPU?

**Lazy loading via Ollama backend:**
1. App requests "llama3.2" (not on vLLM)
2. Gateway checks: Is it in Ollama cache?
3. If cached → Ollama loads it (GPU+RAM overflow as needed)
4. If not cached → Returns 404 with available models list
5. After 30 min idle → Ollama unloads model, frees VRAM/RAM

**Important:** There is NO automatic fallback between backends. vLLM models and Ollama models are separate. If you request a model, you must specify one that exists in the system.

### Does llama.cpp keep the model in memory all the time?

**Yes** - llama.cpp loads the model once and keeps it in RAM while the pod is running.

**Resource usage:**
- 70B Q4 model → ~40GB RAM constantly used
- No auto-offload when idle
- Model stays loaded until pod stops

**Solution:** Use the Admin UI to **Start/Stop** llama.cpp when not needed:

```
Admin UI → llama.cpp section → [Stop] button
    │
    ▼
Pod scales to 0 replicas → RAM freed (~40GB)
    │
    ▼ (later, when needed)
Admin UI → [Start] button → Pod starts, model reloads (2-5 min)
```

### When do I need a HuggingFace token?

**Only for gated models on vLLM:**

| Model | Token Required? |
|-------|----------------|
| Qwen, Mistral, Phi | ❌ No |
| Llama-3, CodeLlama | ✅ Yes |
| Gemma | ✅ Yes |
| Ollama models | ❌ No (uses Ollama registry) |

**How to set the token:**
1. Go to Admin UI (`/admin`)
2. Find "HuggingFace Token" section
3. Paste your `hf_xxxxx` token
4. Click "Save Token"
5. When you change vLLM to a gated model, the token will be used

### What is a "secondary model"?

A secondary model is any model NOT loaded on the primary vLLM backend:
- **Primary**: vLLM with your main production model (fast, GPU-optimized)
- **Secondary**: Ollama-managed models (flexible, can overflow to RAM)

Secondary models are **lazy-loaded** when requested - no manual loading needed.

### Can I change models via URL/API instead of SSH?

**Yes!** Admin API endpoints:

```bash
# List available models (cached + loaded)
GET /admin/models

# Download a new model from HuggingFace
POST /admin/models/download
{"model": "Qwen/Qwen2.5-7B-Instruct", "backend": "ollama"}

# Set active model for a backend
POST /admin/models/activate
{"model": "qwen2.5-7b", "backend": "ollama"}

# Set HuggingFace token (for gated models)
POST /admin/config
{"hf_token": "hf_xxxxx"}

# Delete a cached model
DELETE /admin/models/{model_name}
```

### Why not use VRAM→RAM overflow everywhere?

**vLLM limitation**: vLLM doesn't support partial GPU offloading (it's all-or-nothing).

**Solution**: We use Ollama for overflow scenarios because:
- Ollama supports `--num-gpu N` to control GPU layers
- Automatically spills to RAM when VRAM is full
- Slower than vLLM but more flexible

**Architecture:**
| Backend | GPU Overflow? | Use Case |
|---------|--------------|----------|
| vLLM | ❌ No | Production (fixed model, max speed) |
| Ollama | ✅ Yes | Experimentation (flexible, auto-overflow) |

---

## Quick Reference: Backend Comparison

| Feature | vLLM | llama.cpp | Ollama | Embedding |
|---------|------|-----------|--------|-----------|
| **Hardware** | GPU (24GB VRAM) | CPU (40-80GB RAM) | GPU+RAM (auto) | CPU (1-2GB RAM) |
| **Speed** | ⚡ Fastest | 🐢 Slower | 🚗 Medium | ⚡ Fast |
| **Routing Priority** | 1st (primary) | 2nd (overflow) | 3rd (fallback) | Dedicated |
| **Model Cache** | ❌ No | ❌ No | ✅ 1TB PVC | ❌ No |
| **Change Model** | Restart (10-30min) | Restart (5-15min) | Instant (lazy load) | Fixed |
| **Admin UI Control** | Change model | Start/Stop, Change | Download, Delete | None |
| **Default Model** | Qwen2.5-14B-AWQ | Qwen2.5-14B-Q4 | On-demand | bge-m3 |
| **Auto-unload when idle** | ❌ No | ❌ No | ✅ Yes (30min) | ❌ No |
| **Best for** | Production | Large models (70B+) | Experimentation | Embeddings |

---

## Context Length & Memory Management

### The OOM Problem

vLLM pre-allocates memory for the **KV cache** at startup based on `max_model_len` and `max_num_seqs`. If you set these too high, you get Out-Of-Memory (OOM) errors.

**KV Cache Memory Formula:**
```
kv_cache_memory ≈ 2 × num_layers × head_dim × num_heads × max_model_len × max_num_seqs × dtype_bytes
```

For a 14B AWQ model on RTX 3090 (24GB):
- Model weights: ~8GB
- Available for KV cache: ~14GB (with 90% utilization)
- Safe context: 16K tokens × 32 sequences
- Aggressive context: 24K tokens × 16 sequences

### Default Configuration (RTX 3090 + 256GB RAM)

| Backend | Context | GPU Memory | Batch | Quantization |
|---------|---------|------------|-------|--------------|
| **vLLM** | 16,384 | 90% | 32 | AWQ |
| **llama.cpp** | 32,768 | N/A (CPU) | 4096 | Q4_K_M |
| **Ollama** | Auto | Auto | Auto | Varies |

### Are context lengths auto-configured per model?

**No** - defaults are set at installation time and apply to all models. Recommended values by model size:

| Model Size | Recommended Context | Why |
|------------|---------------------|-----|
| 7B AWQ | 32,768 | Fits easily in 24GB |
| 14B AWQ | 16,384 | Safe default for 24GB |
| 34B AWQ | 8,192 | Tight fit in 24GB |
| 70B Q4 (llama.cpp) | 32,768 | 256GB RAM is plenty |

**To optimize for your specific model:**
1. Check model's native context length (e.g., Qwen supports 128K)
2. Calculate VRAM budget: `24GB × 0.9 - model_size`
3. Use Admin UI to set appropriate context length
4. If OOM occurs, reduce until stable

**Pro tip:** Start conservative (8K-16K), then increase if needed. It's easier to increase context than to debug OOM crashes.

### Configuring via Admin UI

Go to **Admin UI → Advanced: Backend Configuration**:

```
┌─────────────────────────────────────────────────────────────┐
│ Advanced: Backend Configuration          [Requires Restart] │
├─────────────────────────────────────────────────────────────┤
│ vLLM (GPU)                                                  │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐        │
│ │Context   │ │GPU Mem % │ │Batch Size│ │Quant     │        │
│ │[16384  ] │ │[90     ] │ │[32     ] │ │[AWQ   v] │        │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘        │
│                              [Apply vLLM Config (restarts)] │
├─────────────────────────────────────────────────────────────┤
│ llama.cpp (CPU)                                             │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐        │
│ │Context   │ │Batch     │ │Threads   │ │Parallel  │        │
│ │[32768  ] │ │[4096   ] │ │[16     ] │ │[4      ] │        │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘        │
│                          [Apply llama.cpp Config (restarts)]│
└─────────────────────────────────────────────────────────────┘
```

### When do context/memory settings take effect?

**At pod startup only** - NOT in real-time.

```
┌─────────────────────────────────────────────────────────────────┐
│  Timeline of Configuration Change                               │
├─────────────────────────────────────────────────────────────────┤
│  1. Admin changes context length in UI (16K → 32K)              │
│     ↓                                                           │
│  2. Gateway patches ConfigMap with new value                    │
│     ↓                                                           │
│  3. Gateway triggers pod rollout restart                        │
│     ↓                                                           │
│  4. Old pod terminates (current requests may fail)              │
│     ↓                                                           │
│  5. New pod starts with new config                              │
│     ↓                                                           │
│  6. vLLM pre-allocates KV cache based on new context length     │
│     ↓                                                           │
│  7. Model loads into VRAM (~5-30 minutes)                       │
│     ↓                                                           │
│  8. Service available with new settings                         │
└─────────────────────────────────────────────────────────────────┘
```

**Why not real-time?** vLLM pre-allocates the KV cache at startup. Changing context length would require reallocating VRAM, which means unloading and reloading the model anyway.

### Troubleshooting OOM

**If vLLM fails to start with OOM:**
1. Reduce `max_model_len` (try 8192)
2. Reduce `gpu_memory_utilization` (try 0.85)
3. Reduce `max_num_seqs` (try 16)
4. Enable `enforce_eager` (disable CUDA graphs)

**Industry Standard Approach:**
- Start with conservative defaults (8K-16K context)
- Users can request longer context via API (up to max_model_len)
- If request exceeds capacity, return 400 error with max allowed
- Monitor VRAM usage and adjust config as needed

### Quantization Options

| Method | Bits | Quality | VRAM Savings | Use When |
|--------|------|---------|--------------|----------|
| **none** (FP16) | 16 | Best | 0% | Small models (<7B) |
| **AWQ** | 4 | Very Good | ~75% | Default for 14B+ |
| **GPTQ** | 4 | Good | ~75% | Alternative to AWQ |

**Note:** Quantization must match the model format. An AWQ model requires `quantization=awq`.

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              LLMAPI Service                                       │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                         API Gateway (FastAPI)                                │ │
│  │                                                                              │ │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐ │ │
│  │   │  Auth &  │  │   Rate   │  │ Priority │  │  Usage   │  │    Load      │ │ │
│  │   │ API Keys │  │ Limiter  │  │  Queue   │  │ Metering │  │  Balancer    │ │ │
│  │   └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────────┘ │ │
│  │                                                                              │ │
│  │   OpenAI-Compatible Endpoints:                                               │ │
│  │   • POST /v1/chat/completions     (chat, autocomplete)                      │ │
│  │   • POST /v1/completions          (text completion)                          │ │
│  │   • POST /v1/embeddings           (vector embeddings)                        │ │
│  │   • GET  /v1/models               (list available models)                    │ │
│  │   • GET  /health                  (health check)                             │ │
│  │   • GET  /metrics                 (Prometheus metrics)                       │ │
│  └───────────────────────────────────┬──────────────────────────────────────────┘ │
│                                      │                                            │
│         ┌────────────────────────────┼────────────────────────────────┐          │
│         │                            │                                 │          │
│         ▼                            ▼                                 ▼          │
│  ┌─────────────────┐   ┌─────────────────────────┐   ┌──────────────────────┐   │
│  │    vLLM #1      │   │       vLLM #2           │   │   llama.cpp Server   │   │
│  │   (GPU: 3090)   │   │      (GPU: 3090)        │   │    (CPU/RAM Only)    │   │
│  │  Control Plane  │   │     Worker Node         │   │   Overflow Handler   │   │
│  │                 │   │                         │   │                      │   │
│  │  Models:        │   │  Models:                │   │  Models:             │   │
│  │  • Qwen2.5-14B  │   │  • Qwen2.5-14B (replica)│   │  • Llama3.1-70B-Q4   │   │
│  │  • Mistral-7B   │   │  • CodeLlama-34B        │   │  • Mistral-7B-Q8     │   │
│  └─────────────────┘   └─────────────────────────┘   └──────────────────────┘   │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                     Embedding Service (Dedicated)                            │ │
│  │                                                                              │ │
│  │   ┌─────────────────────────┐   ┌─────────────────────────────────────────┐ │ │
│  │   │   text-embedding-3      │   │  BGE-M3 / Nomic-Embed                   │ │ │
│  │   │   (via vLLM or TEI)     │   │  (via llama.cpp or TEI)                 │ │ │
│  │   └─────────────────────────┘   └─────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                            Redis (Queue + Cache)                             │ │
│  │   • Request queue with priorities (realtime, high, normal, low, batch)      │ │
│  │   • Response caching for repeated queries                                    │ │
│  │   • Rate limit counters per API key                                          │ │
│  │   • Usage token counters                                                     │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                          PostgreSQL (State Store)                            │ │
│  │   • API keys and quotas                                                      │ │
│  │   • Usage history and billing data                                           │ │
│  │   • Model configurations                                                     │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. API Gateway (FastAPI)

The central orchestration layer that handles all incoming requests.

**Features:**
- **OpenAI-Compatible API**: Drop-in replacement for OpenAI API clients
- **Rate Limiting**: Per-key limits (requests/min, tokens/day)
- **Priority Queue**: 5 priority levels for request scheduling
- **Load Balancing**: Intelligent routing to available backends
- **Usage Metering**: Token counting for quota enforcement
- **Health Monitoring**: Backend health checks and failover

**Priority Levels:**
| Priority | Use Case | Queue Behavior |
|----------|----------|----------------|
| `realtime` | Autocomplete, streaming chat | Immediate, preempts lower |
| `high` | Interactive chat sessions | Fast queue, <2s wait |
| `normal` | Standard API calls | Default queue |
| `low` | Batch processing | Deferred to idle time |
| `batch` | Bulk embeddings, document processing | Night/low-load scheduling |

### 2. vLLM Backends (GPU Inference)

High-performance GPU inference using vLLM with continuous batching.

**Why vLLM:**
- **Continuous Batching**: Handles 10-50x more concurrent requests than Ollama
- **PagedAttention**: 50% better VRAM efficiency
- **OpenAI-Compatible**: Native `/v1/chat/completions` endpoint
- **Quantization**: AWQ, GPTQ support for larger models on 24GB VRAM

**Deployment Strategy:**
- One vLLM instance per GPU
- Each instance can serve multiple models (with memory management)
- Horizontal scaling by adding GPU workers

### 3. llama.cpp Server (CPU/RAM Overflow)

CPU-based inference for overflow handling and large model support.

**Use Cases:**
- **Overflow**: When GPU backends are saturated
- **Large Models**: 70B+ models that need >24GB (offload to 256GB RAM)
- **Batch Jobs**: Low-priority tasks during peak GPU usage
- **Cost Optimization**: Use CPU for low-priority requests

**Configuration:**
- Uses `llama-server` (llama.cpp HTTP server)
- Supports GGUF quantized models
- Can partially offload to GPU (-ngl flag)

### 4. Embedding Service

Dedicated service for vector embeddings (document indexing, RAG, search).

**Supported Models:**
| Model | Dimensions | Use Case | Backend |
|-------|------------|----------|---------|
| `nomic-embed-text` | 768 | General purpose | llama.cpp |
| `bge-m3` | 1024 | Multilingual | llama.cpp |
| `text-embedding-3-small` | 1536 | OpenAI-compatible | vLLM |

### 5. Redis (Queue + Cache)

Central coordination for request queuing and caching.

**Responsibilities:**
- Priority queue management (BullMQ-style)
- Response caching (LRU with TTL)
- Rate limit counters
- Token usage counters
- Backend health status

### 6. PostgreSQL (State Store)

Persistent storage for configuration and usage data.

**Tables:**
- `api_keys`: Key management and quotas
- `usage_logs`: Per-request token usage
- `model_configs`: Model deployment configurations
- `rate_limits`: Custom rate limits per key

---

## Model Storage & Caching

### Overview

LLMAPI uses a multi-tier storage strategy optimized for different deployment scenarios:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Model Storage Architecture                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Development / Small Deployments (Current):                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ 1. Pre-download (hostPath)                               │  │
│  │    /var/lib/llmapi/models/vllm/                          │  │
│  │    └─ qwen2.5-14b-awq/  (~9GB)                           │  │
│  │                                                           │  │
│  │ 2. Init Container Detection                              │  │
│  │    ├─ Check PVC cache (previous runs)                    │  │
│  │    ├─ Check /predownload hostPath                        │  │
│  │    └─ Download from HuggingFace (fallback)               │  │
│  │                                                           │  │
│  │ 3. Per-Pod PVC Storage (Longhorn)                        │  │
│  │    models-vllm-0: 30Gi (RWO)                             │  │
│  │    models-vllm-1: 30Gi (RWO)                             │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Model Distribution Strategies (Worker Nodes):                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Option A: Sync from Control Plane (LAN optimized)        │  │
│  │ • Uses rsync over SSH (auto-heals permissions)           │  │
│  │ • Best for slow internet, fast LAN                       │  │
│  │                                                          │  │
│  │ Option B: Independent Download (Default)                 │  │
│  │ • Workers download directly from HuggingFace             │  │
│  │ • Best for robust, zero-dependency setup                 │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Production / Multi-Cluster (Recommended):                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ 1. S3-Compatible Object Storage (MinIO/S3/R2)            │  │
│  │    s3://llmapi-models/                                    │  │
│  │    ├─ vllm/qwen2.5-14b-awq/                              │  │
│  │    ├─ vllm/mistral-7b-instruct/                          │  │
│  │    └─ llamacpp/llama-3.1-70b-q4/                         │  │
│  │                                                           │  │
│  │ 2. Pre-download Job (CronJob)                            │  │
│  │    Runs daily to sync new models from HuggingFace        │  │
│  │    Downloads → S3 bucket → Available cluster-wide        │  │
│  │                                                           │  │
│  │ 3. Init Container (S3 → PVC)                             │  │
│  │    Downloads from S3 to pod-local PVC on first start     │  │
│  │    Much faster than HuggingFace (internal network)       │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Current Implementation: hostPath Pre-download

**How It Works:**

```bash
# 1. Pre-download models using parallel downloader
./scripts/apps/llmapi/download-models.sh

# Downloads to: /var/lib/llmapi/models/vllm/qwen2.5-14b-awq
#   - Uses parallel connections (up to 500 MB/s with hf_transfer)
#   - Downloads once, used by all pods on that node

# 2. Install LLMAPI
./scripts/apps/llmapi/install-llmapi.sh

# 3. vLLM init container runs:
#   a. Checks PVC cache: /models/hub/* (from previous pod)
#   b. Checks hostPath: /predownload/vllm/* (pre-downloaded)
#   c. If found → copies to PVC (~2 min startup)
#   d. If not found → downloads from HuggingFace (~5 min)
```

**Storage Flow:**

```
Host OS: /var/lib/llmapi/models/vllm/qwen2.5-14b-awq
            ↓ (mounted as hostPath)
Pod Init:  /predownload/vllm/qwen2.5-14b-awq
            ↓ (cp -r to PVC)
Pod Main:  /models/hub/qwen2.5-14b-awq (PVC)
            ↓ (vLLM loads from here)
GPU VRAM:  Model loaded and running
```

**Why hostPath?**

| Benefit | Explanation |
|---------|-------------|
| **Fast First Startup** | Copy from local disk (2 min) vs download from HuggingFace (5-10 min) |
| **Bandwidth Savings** | Download once per node, not once per pod |
| **Multi-Node Sync** | Can rsync models from control plane to workers via SSH |
| **Simple Setup** | No external dependencies (S3, NFS, etc.) |

**Security Considerations:**

The namespace uses `pod-security.kubernetes.io/enforce: privileged` to allow hostPath volumes. This is acceptable for development/small deployments because:

1. **Models are public data** - HuggingFace models, not private/sensitive
2. **Read-only mount** - Init container has read-only access to /predownload
3. **Cluster admin control** - Only admins have OS-level access
4. **Optimization tradeoff** - 3x faster startup (2 min vs 5 min) worth the relaxed policy
5. **Per-pod isolation** - Each vLLM pod still has its own isolated PVC for runtime

**Limitations:**

- ❌ Not suitable for multi-cluster deployments
- ❌ Requires manual model sync between nodes (via rsync/SSH)
- ❌ No central model registry
- ❌ hostPath bypasses Kubernetes storage abstractions

---

### Production Recommendation: S3 Object Storage

For production deployments, **use S3-compatible object storage** instead of hostPath:

**Architecture:**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: model-predownload-job
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: downloader
            image: python:3.11-slim
            command: ["/bin/bash", "-c"]
            args:
            - |
              # Install dependencies
              pip install huggingface_hub hf_transfer boto3
              
              # Download models from HuggingFace
              export HF_HUB_ENABLE_HF_TRANSFER=1
              python -c "
              from huggingface_hub import snapshot_download
              snapshot_download('Qwen/Qwen2.5-14B-Instruct-AWQ', 
                                cache_dir='/tmp/models')
              "
              
              # Upload to S3
              aws s3 sync /tmp/models/ s3://llmapi-models/vllm/qwen2.5-14b-awq/
            env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: access-key-id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: secret-access-key
```

**vLLM Init Container (S3 Version):**

```yaml
initContainers:
- name: model-downloader
  image: amazon/aws-cli:latest
  command: ["/bin/bash", "-c"]
  args:
  - |
    # Check PVC cache first
    if [ -d "/models/hub/qwen2.5-14b-awq" ]; then
      echo "✓ Model cached in PVC"
      exit 0
    fi
    
    # Download from S3 (much faster than HuggingFace)
    echo "Downloading from S3..."
    aws s3 sync s3://llmapi-models/vllm/qwen2.5-14b-awq/ \
                /models/hub/qwen2.5-14b-awq/ \
                --only-show-errors
    
    echo "✓ Model ready"
  volumeMounts:
  - name: models
    mountPath: /models
  env:
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: s3-credentials
        key: access-key-id
```

**Benefits of S3 Approach:**

| Benefit | Description |
|---------|-------------|
| **Centralized Storage** | Single source of truth for all models across clusters |
| **No hostPath Required** | PodSecurity baseline/restricted compliant |
| **Fast Internal Network** | S3 downloads over private network (~100-500 MB/s) |
| **Version Control** | S3 versioning for model rollbacks |
| **Cross-Cluster Sharing** | Same S3 bucket used by dev/staging/prod |
| **Automated Updates** | CronJob downloads new models automatically |
| **CDN Integration** | CloudFront/CDN for geo-distributed clusters |

**Recommended S3 Providers:**

| Provider | Use Case | Cost | Notes |
|----------|----------|------|-------|
| **MinIO (self-hosted)** | On-premise, full control | Hardware only | S3-compatible, runs in K8s |
| **Cloudflare R2** | Public cloud, no egress fees | $0.015/GB storage | Free egress, fast |
| **AWS S3** | Enterprise, full AWS integration | $0.023/GB + egress | Pay for bandwidth |
| **Backblaze B2** | Budget option | $0.005/GB storage | Cheap storage |

**Migration Path (hostPath → S3):**

```bash
# 1. Deploy MinIO in cluster
helm install minio minio/minio --set replicas=1,persistence.size=500Gi

# 2. Upload existing models to S3
aws s3 sync /var/lib/llmapi/models/vllm/ \
            s3://llmapi-models/vllm/ \
            --endpoint-url http://minio.default:9000

# 3. Update vllm.yaml to use S3 init container
# 4. Remove hostPath volume and PodSecurity privileged label
# 5. Deploy predownload CronJob for automated model updates
```

**Future Enhancement:**

For large-scale production, consider a **model registry service**:
- REST API for model discovery and versioning
- Automatic model pruning (delete unused models)
- Usage tracking (which models are accessed)
- A/B testing support (route % of traffic to different model versions)

---

## API Design

### Authentication

All endpoints (except `/health`) require API key authentication:

```bash
# Header-based authentication (OpenAI-compatible)
curl -H "Authorization: Bearer sk-mynodeone-xxxx" \
     https://llmapi.cluster.local/v1/chat/completions
```

**API Key Scopes:**

| Scope | Permissions | Use Case |
|-------|-------------|----------|
| `inference` | `/v1/*` endpoints only | Application API usage |
| `metrics` | `/metrics`, `/health/backends` | Prometheus monitoring |
| `admin` | All endpoints | Administrative access |

**Scope Enforcement:**
- Keys are restricted to their assigned scopes
- Admin scope grants all permissions (superuser)
- Attempting to access unauthorized endpoints returns `403 Forbidden` with scope details

### Request Priority

Priority is specified via header or parameter:

```bash
# Via header (recommended)
curl -H "X-Priority: high" \
     -H "Authorization: Bearer $API_KEY" \
     https://llmapi.cluster.local/v1/chat/completions

# Via parameter
curl https://llmapi.cluster.local/v1/chat/completions?priority=batch
```

### Endpoints

#### Chat Completions
```bash
POST /v1/chat/completions
{
  "model": "qwen2.5-14b",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": true,
  "max_tokens": 1000
}
```

#### Embeddings
```bash
POST /v1/embeddings
{
  "model": "nomic-embed-text",
  "input": ["Document 1 text", "Document 2 text"]
}
```

#### Models List
```bash
GET /v1/models
# Returns available models with their capabilities and current load
```

#### Usage/Quota Check
```bash
GET /v1/usage
# Returns current token usage and remaining quota for the API key
```

---

## Resource Planning

### Hardware Requirements

| Component | CPU | RAM | GPU | Storage |
|-----------|-----|-----|-----|---------|
| API Gateway | 2 | 4Gi | - | 1Gi |
| vLLM (per instance) | 4 | 16Gi | 1x 3090 | 100Gi |
| llama.cpp Server | 16 | 128Gi | - | 200Gi |
| Embedding Service | 2 | 8Gi | - | 50Gi |
| Redis | 1 | 2Gi | - | 10Gi |
| PostgreSQL | 1 | 2Gi | - | 20Gi |

### Model Memory Requirements (RTX 3090 - 24GB VRAM)

| Model | Quantization | VRAM | Notes |
|-------|--------------|------|-------|
| Qwen2.5-7B | FP16 | ~14GB | Fast, good quality |
| Qwen2.5-14B | AWQ-4bit | ~10GB | Best balance |
| Mistral-7B | FP16 | ~14GB | Fast inference |
| CodeLlama-34B | AWQ-4bit | ~20GB | Coding tasks |
| Llama3.1-70B | Q4_K_M | CPU+40GB | Requires llama.cpp |

---

## Request Flow

### Realtime Request (Autocomplete)
```
Client → Gateway → Rate Check → Queue (realtime) → vLLM → Response
         [<10ms]    [<5ms]       [immediate]      [streaming]
```

### Batch Request (Document Embeddings)
```
Client → Gateway → Rate Check → Queue (batch) → Wait for idle → llama.cpp → Response
         [<10ms]    [<5ms]       [queued]       [0-60min]       [batch]
```

### High-Load Scenario
```
Client → Gateway → Rate Check → Queue → vLLM full? → llama.cpp (overflow) → Response
                                       ↓ yes         ↓ also full
                                       └──────────── 429 Retry-After: Ns
```

---

## Scaling Strategy

### Current Setup (1 Control Plane)
- 1x vLLM on GPU (primary inference)
- 1x llama.cpp on CPU (overflow/large models)
- 1x Embedding service

### With Worker Node (2 GPUs total)
- 2x vLLM instances (one per GPU)
- Load balancing across both
- llama.cpp as overflow

### Future Scaling
- Add GPU workers → automatic vLLM instance deployment
- Add CPU-only workers → llama.cpp pool expansion
- Horizontal pod autoscaling based on queue depth

---

## Monitoring & Observability

### Prometheus Metrics
```
# Request metrics
llmapi_requests_total{model, priority, status}
llmapi_request_duration_seconds{model, priority}
llmapi_tokens_total{model, direction} # input/output

# Queue metrics
llmapi_queue_depth{priority}
llmapi_queue_wait_seconds{priority}

# Backend metrics
llmapi_backend_status{backend, model}
llmapi_backend_requests_inflight{backend}
llmapi_vram_utilization{backend}
```

### Health Endpoints
```bash
GET /health           # Gateway health
GET /health/backends  # All backend statuses
GET /health/vllm-1    # Specific backend
```

---

## Network Architecture

### Current Implementation: Tailscale Mesh Network

All node-to-node communication in MyNodeOne uses **Tailscale** (WireGuard-based mesh VPN):

```
┌─────────────────────────────────────────────────────────────────┐
│                     Network Communication Layer                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  All Traffic Routes Through Tailscale:                         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ 1. Kubernetes Control Plane ↔ Worker Nodes              │  │
│  │    • kubelet → kube-apiserver                            │  │
│  │    • All K8s cluster traffic                             │  │
│  │                                                           │  │
│  │ 2. Pod-to-Pod Communication (CNI)                        │  │
│  │    • Cross-node pod networking                           │  │
│  │    • Service mesh traffic                                │  │
│  │                                                           │  │
│  │ 3. Storage Replication (Longhorn)                        │  │
│  │    • PVC data synchronization between nodes              │  │
│  │    • Volume replication (default 3 replicas)             │  │
│  │                                                           │  │
│  │ 4. Management Operations (SSH)                           │  │
│  │    • Model sync via rsync                                │  │
│  │    • Administrative access                               │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Tailscale Network Properties:                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Protocol:  WireGuard (kernel-space, ChaCha20-Poly1305)   │  │
│  │ IP Range:  100.64.0.0/10 (CGNAT space)                   │  │
│  │ Routing:   Direct peer-to-peer when possible             │  │
│  │ Fallback:  DERP relay for NAT traversal                  │  │
│  │ Security:  End-to-end encrypted, key rotation            │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Performance Characteristics

**Current Throughput (Observed):**
- **Small transfers (<10 MB):** 5-10 MB/s
- **Large transfers (>1 GB):** 1-10 MB/s sustained
- **PVC writes (Longhorn):** 1-5 MB/s (replication overhead)

**Bottlenecks:**
1. **WireGuard single-core encryption:** Each tunnel limited to one CPU core
2. **Tailscale overhead:** Additional protocol layers
3. **Longhorn replication:** 3x write amplification for replicated volumes
4. **Network path:** Encryption/decryption at source and destination

**Comparison to Physical Networks:**

| Network Type | Typical Throughput | Encryption | Complexity |
|--------------|-------------------|------------|------------|
| **Tailscale (current)** | 1-10 MB/s | ✅ WireGuard | ✅ Zero config |
| **10 Gbps LAN** | 500-1200 MB/s | ❌ Plain text | ⚠️ Physical setup |
| **10 Gbps LAN + IPsec** | 200-400 MB/s | ✅ IPsec | ⚠️ Manual config |

### Why Tailscale for Production Clusters?

**Benefits:**
- ✅ **Works anywhere:** Nodes can be on different networks, locations, or cloud providers
- ✅ **Zero manual configuration:** Automatic mesh routing, NAT traversal
- ✅ **Secure by default:** End-to-end encryption, automatic key rotation
- ✅ **Split-brain resistant:** Central coordination via Tailscale control plane
- ✅ **Simple firewall rules:** Only outbound HTTPS needed

**Trade-offs:**
- ❌ **Limited throughput:** 10-100 MB/s vs. multi-GB/s on physical networks
- ❌ **CPU overhead:** Encryption consumes ~10-20% CPU per active connection
- ❌ **Not suitable for high-frequency storage:** Real-time databases, video streaming

**Acceptable for:**
- LLM inference workloads (model loaded once, then served)
- Occasional large file transfers (model updates, backups)
- Distributed control plane (control plane and workers in different locations)

**Not acceptable for:**
- High-frequency database replication
- Streaming large datasets continuously
- Latency-sensitive real-time applications

### Future Optimization Plans

**Problem:** Large file transfers (models, backups) are slow over Tailscale due to single-core encryption bottleneck.

**Planned Solutions:**

#### Option 1: Pre-encrypted Multi-stream Transfer Utility

Create a dedicated tool for large file transfers that:

1. **Encrypt at source using multiple CPU cores:**
   ```bash
   # Split file into chunks, encrypt in parallel
   split -b 100M model.safetensor /tmp/chunks/
   parallel -j $(nproc) openssl enc -aes-256-cbc -in {} -out {}.enc ::: /tmp/chunks/*
   ```

2. **Transfer over multiple Tailscale connections:**
   ```bash
   # Open parallel rsync streams (each gets own WireGuard tunnel)
   parallel -j 8 rsync {} remote:/dest/ ::: /tmp/chunks/*.enc
   ```

3. **Decrypt and reassemble at destination:**
   ```bash
   parallel -j $(nproc) openssl enc -d -aes-256-cbc -in {} -out {.} ::: /dest/chunks/*.enc
   cat /dest/chunks/* > model.safetensor
   ```

**Expected improvement:** 5-8x faster for multi-GB files on multi-core systems

#### Option 2: Direct Public Internet Transfer (Optional)

For nodes with public IPs, bypass Tailscale for large transfers:

1. **Temporary HTTP server with TLS:**
   ```bash
   # On source node
   python3 -m http.server --bind 0.0.0.0 8443 --cert cert.pem --key key.pem
   ```

2. **Parallel downloads:**
   ```bash
   # On destination
   aria2c -x 16 -s 16 https://source-ip:8443/model.safetensor
   ```

3. **Automatic fallback to Tailscale** if direct connection fails

**Expected improvement:** 10-50x faster (limited by internet bandwidth, not encryption)

#### Option 3: Background Asynchronous Sync

For non-urgent transfers (nightly model updates):

1. **Queue transfers during off-peak hours**
2. **Use lower-priority nice/ionice**
3. **Spread transfers over time** (throttled rsync)

**Trade-off:** Slower but doesn't impact user-facing workloads

### Implementation Status

| Feature | Status | ETA |
|---------|--------|-----|
| Tailscale mesh networking | ✅ Production | - |
| SSH permission auto-fix | ✅ Production | - |
| Multi-stream transfer utility | 📋 Planned | TBD |
| Direct public internet fallback | 📋 Planned | TBD |
| Background async sync scheduler | 📋 Planned | TBD |

**Note:** The current Tailscale implementation is intentionally kept as-is for stability and simplicity. Future optimizations will be additive (optional tools) rather than replacing the base network layer.

---

## Security

### API Key Management

**Three keys auto-generated during installation:**
1. **Admin Key** (`admin` scope) - saved to `~/.mynodeone/llmapi-admin-key`
2. **Prometheus Key** (`metrics` scope) - saved to `~/.mynodeone/llmapi-prometheus-key`
3. **Default Key** (`inference` scope) - saved to `~/.mynodeone/llmapi-key`

**Create additional keys:**
```bash
# Create inference key (for applications)
./scripts/apps/llmapi/manage-keys.sh create \
  --name "my-app" \
  --scopes "inference" \
  --tokens 1000000 \
  --rpm 100

# Create metrics key (for Prometheus)
./scripts/apps/llmapi/manage-keys.sh create \
  --name "prometheus" \
  --scopes "metrics"

# Create admin key (for management)
./scripts/apps/llmapi/manage-keys.sh create \
  --name "admin-user" \
  --scopes "admin"

# Create multi-scope key
./scripts/apps/llmapi/manage-keys.sh create \
  --name "power-user" \
  --scopes "inference,metrics"

# List keys
./scripts/apps/llmapi/manage-keys.sh list

# Revoke key
./scripts/apps/llmapi/manage-keys.sh revoke sk-mynodeone-xxxx
```

### Network Policies
- API Gateway exposed via LoadBalancer
- Backend services only accessible within cluster
- PostgreSQL/Redis internal only

---

## Files in This Directory

```
scripts/apps/llmapi/
├── ARCHITECTURE.md          # This document
├── README.md                 # Quick start guide
├── install-llmapi.sh         # Main installation script
├── manage-keys.sh            # API key management
├── manage-models.sh          # Model deployment management
├── monitor-llmapi.sh         # Status and monitoring
├── scale-backends.sh         # Scale vLLM/llama.cpp instances
├── uninstall-llmapi.sh       # Clean uninstall
├── gateway/                  # Gateway source code
│   ├── main.py               # FastAPI application with Admin UI
│   ├── Dockerfile
│   └── requirements.txt
└── manifests/
    ├── namespace.yaml        # Namespace definition
    ├── redis.yaml            # Redis deployment
    ├── gateway.yaml          # API Gateway deployment + ConfigMap
    ├── gateway-rbac.yaml     # RBAC for Admin UI model management
    ├── vllm.yaml             # vLLM StatefulSet (GPU)
    ├── llamacpp.yaml         # llama.cpp deployment (CPU)
    ├── embedding.yaml        # Embedding service
    └── ollama.yaml           # Ollama deployment (dynamic models, 1TB cache)
```

---

## Quick Start

```bash
# Install LLM API service
sudo ./scripts/apps/llmapi/install-llmapi.sh

# API keys are auto-generated during installation
# Admin key:      ~/.mynodeone/llmapi-admin-key
# Prometheus key: ~/.mynodeone/llmapi-prometheus-key
# Default key:    ~/.mynodeone/llmapi-key

# Create additional keys as needed
./scripts/apps/llmapi/manage-keys.sh create --name "my-app" --scopes "inference"

# Test the API
curl -H "Authorization: Bearer $API_KEY" \
     http://llmapi.cluster.local/v1/models

# Monitor status
./scripts/apps/llmapi/monitor-llmapi.sh
```
