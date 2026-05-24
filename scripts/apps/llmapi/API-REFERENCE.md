# LLM API - Complete API Reference

OpenAI-compatible API endpoints for MyNodeOne self-hosted LLM inference.

**Base URL:** `http://llmapi.cluster.local/v1`

---

## Authentication

All endpoints (except `/health`) require an API key via Bearer token:

```bash
Authorization: Bearer sk-mynodeone-xxxxxx
```

### API Key Scopes

API keys have specific scopes that control access:

| Scope | Endpoints | Purpose |
|-------|-----------|----------|
| `inference` | `/v1/*` | LLM API usage (chat, embeddings, models) |
| `metrics` | `/metrics`, `/health/backends` | Prometheus monitoring |
| `admin` | `/admin/*` | Full administrative access |

**Note:** The `admin` scope grants all permissions (includes `inference` + `metrics`).

**Scope Error Example:**
```json
{
  "detail": {
    "error": "Insufficient scope",
    "message": "API key lacks required scope: 'metrics'",
    "required_scope": "metrics",
    "available_scopes": ["inference"],
    "hint": "Request a new API key with appropriate scopes from your administrator"
  }
}
```

---

## Quick Start: Copy-Paste Examples

### 1. What models exist?

**List all available models:**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://llmapi.cluster.local/v1",
    api_key="sk-mynodeone-xxxxxx"
)

# List available models
models = client.models.list()
for model in models.data:
    print(f"{model.id} - Backend: {model.backend}")

# Output:
# qwen3-14b - Backend: vllm
# nomic-embed-text - Backend: embedding
```

**cURL:**
```bash
curl -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
     http://llmapi.cluster.local/v1/models
```

**Response:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "qwen3-14b",
      "object": "model",
      "created": 1703123456,
      "owned_by": "mynodeone",
      "backend": "vllm"
    },
    {
      "id": "nomic-embed-text",
      "object": "model",
      "created": 1703123456,
      "owned_by": "mynodeone",
      "backend": "embedding"
    }
  ]
}
```

---

### 2. How do I send a prompt?

**Basic chat completion:**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://llmapi.cluster.local/v1",
    api_key="sk-mynodeone-xxxxxx"
)

response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[
        {"role": "user", "content": "What is the capital of France?"}
    ]
)

print(response.choices[0].message.content)
# Output: The capital of France is Paris.
```

The default `qwen3-14b` vLLM backend starts with Qwen3 reasoning enabled. vLLM exposes parsed thinking text through its OpenAI-compatible reasoning fields when supported by the client, while `message.content` remains the final answer.

**cURL:**
```bash
curl -X POST http://llmapi.cluster.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

**Response:**
```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1703123456,
  "model": "qwen3-14b",
  "system_fingerprint": "vllm",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "The capital of France is Paris."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 15,
    "completion_tokens": 8,
    "total_tokens": 23
  }
}
```

---

### 3. How do I stream responses?

**Streaming chat (recommended for interactive applications):**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://llmapi.cluster.local/v1",
    api_key="sk-mynodeone-xxxxxx"
)

response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[
        {"role": "user", "content": "Write a haiku about coding"}
    ],
    stream=True  # ← Enable streaming
)

# Print tokens as they arrive
for chunk in response:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)

# Output (streamed):
# Code flows like water,
# Logic shapes the silent night,
# Bugs lurk in shadows.
```

**cURL (streaming):**
```bash
curl -X POST http://llmapi.cluster.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [{"role": "user", "content": "Write a haiku"}],
    "stream": true
  }'
```

**Streaming Response Format (Server-Sent Events):**
```
data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Code"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" flows"},"finish_reason":null}]}

