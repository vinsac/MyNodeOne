# LLM API Service

Self-hosted OpenAI-compatible LLM API for MyNodeOne infrastructure.

## Features

- ✅ **OpenAI-Compatible API** - Drop-in replacement for OpenAI clients
- ✅ **Multi-Backend** - vLLM (GPU), llama.cpp (CPU/RAM), dedicated embeddings
- ✅ **Priority Queue** - Realtime, high, normal, low, batch priorities
- ✅ **Rate Limiting** - Per-key request and token limits
- ✅ **Usage Metering** - Track tokens per API key for quotas
- ✅ **Load Balancing** - Automatic routing across backends
- ✅ **GPU + CPU** - Use GPU for fast inference, CPU for overflow/large models
- ✅ **Admin UI** - Web interface at `/admin` for key management and monitoring

## Quick Start

```bash
# Install the LLM API service
sudo ./scripts/apps/llmapi/install-llmapi.sh

# Create an API key
./scripts/apps/llmapi/manage-keys.sh create --name "my-app"

# Test the API
export LLMAPI_KEY="sk-mynodeone-xxxx"  # from above command
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

## Admin Interface

Access the admin UI at `http://llmapi.cluster.local/admin`:

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

| Model | Type | Backend | Best For |
|-------|------|---------|----------|
| `qwen2.5-14b` | Chat | vLLM (GPU) | General chat, coding |
| `llama-cpu` | Chat | llama.cpp (CPU) | Complex reasoning (70B on RAM) |
| `embedding` | Embedding | Dedicated | Document indexing |

Models are auto-discovered from backends. The actual model names depend on your configuration.

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed design.

```
                         ┌─────────────────┐
                         │   API Gateway   │
                         │  + Admin UI     │
                         │  (Rate Limit)   │
                         └────────┬────────┘
                                  │
     ┌─────────────┬──────────────┼──────────────┬─────────────┐
     ▼             ▼              ▼              ▼             ▼
┌─────────┐  ┌──────────┐  ┌───────────┐  ┌───────────┐  ┌────────┐
│  vLLM   │  │  Ollama  │  │ llama.cpp │  │ Embedding │  │ Redis  │
│  (GPU)  │  │ (Flex)   │  │   (CPU)   │  │  Service  │  │        │
│ Fixed   │  │ Dynamic  │  │ Start/Stop│  │           │  │ Queue  │
│ Model   │  │ Models   │  │ via Admin │  │           │  │ Cache  │
└─────────┘  └──────────┘  └───────────┘  └───────────┘  └────────┘
```

**Backends:**
- **vLLM**: Production GPU inference, fixed model, fastest
- **Ollama**: Dynamic model loading, auto-unload, 1TB cache
- **llama.cpp**: CPU/RAM for large models (70B+), start/stop via Admin
- **Embedding**: Dedicated service for vector embeddings

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
