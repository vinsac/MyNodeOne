# LLM Chat - Local AI Chat Interface

Chat with AI models running locally on your infrastructure using Open WebUI and Ollama.

## What You Get

- 💬 ChatGPT-like interface for local AI models
- 🤖 Multiple AI models (Llama, Mistral, Qwen, etc.)
- 🔒 Complete privacy - everything runs locally
- 📝 Chat history saved locally
- 👥 Multi-user support with authentication
- 📦 Model management through web interface
- 🎨 Modern, responsive UI

## Installation

```bash
sudo ./scripts/apps/llm-chat/install-llm-chat.sh
```

During installation, you'll be asked:
- **Subdomain**: Choose a name like `chat`, `ai`, or `llm`
- **GPU Mode**: Use GPU acceleration or CPU-only (if GPU detected)
- **Storage Size**: How much space to allocate for models and chat history
- **Public Access**: Whether to access from anywhere or just your home network
- **Model Selection**: Which AI models to download

### GPU Acceleration

If you have an NVIDIA GPU, you'll be asked:
- **Option 1**: Use GPU for Ollama (faster, recommended for most users)
- **Option 2**: Use CPU only (reserve GPU for other apps like LLMAPI)

**Advanced users**: Choose CPU-only mode if you plan to run LLMAPI (which also uses GPU). This prevents GPU conflicts between applications.

## Access

### Local Access
```
http://chat.mynodeone.local
```
(Replace `chat` with your chosen subdomain and `mynodeone` with your cluster domain)

### First-Time Setup

1. Open the URL in your browser
2. Create an admin account (first user becomes admin)
3. Start chatting with AI models

## Available Models

The installer offers several pre-configured models:
- **Llama 3.1 8B** - Fast, general-purpose (recommended)
- **Qwen 2.5 14B** - Better reasoning, slower
- **Mistral 7B** - Good balance of speed and quality
- **Custom** - Download any model from Ollama library

## Storage

### Storage Selection During Installation

**Model Storage:**
- **50Gi** - Good for 2-3 small models (7B-8B)
- **100Gi** - Good for 4-5 models or larger models (recommended)
- **200Gi** - Good for many models or very large models (70B+)

**Chat History Storage:**
- **10Gi** - Good for thousands of conversations (recommended)
- **20Gi** - Good for extensive chat history

### Need More Storage?

```bash
sudo ./scripts/apps/llm-chat/expand-storage.sh
```

## Managing Models

### Download New Models

From the Open WebUI interface:
1. Click on your profile
2. Go to "Settings" → "Models"
3. Enter model name (e.g., `llama3.1:8b`)
4. Click "Pull Model"

### Delete Models

From the Open WebUI interface:
1. Go to "Settings" → "Models"
2. Find the model you want to remove
3. Click the delete icon

## Common Tasks

### Restart Services

```bash
kubectl rollout restart deployment/open-webui -n open-webui
kubectl rollout restart deployment/ollama -n ollama
```

### Check if Running

```bash
kubectl get pods -n open-webui
kubectl get pods -n ollama
```

## Access from Anywhere

To access the chat interface when you're away from home:

```bash
sudo ./scripts/operations/manage-app-visibility.sh
```

## Performance

### Slow Responses?

AI model performance depends on your hardware:
- **CPU-only**: Slower responses (30-60 seconds)
- **With GPU**: Much faster responses (2-5 seconds)

If you have an NVIDIA GPU, the installer will automatically detect and use it for acceleration.

## Problems?

### Models Not Loading

1. Check if Ollama is running:
   ```bash
   kubectl get pods -n ollama
   ```

2. Check Ollama logs:
   ```bash
   kubectl logs -n ollama deployment/ollama
   ```

### Can't Access Interface

Update your network settings:
```bash
sudo ./scripts/domains/sync-dns.sh
```

### Running Out of Storage

Expand your storage:
```bash
sudo ./scripts/apps/llm-chat/expand-storage.sh
```

Or delete unused models from the web interface.

## Uninstall

```bash
sudo ./scripts/apps/llm-chat/uninstall-llm-chat.sh
```

**WARNING:** This will delete all chat history and downloaded models!

## Need Help?

- Open WebUI Documentation: https://docs.openwebui.com
- Ollama Model Library: https://ollama.com/library