data: [DONE]
```

**HTTP Headers in Streaming:**
```
X-Backend: vllm
Content-Type: text/event-stream
```

---

### 4. How do I control temperature, max_tokens, and other parameters?

**All supported parameters (OpenAI-compatible):**

```python
response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Explain quantum computing"}
    ],
    
    # Temperature: Controls randomness (0.0 - 2.0)
    # - 0.0 = deterministic, always same output
    # - 1.0 = balanced (default)
    # - 2.0 = very creative/random
    temperature=0.7,
    
    # Max tokens: Maximum length of response
    max_tokens=500,
    
    # Top P: Nucleus sampling (0.0 - 1.0)
    # Use temperature OR top_p, not both
    top_p=0.9,
    
    # Frequency penalty: Reduce repetition (-2.0 to 2.0)
    frequency_penalty=0.5,
    
    # Presence penalty: Encourage new topics (-2.0 to 2.0)
    presence_penalty=0.0,
    
    # Stop sequences: Stop generation when these appear
    stop=["END", "\n\n\n"],
    
    # Number of completions to generate
    n=1,
    
    # Streaming
    stream=False
)
```

**Parameter Guide:**

| Parameter | Type | Default | Range | Purpose |
|-----------|------|---------|-------|---------|
| `temperature` | float | 1.0 | 0.0 - 2.0 | Randomness (lower = more focused) |
| `max_tokens` | int | 2048 | 1 - 32768 | Maximum response length |
| `top_p` | float | 1.0 | 0.0 - 1.0 | Nucleus sampling (alternative to temp) |
| `frequency_penalty` | float | 0.0 | -2.0 - 2.0 | Penalize repeated tokens |
| `presence_penalty` | float | 0.0 | -2.0 - 2.0 | Encourage topic diversity |
| `stop` | list | null | - | Stop sequences |
| `n` | int | 1 | 1-10 | Number of completions |
| `stream` | bool | false | true/false | Stream response tokens |

**Example: Creative writing (high temperature):**
```python
response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[{"role": "user", "content": "Write a creative story"}],
    temperature=1.5,      # Higher = more creative
    max_tokens=1000,      # Longer response
    top_p=0.95           # Wide token selection
)
```

**Example: Code generation (low temperature):**
```python
response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[{"role": "user", "content": "Write a Python function to sort a list"}],
    temperature=0.2,      # Lower = more deterministic
    max_tokens=300,
    stop=["```"]         # Stop at code block end
)
```

**cURL with parameters:**
```bash
curl -X POST http://llmapi.cluster.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [{"role": "user", "content": "Explain AI"}],
    "temperature": 0.7,
    "max_tokens": 500,
    "top_p": 0.9,
    "frequency_penalty": 0.5
  }'
```

---

### 5. What do errors look like?

All errors follow this format:

```json
{
  "error": {
    "message": "Human-readable error description",
    "type": "error_type",
    "code": "error_code"
  },
  "status": 400
}
```

#### **401 Unauthorized - Missing or invalid API key**

```bash
curl http://llmapi.cluster.local/v1/chat/completions
```

**Response:**
```json
{
  "error": {
    "message": "Missing or invalid API key",
    "type": "authentication_error",
    "code": "invalid_api_key"
  },
  "status": 401
}
```

**Fix:** Include valid API key in `Authorization: Bearer` header

---

#### **401 Unauthorized - Missing or invalid API key**

```bash
curl http://llmapi.cluster.local/v1/chat/completions
# Missing Authorization header
```

```json
{
  "detail": "Missing Authorization header"
}
```

**Fix:** Include valid API key in `Authorization: Bearer` header

---

#### **403 Forbidden - Insufficient scope**

```bash
# Trying to access /metrics with inference-only key
curl -H "Authorization: Bearer sk-mynodeone-xxxx" \
     http://llmapi.cluster.local/metrics
