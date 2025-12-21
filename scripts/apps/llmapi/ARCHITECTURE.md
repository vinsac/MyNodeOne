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

**Authentication:** HTTP Basic Auth
- **Username:** `admin` (or any username - only password is checked)
- **Password:** Generated during installation (shown at end of install script)

The password is stored in the gateway ConfigMap (`ADMIN_PASSWORD`). To reset it:
```bash
kubectl edit configmap gateway-config -n llmapi
# Change ADMIN_PASSWORD value, then restart gateway:
kubectl rollout restart deployment gateway -n llmapi
```

### Who can change backend settings?

| Endpoint | Access | Description |
|----------|--------|-------------|
| `/v1/*` | API key holders | Standard OpenAI-compatible API |
| `/admin/*` | Admin password only | Model management, config, keys |
| `/health/*` | Public | Health checks (no auth) |
| `/metrics` | Public | Prometheus metrics |

**Regular users** can only use the API with their API key. They **cannot** change models, context length, or other settings.

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

## API Design

### Authentication

```bash
# Header-based authentication (OpenAI-compatible)
curl -H "Authorization: Bearer sk-mynodeone-xxxx" \
     https://llmapi.cluster.local/v1/chat/completions
```

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

## Security

### API Key Management
```bash
# Create API key with quota
./scripts/apps/llmapi/manage-keys.sh create \
  --name "my-app" \
  --quota-tokens 1000000 \
  --rate-limit 100/min

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

# Create an API key for your app
./scripts/apps/llmapi/manage-keys.sh create --name "my-app"

# Test the API
curl -H "Authorization: Bearer $API_KEY" \
     http://llmapi.cluster.local/v1/models

# Monitor status
./scripts/apps/llmapi/monitor-llmapi.sh
```