```

```json
{
  "detail": {
    "error": "Insufficient scope",
    "message": "API key lacks required scope: 'metrics'",
    "required_scope": "metrics",
    "available_scopes": ["inference"],
    "hint": "Request a new API key with appropriate scopes from your administrator"
  }
}
```

**Fix:** Use an API key with the required scope, or request admin to create one

---

#### **404 Not Found - Model doesn't exist**

```python
response = client.chat.completions.create(
    model="gpt-4",  # ← Not available on this cluster
    messages=[{"role": "user", "content": "Hello"}]
)
```

**Response:**
```json
{
  "error": {
    "message": "Model 'gpt-4' is not currently loaded",
    "type": "model_not_found",
    "code": "model_not_found",
    "available_models": ["qwen3-14b", "nomic-embed-text"],
    "hint": "Call GET /v1/models first to see available models"
  },
  "status": 404
}
```

**Fix:** 
1. List available models: `client.models.list()`
2. Use a model from that list

---

#### **429 Too Many Requests - Rate limit exceeded**

The gateway enforces three independent rate limits per API key and per service pool. vLLM/GPU, embedding, llama.cpp, and Ollama traffic each use separate concurrency, RPM, and TPM buckets, so one backend class cannot consume another class's slots. Each limit returns a structured error body with an accurate `Retry-After` header.

---

**429 — Concurrency limit** (too many simultaneous requests from this key)

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

**HTTP Headers:**
```
Retry-After: 5
```

**Fix:** Wait ~5s for an in-flight request in the same `limit_bucket` to finish, then retry. vLLM limits scale with healthy GPU count. Embedding, llama.cpp, and Ollama limits scale separately with their healthy service replicas.

If `current_inflight` stays pinned while backends are idle, the gateway prunes stale per-key leases after `CONCURRENCY_LEASE_TTL_SECONDS` (default `600`) and stale backend leases after `BACKEND_INFLIGHT_LEASE_TTL_SECONDS` (default `600`). A background maintenance task runs this pruning even without new traffic. Admins can also clear the current gateway process immediately:

```bash
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     http://llmapi.cluster.local/admin/rate-limiter/reset
```

To reset one pool in the current gateway process:

```bash
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     -H "Content-Type: application/json" \
     -d '{"limit_bucket":"vllm","backend":"vllm"}' \
     http://llmapi.cluster.local/admin/rate-limiter/reset
```

---

**429 — RPM limit** (too many requests per minute)

```json
{
  "detail": {
    "error": {
      "type": "rate_limit_exceeded",
      "message": "Rate limit exceeded: 60 requests/minute. Retry in 42s.",
      "limit": 60,
      "retry_after": 42
    }
  }
}
```

**HTTP Headers:**
```
Retry-After: 42
```

**Fix:** Wait exactly `retry_after` seconds (the remaining time in the current 60s window), then retry. Use exponential backoff in your client.

---

**429 — TPM limit** (too many tokens per minute)

```json
{
  "detail": {
    "error": {
      "type": "tokens_per_minute_exceeded",
      "message": "Token rate limit exceeded: 40000 tokens/minute. Retry in 38s.",
      "limit": 40000,
      "estimated_prompt_tokens": 3200,
      "retry_after": 38
    }
  }
}
```

**Fix:** Wait `retry_after` seconds, or reduce prompt length / `max_tokens`.

---

**429 — Daily token quota** (total tokens for the day exhausted)

```json
{
  "detail": "Daily token quota exceeded"
}
```

**Fix:** Contact admin to increase your daily quota, or wait until the next calendar day.

---

**Client retry pattern (openai-python handles this automatically):**

```python
from openai import OpenAI, RateLimitError
import time

client = OpenAI(base_url="http://llmapi.cluster.local/v1", api_key="sk-...")

for attempt in range(5):
    try:
        response = client.chat.completions.create(
            model="qwen3-14b",
            messages=[{"role": "user", "content": "Hello"}]
        )
        break
    except RateLimitError as e:
        retry_after = int(e.response.headers.get("Retry-After", 5))
        print(f"Rate limited. Retrying in {retry_after}s...")
        time.sleep(retry_after)
```

---

#### **400 Bad Request - Invalid parameters**

**Example: Context length exceeded**

```python
response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[{"role": "user", "content": "..." * 10000}],  # ← Too long
    max_tokens=50000  # ← Exceeds model capacity
)
```

**Response:**
```json
{
  "error": {
    "message": "Requested tokens (55000) exceeds model maximum (16384)",
    "type": "invalid_request_error",
    "code": "context_length_exceeded",
    "max_tokens": 16384,
    "requested_tokens": 55000
  },
  "status": 400
}
```

**Fix:** Reduce prompt length or `max_tokens`

---

**Example: Invalid parameter value**

```bash
curl -X POST http://llmapi.cluster.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -d '{
    "model": "qwen3-14b",
    "messages": [],
    "temperature": 5.0
  }'
```

**Response:**
```json
{
  "error": {
    "message": "Invalid value for temperature: must be between 0.0 and 2.0",
    "type": "invalid_request_error",
    "code": "invalid_parameter"
  },
  "status": 400
}
```

---

#### **503 Service Unavailable - All backends busy**

**Response:**
```json
{
  "error": {
    "message": "All inference backends are currently busy. Please retry.",
    "type": "service_unavailable",
    "code": "backends_busy"
  },
  "status": 503,
  "retry_after": 5
}
```

**Fix:** 
- Retry after a few seconds
- Use lower priority (`X-Priority: low`)
- Contact admin to scale up backends

---

#### **500 Internal Server Error - Backend failure**

**Response:**
```json
{
  "error": {
    "message": "Internal server error during inference",
    "type": "internal_error",
    "code": "backend_error"
  },
  "status": 500
}
```

**Fix:** 
- Check backend health: `curl http://llmapi.cluster.local/health/backends`
- Check logs: `kubectl logs -n llmapi -l app=llmapi-gateway`
- Contact admin if persists

---

## Complete Error Code Reference

| Status | Error type | Cause | Retry-After | Fix |
|--------|-----------|-------|-------------|-----|
| **401** | `invalid_api_key` | Missing/invalid API key | — | Add valid `Authorization: Bearer` header |
| **403** | `insufficient_scope` | Key lacks required scope | — | Use key with correct scope |
| **404** | `model_not_found` | Requested model not loaded | — | Use `GET /v1/models` to list available |
| **429** | `concurrency_limit_exceeded` | Too many simultaneous requests from this key | ~5s | Wait for an in-flight request to complete |
| **429** | `rate_limit_exceeded` | RPM window exhausted | TTL of window (≤60s) | Wait `retry_after` seconds |
| **429** | `tokens_per_minute_exceeded` | TPM window exhausted | TTL of window (≤60s) | Wait `retry_after` seconds or shorten prompt |
| **429** | `daily_quota_exceeded` | Daily token quota used up | Until midnight | Contact admin to raise quota |
| **400** | `context_length_exceeded` | Prompt + max_tokens too large | — | Reduce prompt or max_tokens |
| **400** | `invalid_parameter` | Invalid parameter value | — | Check parameter ranges |
| **400** | `missing_messages` | Empty messages array | — | Provide at least one message |
| **503** | `backends_busy` | All backends at capacity | ~5s | Retry or use lower priority |
| **500** | `backend_error` | Inference backend failed | — | Check backend health, contact admin |

---

## Priority Tagging (`X-Priority`)

Tag requests with a priority level using the `X-Priority` header:

```bash
curl -X POST http://llmapi.cluster.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "X-Priority: high" \
  -d '{"model": "qwen3-14b", "messages": [...]}'
```

**Priority Levels:**

| Priority | Intended Use Case | Effect |
|----------|-------------------|--------|
| `realtime` | Autocomplete, instant chat | Accepted; tracked in metrics |
| `high` | Interactive applications | Accepted; tracked in metrics |
| `normal` | Standard API calls | **Default** |
| `low` | Background processing | Accepted; tracked in metrics |
| `batch` | Bulk operations | Accepted; tracked in metrics |

**Default:** If no `X-Priority` header (or an unrecognised value), uses `normal`.

**What priority does today:**
- The header is validated and normalised to one of the five levels above.
- The priority label is attached to every Prometheus metric for that request (`llmapi_requests_total{priority="high",...}`), so you can slice dashboards by priority.
- The `X-Priority` value is echoed back in the response header.

**What priority does NOT do (yet):**
- Requests are **not queued or reordered** — every request is forwarded to a backend immediately regardless of priority.
- There is no preemption, no idle-time scheduling for `batch`, and no latency differentiation between levels.
- Priority-based queue processing is planned but not yet implemented.

**Practical guidance:** Use `X-Priority` now to annotate your requests in metrics. When queue-based scheduling is added in a future release, your clients will automatically benefit without any code changes.

---

## Embeddings

**Generate embeddings for text:**

```python
response = client.embeddings.create(
    model="nomic-embed-text",
    input=[
        "The quick brown fox",
        "jumps over the lazy dog"
    ]
)

print(response.data[0].embedding)  # [0.123, -0.456, ...]
print(len(response.data[0].embedding))  # 768 dimensions
```

**cURL:**
```bash
curl -X POST http://llmapi.cluster.local/v1/embeddings \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nomic-embed-text",
    "input": ["Text to embed"]
  }'
```

**Response:**
```json
{
  "object": "list",
  "data": [
    {
      "object": "embedding",
      "embedding": [0.123, -0.456, 0.789, ...],  // 768 floats
      "index": 0
    }
  ],
  "model": "nomic-embed-text",
  "usage": {
    "prompt_tokens": 4,
    "total_tokens": 4
  }
}
```

---

## Best Practices

### 1. Always discover models first

```python
# ✅ Good: Check available models
models = client.models.list()
model_id = models.data[0].id

response = client.chat.completions.create(
    model=model_id,
    messages=[...]
)
```

```python
# ❌ Bad: Hardcode model name
response = client.chat.completions.create(
    model="gpt-4",  # May not exist!
    messages=[...]
)
```

### 2. Handle errors gracefully

```python
from openai import OpenAI, APIError, RateLimitError

client = OpenAI(base_url="...", api_key="...")

try:
    response = client.chat.completions.create(
        model="qwen3-14b",
        messages=[{"role": "user", "content": "Hello"}]
    )
except RateLimitError as e:
    print(f"Rate limited. Retry after {e.retry_after}s")
    time.sleep(e.retry_after)
except APIError as e:
    print(f"API error: {e.message}")
```

### 3. Use streaming for interactive apps

```python
# ✅ Good: Stream for real-time UI updates
response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[...],
    stream=True  # User sees response immediately
)
```

### 4. Set appropriate priorities

```python
# Autocomplete (needs immediate response)
response = client.chat.completions.create(
    model="qwen3-14b",
    messages=[...],
    max_tokens=50,  # Short response
    extra_headers={"X-Priority": "realtime"}
)

# Batch document processing (not urgent)
embeddings = client.embeddings.create(
    model="nomic-embed-text",
    input=documents,
    extra_headers={"X-Priority": "batch"}
)
```

### 5. Adjust temperature based on use case

```python
# Code generation: Low temperature (deterministic)
code = client.chat.completions.create(
    messages=[{"role": "user", "content": "Write a Python function"}],
    temperature=0.2
)

# Creative writing: High temperature (varied)
story = client.chat.completions.create(
    messages=[{"role": "user", "content": "Write a story"}],
    temperature=1.5
)
```

---

## Health Check

```bash
# Check all backends
curl http://llmapi.cluster.local/health/backends
```

**Response:**
```json
{
  "vllm": "healthy",
  "llamacpp": "healthy",
  "embedding": "healthy",
  "ollama": "not_running"
}
```

---

## Complete Example: Production-Ready Client

```python
from openai import OpenAI, APIError, RateLimitError
import time

class LLMAPIClient:
    def __init__(self, api_key: str):
        self.client = OpenAI(
            base_url="http://llmapi.cluster.local/v1",
            api_key=api_key
        )
        self.available_models = self._discover_models()
    
    def _discover_models(self):
        """Discover available models at startup"""
        models = self.client.models.list()
        return [m.id for m in models.data]
    
    def chat(self, prompt: str, temperature: float = 0.7, stream: bool = True):
        """Send chat completion with retry logic"""
        if not self.available_models:
            raise ValueError("No models available")
        
        max_retries = 3
        for attempt in range(max_retries):
            try:
                response = self.client.chat.completions.create(
                    model=self.available_models[0],  # Use first available
                    messages=[{"role": "user", "content": prompt}],
                    temperature=temperature,
                    stream=stream
                )
                return response
            
            except RateLimitError as e:
                if attempt < max_retries - 1:
                    print(f"Rate limited. Retrying in {e.retry_after}s...")
                    time.sleep(e.retry_after)
                else:
                    raise
            
            except APIError as e:
                if e.status_code == 404:
                    # Model removed, rediscover
                    self.available_models = self._discover_models()
                    if attempt < max_retries - 1:
                        continue
                raise

# Usage
client = LLMAPIClient(api_key="sk-mynodeone-xxxxxx")

# Streaming response
response = client.chat("Explain quantum computing", temperature=0.8)
for chunk in response:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

---

## Getting an API Key

**Auto-generated keys** (available after installation):
```bash
# Three keys are created automatically:
cat ~/.mynodeone/llmapi-key              # inference scope
cat ~/.mynodeone/llmapi-admin-key        # admin scope
cat ~/.mynodeone/llmapi-prometheus-key   # metrics scope
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

# Multi-scope key
./scripts/apps/llmapi/manage-keys.sh create \
  --name "power-user" \
  --scopes "inference,metrics"

# List all keys
./scripts/apps/llmapi/manage-keys.sh list
```

---

## Common cURL Issues

### Issue 1: "Field required" or Body Parsing Errors

**Error:**
```json
{"detail":[{"type":"missing","loc":["body"],"msg":"Field required","input":null}]}
```

**Cause:** Newline in Authorization header breaks the header, causing auth failure.

**Bad Example:**
```bash
curl -X POST http://llmapi.mynodeone.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx
"   # ← Newline before closing quote breaks the header!
```

**Fix:** Close quote immediately after token (no newline):
```bash
curl -X POST http://llmapi.mynodeone.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Hello"}]}'
```

**Why this happens:**
- Broken Authorization header → API can't authenticate
- Without auth, request fails validation early
- Error message mentions "body" but real issue is broken header

---

### Issue 2: "Permanent Redirect" on Public Domain

**Error:**
```
Permanent Redirect
```

**Cause:** Using `http://` instead of `https://` for public domain.

**Bad Example:**
```bash
curl -X POST http://llmapi.example.com/v1/chat/completions  # ← HTTP
```

**Fix:** Use `https://` for public domains:
```bash
curl -X POST https://llmapi.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Hello"}]}'
```

**Rule:**
- **Local domain** (`*.mynodeone.local`, `*.cluster.local`): Use `http://`
- **Public domain** (`*.yourdomain.com`): Use `https://`

---

### Issue 3: JSON Parsing Errors

**Error:**
```json
{"detail":"Invalid JSON in request body"}
```

**Cause:** Malformed JSON in `-d` data.

**Common mistakes:**
- Single quotes inside single-quoted JSON
- Unescaped quotes
- Missing commas

**Bad Example:**
```bash
curl -d '{"messages":[{"content":"It's working"}]}'  # ← Unescaped '
```

**Fix:** Escape quotes or use double-quoted JSON:
```bash
# Option 1: Escape single quotes
curl -d '{"messages":[{"content":"It'\''s working"}]}'

# Option 2: Use double quotes (escape them in shell)
curl -d "{\"messages\":[{\"content\":\"It's working\"}]}"

# Option 3: Use file
echo '{"messages":[{"content":"It'\''s working"}]}' > request.json
curl -d @request.json
```

---

### Issue 4: Empty Response

**Cause:** Missing `-H "Content-Type: application/json"`

**Fix:** Always include Content-Type header:
```bash
curl -X POST http://llmapi.mynodeone.local/v1/chat/completions \
  -H "Authorization: Bearer sk-mynodeone-xxxxxx" \
  -H "Content-Type: application/json" \  # ← Required!
  -d '{"model":"qwen3-14b","messages":[...]}'
```

---

### Working cURL Template

**Copy-paste this and replace the parts in `<...>`:**

```bash
# Local domain (HTTP)
curl -X POST http://llmapi.mynodeone.local/v1/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [
      {"role": "user", "content": "<YOUR_QUESTION>"}
    ]
  }'

# Public domain (HTTPS)
curl -X POST https://llmapi.<yourdomain>.com/v1/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [
      {"role": "user", "content": "<YOUR_QUESTION>"}
    ]
  }'
```

**Tips:**
- No newlines in header values
- Use `https://` for public domains
- Include `Content-Type: application/json`
- Escape quotes in JSON properly
- Use `-v` flag to see full request/response for debugging

---

## Summary

✅ **OpenAI-compatible** - Drop-in replacement for OpenAI Python SDK  
✅ **Predictable** - Standard request/response formats, clear error codes  
✅ **Well-documented** - Copy-paste examples for all operations  
✅ **Error clarity** - Detailed error messages with fix suggestions  
✅ **Production-ready** - Rate limiting, retries, health checks

**Questions?** Check [README.md](./README.md) for installation and [ARCHITECTURE.md](./ARCHITECTURE.md) for system design.
