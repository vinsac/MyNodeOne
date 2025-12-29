"""
LLM API Gateway - OpenAI-compatible API with rate limiting, queuing, and load balancing.

This gateway provides:
- OpenAI-compatible /v1/* endpoints
- Priority-based request queuing
- Rate limiting per API key
- Token usage metering
- Load balancing across backends (vLLM, llama.cpp)
- Health monitoring
"""

import asyncio
import hashlib
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import AsyncGenerator, Optional

import httpx
import redis.asyncio as redis
from fastapi import FastAPI, HTTPException, Request, Header, Depends, Form
from fastapi.responses import StreamingResponse, JSONResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

class Config:
    # Redis connection
    REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
    
    # Backend URLs
    VLLM_URLS = os.getenv("VLLM_URLS", "http://vllm:8000").split(",")
    LLAMACPP_URL = os.getenv("LLAMACPP_URL", "http://llamacpp:8080")
    EMBEDDING_URL = os.getenv("EMBEDDING_URL", "http://embedding:8080")
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
    
    # Default rate limits
    DEFAULT_REQUESTS_PER_MINUTE = int(os.getenv("DEFAULT_REQUESTS_PER_MINUTE", "60"))
    DEFAULT_TOKENS_PER_DAY = int(os.getenv("DEFAULT_TOKENS_PER_DAY", "100000"))
    
    # Queue settings
    QUEUE_TIMEOUT_SECONDS = {
        "realtime": 5,
        "high": 30,
        "normal": 120,
        "low": 600,
        "batch": 3600,
    }
    
    # Admin password (set via env var for security)
    ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "admin")
    
    # Lazy loading settings
    LAZY_LOAD_ENABLED = os.getenv("LAZY_LOAD_ENABLED", "true").lower() == "true"
    LAZY_LOAD_BACKEND = os.getenv("LAZY_LOAD_BACKEND", "ollama")
    AUTO_DOWNLOAD = os.getenv("AUTO_DOWNLOAD", "false").lower() == "true"
    
    # Horizontal scaling: route chat requests to least-loaded backend
    # When enabled, any chat model request routes to: GPU1 → GPU2 → ... → CPU
    # This assumes all chat backends run equivalent models (e.g., all run Qwen2.5-14B)
    HORIZONTAL_SCALING = os.getenv("HORIZONTAL_SCALING", "true").lower() == "true"
    # Max concurrent requests per backend before routing to next
    MAX_INFLIGHT_PER_BACKEND = int(os.getenv("MAX_INFLIGHT_PER_BACKEND", "32"))
    
    # Model name aliases (map OpenAI names to our internal names)
    MODEL_ALIASES = {
        "gpt-4": "default",
        "gpt-3.5-turbo": "default",
        "text-embedding-ada-002": "embedding",
    }


config = Config()

# =============================================================================
# Model Registry - Tracks loaded models dynamically
# =============================================================================

class ModelRegistry:
    """
    Tracks which models are actually loaded on each backend.
    Models are discovered by querying backends, not hardcoded.
    Supports lazy loading via Ollama.
    """
    def __init__(self):
        # Loaded models: {model_name: {"backend": "vllm", "status": "ready", "info": {...}}}
        self.loaded_models: dict[str, dict] = {}
        # Cached models (downloaded but not loaded): {model_name: {"backend": "ollama", "size": "4.1GB"}}
        self.cached_models: dict[str, dict] = {}
        # Backend status
        self.backends: dict[str, dict] = {
            "vllm": {"url": config.VLLM_URLS[0] if config.VLLM_URLS else "", "status": "unknown", "models": []},
            "llamacpp": {"url": config.LLAMACPP_URL, "status": "unknown", "models": []},
            "embedding": {"url": config.EMBEDDING_URL, "status": "unknown", "models": []},
            "ollama": {"url": config.OLLAMA_URL, "status": "unknown", "models": [], "cached": []},
        }
    
    def get_model(self, model_name: str) -> Optional[dict]:
        """Get model info if loaded, or check if lazy-loadable."""
        # Check aliases first
        resolved = config.MODEL_ALIASES.get(model_name, model_name)
        if resolved == "default":
            # Return first available chat model (prefer vLLM for speed)
            for backend in ["vllm", "ollama", "llamacpp"]:
                for name, info in self.loaded_models.items():
                    if info.get("backend") == backend and info.get("status") == "ready":
                        return {"name": name, **info}
            return None
        if resolved == "embedding":
            # Return embedding model
            for name, info in self.loaded_models.items():
                if info.get("backend") == "embedding" and info.get("status") == "ready":
                    return {"name": name, **info}
            return None
        
        # Check loaded models
        if resolved in self.loaded_models:
            return {"name": resolved, **self.loaded_models[resolved]}
        
        # Check if model is cached in Ollama (can be lazy-loaded)
        if resolved in self.cached_models and config.LAZY_LOAD_ENABLED:
            return {
                "name": resolved, 
                "backend": "ollama",
                "status": "cached",
                "lazy_load": True,
                **self.cached_models[resolved]
            }
        
        return None
    
    def get_available_models(self) -> list[dict]:
        """Get list of available models (loaded + cached)."""
        models = []
        # Add loaded models
        for name, info in self.loaded_models.items():
            if info.get("status") == "ready":
                models.append({
                    "id": name,
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "mynodeone",
                    "backend": info.get("backend"),
                    "status": "loaded",
                })
        # Add cached (lazy-loadable) models
        if config.LAZY_LOAD_ENABLED:
            for name, info in self.cached_models.items():
                if name not in self.loaded_models:
                    models.append({
                        "id": name,
                        "object": "model",
                        "created": int(time.time()),
                        "owned_by": "mynodeone",
                        "backend": info.get("backend", "ollama"),
                        "status": "cached",
                        "size": info.get("size"),
                    })
        return models
    
    def update_cached_models(self, models: list[dict]):
        """Update list of cached models from Ollama."""
        self.cached_models = {}
        for model in models:
            name = model.get("name") or model.get("model", "")
            # Only remove :latest suffix (keep other tags like :1b, :7b, etc.)
            if name.endswith(":latest"):
                name = name[:-7]
            self.cached_models[name] = {
                "backend": "ollama",
                "size": model.get("size"),
                "modified_at": model.get("modified_at"),
                "details": model.get("details", {}),
            }
        self.backends["ollama"]["cached"] = list(self.cached_models.keys())
    
    def register_model(self, name: str, backend: str, status: str = "ready", info: dict = None):
        """Register a loaded model."""
        self.loaded_models[name] = {
            "backend": backend,
            "status": status,
            "info": info or {},
            "registered_at": datetime.utcnow().isoformat(),
        }
        if name not in self.backends[backend]["models"]:
            self.backends[backend]["models"].append(name)
        logger.info(f"Registered model: {name} on {backend}")
    
    def unregister_model(self, name: str):
        """Remove a model from registry."""
        if name in self.loaded_models:
            backend = self.loaded_models[name].get("backend")
            del self.loaded_models[name]
            if backend and name in self.backends[backend]["models"]:
                self.backends[backend]["models"].remove(name)
            logger.info(f"Unregistered model: {name}")
    
    def update_backend_status(self, backend: str, status: str):
        """Update backend status."""
        if backend in self.backends:
            self.backends[backend]["status"] = status


model_registry = ModelRegistry()

# =============================================================================
# Prometheus Metrics
# =============================================================================

REQUEST_COUNT = Counter(
    "llmapi_requests_total",
    "Total requests",
    ["model", "priority", "status", "endpoint"]
)

REQUEST_DURATION = Histogram(
    "llmapi_request_duration_seconds",
    "Request duration in seconds",
    ["model", "priority", "endpoint"],
    buckets=[0.1, 0.5, 1, 2, 5, 10, 30, 60, 120]
)

TOKENS_COUNT = Counter(
    "llmapi_tokens_total",
    "Total tokens processed",
    ["model", "direction"]  # direction: input, output
)

QUEUE_DEPTH = Gauge(
    "llmapi_queue_depth",
    "Current queue depth",
    ["priority"]
)

BACKEND_STATUS = Gauge(
    "llmapi_backend_status",
    "Backend health status (1=healthy, 0=unhealthy)",
    ["backend", "url"]
)

BACKEND_INFLIGHT = Gauge(
    "llmapi_backend_requests_inflight",
    "Current in-flight requests per backend",
    ["backend"]
)

# =============================================================================
# Pydantic Models
# =============================================================================

class Message(BaseModel):
    role: str
    content: str
    name: Optional[str] = None


class ChatCompletionRequest(BaseModel):
    model: str
    messages: list[Message]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 1024
    stream: Optional[bool] = False
    top_p: Optional[float] = 1.0
    frequency_penalty: Optional[float] = 0.0
    presence_penalty: Optional[float] = 0.0
    stop: Optional[list[str]] = None
    user: Optional[str] = None


class CompletionRequest(BaseModel):
    model: str
    prompt: str
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 1024
    stream: Optional[bool] = False
    top_p: Optional[float] = 1.0
    stop: Optional[list[str]] = None


class EmbeddingRequest(BaseModel):
    model: str
    input: str | list[str]
    encoding_format: Optional[str] = "float"


class UsageResponse(BaseModel):
    tokens_used_today: int
    tokens_limit_daily: int
    requests_used_minute: int
    requests_limit_minute: int
    quota_reset_at: str


# =============================================================================
# Redis Client
# =============================================================================

class RedisClient:
    def __init__(self):
        self.client: Optional[redis.Redis] = None
    
    async def connect(self):
        self.client = redis.from_url(config.REDIS_URL, decode_responses=True)
        logger.info(f"Connected to Redis at {config.REDIS_URL}")
    
    async def close(self):
        if self.client:
            await self.client.close()
    
    async def check_rate_limit(self, api_key: str, requests_per_minute: int) -> bool:
        """Check if request is within rate limit."""
        key = f"ratelimit:{api_key}:rpm"
        current = await self.client.get(key)
        if current and int(current) >= requests_per_minute:
            return False
        pipe = self.client.pipeline()
        pipe.incr(key)
        pipe.expire(key, 60)
        await pipe.execute()
        return True
    
    async def get_rate_limit_info(self, api_key: str) -> tuple[int, int]:
        """Get current rate limit usage."""
        rpm_key = f"ratelimit:{api_key}:rpm"
        current_rpm = await self.client.get(rpm_key) or 0
        ttl = await self.client.ttl(rpm_key)
        return int(current_rpm), max(0, ttl)
    
    async def add_token_usage(self, api_key: str, input_tokens: int, output_tokens: int):
        """Track token usage (daily and hourly)."""
        now = datetime.utcnow()
        today = now.strftime("%Y-%m-%d")
        hour = now.hour
        total_tokens = input_tokens + output_tokens
        
        key = f"tokens:{api_key}:{today}"
        hourly_key = f"hourly_tokens:{api_key}:{today}:{hour}"
        requests_key = f"requests:{api_key}:{today}"
        hourly_req_key = f"hourly:{api_key}:{today}:{hour}"
        
        pipe = self.client.pipeline()
        # Daily token tracking
        pipe.hincrby(key, "input", input_tokens)
        pipe.hincrby(key, "output", output_tokens)
        pipe.expire(key, 86400 * 7)  # Keep for 7 days
        # Hourly token tracking
        pipe.incrby(hourly_key, total_tokens)
        pipe.expire(hourly_key, 86400 * 2)  # Keep for 2 days
        # Daily request count
        pipe.incr(requests_key)
        pipe.expire(requests_key, 86400 * 7)
        # Hourly request count
        pipe.incr(hourly_req_key)
        pipe.expire(hourly_req_key, 86400 * 2)
        await pipe.execute()
    
    async def get_token_usage(self, api_key: str) -> tuple[int, int]:
        """Get today's token usage."""
        today = datetime.utcnow().strftime("%Y-%m-%d")
        key = f"tokens:{api_key}:{today}"
        usage = await self.client.hgetall(key)
        return int(usage.get("input", 0)), int(usage.get("output", 0))
    
    async def check_token_quota(self, api_key: str, daily_limit: int) -> bool:
        """Check if within daily token quota."""
        input_tokens, output_tokens = await self.get_token_usage(api_key)
        return (input_tokens + output_tokens) < daily_limit
    
    async def enqueue_request(self, priority: str, request_id: str, data: dict):
        """Add request to priority queue."""
        queue_key = f"queue:{priority}"
        await self.client.zadd(queue_key, {request_id: time.time()})
        await self.client.set(f"request:{request_id}", json.dumps(data), ex=3600)
        QUEUE_DEPTH.labels(priority=priority).inc()
    
    async def dequeue_request(self, priority: str) -> Optional[tuple[str, dict]]:
        """Get next request from queue."""
        queue_key = f"queue:{priority}"
        result = await self.client.zpopmin(queue_key)
        if result:
            request_id = result[0][0]
            data = await self.client.get(f"request:{request_id}")
            await self.client.delete(f"request:{request_id}")
            QUEUE_DEPTH.labels(priority=priority).dec()
            if data:
                return request_id, json.loads(data)
        return None
    
    async def cache_response(self, cache_key: str, response: str, ttl: int = 3600):
        """Cache a response."""
        await self.client.set(f"cache:{cache_key}", response, ex=ttl)
    
    async def get_cached_response(self, cache_key: str) -> Optional[str]:
        """Get cached response."""
        return await self.client.get(f"cache:{cache_key}")
    
    async def get_api_key_config(self, api_key: str) -> Optional[dict]:
        """Get API key configuration."""
        data = await self.client.get(f"apikey:{api_key}")
        if data:
            return json.loads(data)
        return None
    
    async def set_api_key_config(self, api_key: str, config: dict):
        """Set API key configuration."""
        await self.client.set(f"apikey:{api_key}", json.dumps(config))


redis_client = RedisClient()

# =============================================================================
# Backend Manager
# =============================================================================

class BackendManager:
    def __init__(self):
        self.http_client: Optional[httpx.AsyncClient] = None
        self.backend_health: dict[str, bool] = {}
        self.backend_inflight: dict[str, int] = {}
    
    async def start(self):
        self.http_client = httpx.AsyncClient(timeout=300.0)
        # Initialize health status
        for url in config.VLLM_URLS:
            self.backend_health[f"vllm:{url}"] = False
            self.backend_inflight[f"vllm:{url}"] = 0
        self.backend_health[f"llamacpp:{config.LLAMACPP_URL}"] = False
        self.backend_inflight[f"llamacpp:{config.LLAMACPP_URL}"] = 0
        self.backend_health[f"embedding:{config.EMBEDDING_URL}"] = False
        self.backend_inflight[f"embedding:{config.EMBEDDING_URL}"] = 0
        self.backend_health[f"ollama:{config.OLLAMA_URL}"] = False
        self.backend_inflight[f"ollama:{config.OLLAMA_URL}"] = 0
        # Initial health check and model discovery
        await self.health_check()
    
    async def stop(self):
        if self.http_client:
            await self.http_client.aclose()
    
    def get_backend_url(self, model: str) -> tuple[str, str]:
        """
        Get backend URL for a model using simple load-balanced routing.
        
        For chat models with HORIZONTAL_SCALING enabled:
          - Routes to least-loaded backend: GPU1 → GPU2 → ... → CPU
          - All chat backends are treated as equivalent (same model family)
        
        For embedding models:
          - Always routes to dedicated embedding service
        """
        model_info = model_registry.get_model(model)
        
        # Handle embedding requests - always go to embedding service
        if model_info and model_info.get("backend") == "embedding":
            return "embedding", config.EMBEDDING_URL
        
        # For chat models with horizontal scaling, route to least-loaded backend
        if config.HORIZONTAL_SCALING:
            return self._get_least_loaded_chat_backend()
        
        # Fallback: route based on model's registered backend
        if not model_info:
            # If model not found but we have healthy backends, try to route anyway
            return self._get_least_loaded_chat_backend()
        
        backend_type = model_info.get("backend")
        if backend_type == "vllm":
            return self._get_least_loaded_vllm()
        elif backend_type == "llamacpp":
            return "llamacpp", config.LLAMACPP_URL
        elif backend_type == "ollama":
            return "ollama", config.OLLAMA_URL
        else:
            return None, None
    
    def _get_least_loaded_chat_backend(self) -> tuple[str, str]:
        """
        Route to least-loaded chat backend.
        Priority: vLLM instances (GPU) → llama.cpp (CPU) → Ollama
        """
        best_backend = None
        best_url = None
        min_inflight = float("inf")
        
        # Check all vLLM instances (GPUs) first
        for url in config.VLLM_URLS:
            key = f"vllm:{url}"
            if self.backend_health.get(key, False):
                inflight = self.backend_inflight.get(key, 0)
                if inflight < min_inflight and inflight < config.MAX_INFLIGHT_PER_BACKEND:
                    min_inflight = inflight
                    best_backend = "vllm"
                    best_url = url
        
        # If all vLLM instances are busy, try llama.cpp (CPU)
        if best_backend is None or min_inflight >= config.MAX_INFLIGHT_PER_BACKEND:
            llamacpp_key = f"llamacpp:{config.LLAMACPP_URL}"
            if self.backend_health.get(llamacpp_key, False):
                inflight = self.backend_inflight.get(llamacpp_key, 0)
                if inflight < config.MAX_INFLIGHT_PER_BACKEND:
                    if best_backend is None or inflight < min_inflight:
                        min_inflight = inflight
                        best_backend = "llamacpp"
                        best_url = config.LLAMACPP_URL
        
        # Last resort: Ollama
        if best_backend is None:
            ollama_key = f"ollama:{config.OLLAMA_URL}"
            if self.backend_health.get(ollama_key, False):
                best_backend = "ollama"
                best_url = config.OLLAMA_URL
        
        if best_backend:
            logger.debug(f"Routing to {best_backend} ({best_url}), inflight={min_inflight}")
        
        return best_backend, best_url
    
    def _get_least_loaded_vllm(self) -> tuple[str, str]:
        """Get least-loaded vLLM instance."""
        best_url = config.VLLM_URLS[0] if config.VLLM_URLS else None
        min_inflight = float("inf")
        
        for url in config.VLLM_URLS:
            key = f"vllm:{url}"
            if self.backend_health.get(key, False):
                inflight = self.backend_inflight.get(key, 0)
                if inflight < min_inflight:
                    min_inflight = inflight
                    best_url = url
        
        return "vllm", best_url
    
    async def discover_models(self):
        """Query backends to discover loaded models."""
        # Discover vLLM models
        for url in config.VLLM_URLS:
            try:
                resp = await self.http_client.get(f"{url}/v1/models", timeout=10.0)
                if resp.status_code == 200:
                    data = resp.json()
                    for model in data.get("data", []):
                        model_id = model.get("id")
                        if model_id:
                            model_registry.register_model(model_id, "vllm", "ready", model)
                            logger.info(f"Discovered vLLM model: {model_id}")
            except Exception as e:
                logger.debug(f"Could not discover vLLM models from {url}: {e}")
        
        # Discover llama.cpp model (it serves one model)
        try:
            resp = await self.http_client.get(f"{config.LLAMACPP_URL}/health", timeout=5.0)
            if resp.status_code == 200:
                # llama.cpp doesn't have a models endpoint, use configured name or default
                model_name = os.getenv("LLAMACPP_MODEL_NAME", "llama-cpu")
                model_registry.register_model(model_name, "llamacpp", "ready")
                logger.info(f"Discovered llama.cpp model: {model_name}")
        except Exception as e:
            logger.debug(f"Could not discover llama.cpp models: {e}")
        
        # Discover embedding model
        try:
            resp = await self.http_client.get(f"{config.EMBEDDING_URL}/health", timeout=5.0)
            if resp.status_code == 200:
                model_name = os.getenv("EMBEDDING_MODEL_NAME", "embedding")
                model_registry.register_model(model_name, "embedding", "ready")
                logger.info(f"Discovered embedding model: {model_name}")
        except Exception as e:
            logger.debug(f"Could not discover embedding models: {e}")
        
        # Discover Ollama models (both loaded and cached)
        try:
            # Get list of all downloaded models
            resp = await self.http_client.get(f"{config.OLLAMA_URL}/api/tags", timeout=10.0)
            if resp.status_code == 200:
                data = resp.json()
                models = data.get("models", [])
                model_registry.update_cached_models(models)
                logger.info(f"Discovered {len(models)} Ollama cached models")
            
            # Check which models are currently loaded (have active sessions)
            ps_resp = await self.http_client.get(f"{config.OLLAMA_URL}/api/ps", timeout=5.0)
            if ps_resp.status_code == 200:
                ps_data = ps_resp.json()
                for model in ps_data.get("models", []):
                    model_name = model.get("name", "")
                    # Only strip :latest suffix, keep other tags
                    if model_name.endswith(":latest"):
                        model_name = model_name[:-7]
                    if model_name:
                        model_registry.register_model(model_name, "ollama", "ready", model)
                        logger.info(f"Discovered loaded Ollama model: {model_name}")
        except Exception as e:
            logger.debug(f"Could not discover Ollama models: {e}")
    
    async def load_ollama_model(self, model_name: str) -> bool:
        """Lazy-load a model in Ollama. Returns True if successful."""
        try:
            # Ollama loads models on first request, but we can pre-warm with a simple generate
            logger.info(f"Lazy-loading model {model_name} via Ollama...")
            resp = await self.http_client.post(
                f"{config.OLLAMA_URL}/api/generate",
                json={"model": model_name, "prompt": "", "stream": False},
                timeout=300.0  # Model loading can take a while
            )
            if resp.status_code == 200:
                model_registry.register_model(model_name, "ollama", "ready")
                logger.info(f"Successfully loaded model {model_name}")
                return True
            else:
                logger.error(f"Failed to load model {model_name}: {resp.status_code}")
                return False
        except Exception as e:
            logger.error(f"Error loading model {model_name}: {e}")
            return False
    
    async def pull_ollama_model(self, model_name: str) -> AsyncGenerator[str, None]:
        """Download a model from HuggingFace/Ollama registry. Yields progress."""
        try:
            async with self.http_client.stream(
                "POST",
                f"{config.OLLAMA_URL}/api/pull",
                json={"name": model_name, "stream": True},
                timeout=None  # Downloads can take a long time
            ) as response:
                async for line in response.aiter_lines():
                    if line:
                        yield line
        except Exception as e:
            yield json.dumps({"error": str(e)})
    
    async def health_check(self):
        """Check health of all backends and discover models."""
        for url in config.VLLM_URLS:
            try:
                resp = await self.http_client.get(f"{url}/health", timeout=5.0)
                healthy = resp.status_code == 200
            except Exception:
                healthy = False
            key = f"vllm:{url}"
            self.backend_health[key] = healthy
            BACKEND_STATUS.labels(backend="vllm", url=url).set(1 if healthy else 0)
            model_registry.update_backend_status("vllm", "healthy" if healthy else "unhealthy")
        
        # Check llama.cpp
        try:
            resp = await self.http_client.get(f"{config.LLAMACPP_URL}/health", timeout=5.0)
            healthy = resp.status_code == 200
        except Exception:
            healthy = False
        self.backend_health[f"llamacpp:{config.LLAMACPP_URL}"] = healthy
        BACKEND_STATUS.labels(backend="llamacpp", url=config.LLAMACPP_URL).set(1 if healthy else 0)
        model_registry.update_backend_status("llamacpp", "healthy" if healthy else "unhealthy")
        
        # Check embedding service
        try:
            resp = await self.http_client.get(f"{config.EMBEDDING_URL}/health", timeout=5.0)
            healthy = resp.status_code == 200
        except Exception:
            healthy = False
        self.backend_health[f"embedding:{config.EMBEDDING_URL}"] = healthy
        BACKEND_STATUS.labels(backend="embedding", url=config.EMBEDDING_URL).set(1 if healthy else 0)
        model_registry.update_backend_status("embedding", "healthy" if healthy else "unhealthy")
        
        # Check Ollama
        try:
            resp = await self.http_client.get(f"{config.OLLAMA_URL}/api/tags", timeout=5.0)
            healthy = resp.status_code == 200
        except Exception:
            healthy = False
        self.backend_health[f"ollama:{config.OLLAMA_URL}"] = healthy
        BACKEND_STATUS.labels(backend="ollama", url=config.OLLAMA_URL).set(1 if healthy else 0)
        model_registry.update_backend_status("ollama", "healthy" if healthy else "unhealthy")
        
        # Periodically rediscover models
        await self.discover_models()
    
    async def forward_request(
        self,
        method: str,
        endpoint: str,
        model: str,
        data: dict,
        stream: bool = False
    ) -> tuple[httpx.Response | AsyncGenerator, dict]:
        """
        Forward request to appropriate backend.
        Returns (response, backend_info) tuple.
        backend_info contains: backend_type, backend_url for response enrichment.
        """
        backend_type, url = self.get_backend_url(model)
        backend_key = f"{backend_type}:{url}"
        
        backend_info = {
            "backend": backend_type,
            "backend_url": url,
        }
        
        # Track in-flight requests
        self.backend_inflight[backend_key] = self.backend_inflight.get(backend_key, 0) + 1
        BACKEND_INFLIGHT.labels(backend=backend_type).inc()
        
        try:
            if stream:
                return self._stream_request(url, endpoint, data, backend_type, backend_key, backend_info), backend_info
            else:
                response = await self.http_client.request(
                    method,
                    f"{url}{endpoint}",
                    json=data,
                    timeout=300.0
                )
                return response, backend_info
        finally:
            if not stream:
                self.backend_inflight[backend_key] = max(0, self.backend_inflight.get(backend_key, 0) - 1)
                BACKEND_INFLIGHT.labels(backend=backend_type).dec()
    
    async def _stream_request(
        self,
        url: str,
        endpoint: str,
        data: dict,
        backend_type: str,
        backend_key: str,
        backend_info: dict
    ) -> AsyncGenerator[bytes, None]:
        """Stream response from backend, injecting backend info into SSE events."""
        import json as json_module
        try:
            async with self.http_client.stream(
                "POST",
                f"{url}{endpoint}",
                json=data,
                timeout=300.0
            ) as response:
                async for chunk in response.aiter_bytes():
                    # Inject backend info into SSE data events
                    chunk_str = chunk.decode('utf-8', errors='ignore')
                    if chunk_str.startswith('data: ') and not chunk_str.startswith('data: [DONE]'):
                        try:
                            # Parse the JSON, add backend info, re-serialize
                            json_str = chunk_str[6:].strip()
                            if json_str:
                                event_data = json_module.loads(json_str)
                                event_data["system_fingerprint"] = f"{backend_type}"
                                chunk = f"data: {json_module.dumps(event_data)}\n\n".encode()
                        except:
                            pass  # If parsing fails, send original chunk
                    yield chunk
        finally:
            self.backend_inflight[backend_key] = max(0, self.backend_inflight.get(backend_key, 0) - 1)
            BACKEND_INFLIGHT.labels(backend=backend_type).dec()


backend_manager = BackendManager()

# =============================================================================
# Authentication
# =============================================================================

async def get_api_key(authorization: str = Header(None)) -> str:
    """Extract and validate API key from Authorization header."""
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid Authorization format")
    
    api_key = authorization[7:]
    
    # Check if key exists in Redis
    key_config = await redis_client.get_api_key_config(api_key)
    if not key_config:
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    return api_key



async def require_scope(required_scope: str, api_key: str) -> str:
    """Verify API key has required scope."""
    key_config = await redis_client.get_api_key_config(api_key)
    if not key_config:
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    scopes = key_config.get("scopes", ["inference"])  # Default: inference only
    
    # Admin scope grants all permissions
    if "admin" in scopes:
        return api_key
    
    if required_scope not in scopes:
        raise HTTPException(
            status_code=403,
            detail={
                "error": "Insufficient scope",
                "message": f"API key lacks required scope: '{required_scope}'",
                "required_scope": required_scope,
                "available_scopes": scopes,
                "hint": "Request a new API key with appropriate scopes from your administrator"
            }
        )
    
    return api_key


async def get_priority(x_priority: str = Header(None)) -> str:
    """Get request priority from header."""
    valid_priorities = ["realtime", "high", "normal", "low", "batch"]
    if x_priority and x_priority.lower() in valid_priorities:
        return x_priority.lower()
    return "normal"


# =============================================================================
# FastAPI App
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup
    await redis_client.connect()
    await backend_manager.start()
    
    # Start background health check
    async def health_check_loop():
        while True:
            try:
                await backend_manager.health_check()
            except Exception as e:
                logger.error(f"Health check failed: {e}")
            await asyncio.sleep(30)
    
    health_task = asyncio.create_task(health_check_loop())
    
    yield
    
    # Shutdown
    health_task.cancel()
    await redis_client.close()
    await backend_manager.stop()


app = FastAPI(
    title="LLM API Gateway",
    description="OpenAI-compatible LLM API with rate limiting and load balancing",
    version="1.0.0",
    lifespan=lifespan
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# =============================================================================
# Endpoints
# =============================================================================

@app.api_route("/", methods=["GET", "HEAD"])
async def root():
    """Root endpoint - returns 200 OK for health checks and public access verification."""
    return {"status": "ok", "service": "llmapi", "version": "1.0.0"}


@app.get("/health")
async def health():
    """Health check endpoint - basic liveness check (public)."""
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}


@app.get("/health/backends")
async def health_backends(
    api_key: str = Depends(get_api_key)
):
    """Backend health status - requires \'metrics\' scope."""
    await require_scope("metrics", api_key)
    return {
        "backends": backend_manager.backend_health,
        "inflight": backend_manager.backend_inflight,
    }


@app.get("/metrics")
async def metrics(
    api_key: str = Depends(get_api_key)
):
    """Prometheus metrics endpoint - requires \'metrics\' scope."""
    await require_scope("metrics", api_key)
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/v1/models")
async def list_models(api_key: str = Depends(get_api_key)):
    """List available models - requires \'inference\' scope."""
    await require_scope("inference", api_key)
    models = model_registry.get_available_models()
    return {
        "object": "list",
        "data": models,
        "info": {
            "message": "These are the currently loaded models. Use the 'id' field in your requests.",
            "backends": model_registry.backends,
        }
    }


@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible chat completions endpoint - requires \'inference\' scope."""
    await require_scope("inference", api_key)
    start_time = time.time()
    
    # Resolve model - check if it exists
    model_info = model_registry.get_model(request.model)
    if not model_info:
        available = [m["id"] for m in model_registry.get_available_models()]
        raise HTTPException(
            status_code=404,
            detail={
                "error": f"Model '{request.model}' is not currently loaded or cached",
                "available_models": available,
                "hint": "Call GET /v1/models to see available models, or POST /admin/models/download to download new ones"
            }
        )
    
    # Handle lazy loading for cached models
    if model_info.get("lazy_load") and model_info.get("status") == "cached":
        logger.info(f"Lazy-loading cached model: {request.model}")
        success = await backend_manager.load_ollama_model(request.model)
        if not success:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": f"Failed to load model '{request.model}'",
                    "hint": "The model may be too large or Ollama may be unavailable"
                }
            )
        # Refresh model info after loading
        model_info = model_registry.get_model(request.model)
    
    model = model_info.get("name", request.model)
    
    # Get key config (use defaults if not found)
    key_config = await redis_client.get_api_key_config(api_key) or {
        "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
        "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
    }
    
    # Check rate limit
    if not await redis_client.check_rate_limit(api_key, key_config["requests_per_minute"]):
        REQUEST_COUNT.labels(model=model, priority=priority, status="rate_limited", endpoint="chat").inc()
        raise HTTPException(
            status_code=429,
            detail="Rate limit exceeded",
            headers={"Retry-After": "60"}
        )
    
    # Check token quota
    if not await redis_client.check_token_quota(api_key, key_config["tokens_per_day"]):
        REQUEST_COUNT.labels(model=model, priority=priority, status="quota_exceeded", endpoint="chat").inc()
        raise HTTPException(status_code=429, detail="Daily token quota exceeded")
    
    # Build request data - exclude None values to avoid backend parse errors
    data = {
        "model": model,
        "messages": [m.model_dump(exclude_none=True) for m in request.messages],
        "temperature": request.temperature,
        "max_tokens": request.max_tokens,
        "stream": request.stream,
        "top_p": request.top_p,
    }
    if request.stop:
        data["stop"] = request.stop
    
    try:
        if request.stream:
            # Streaming response - backend info is injected into SSE events
            stream_gen, backend_info = await backend_manager.forward_request(
                "POST", "/v1/chat/completions", model, data, stream=True
            )
            
            async def stream_generator():
                total_output_tokens = 0
                async for chunk in stream_gen:
                    yield chunk
                    # Rough token counting from SSE data
                    if b'"content":' in chunk:
                        total_output_tokens += 1
                
                # Track usage after streaming completes
                input_tokens = sum(len(m.content.split()) for m in request.messages) * 2  # Rough estimate
                await redis_client.add_token_usage(api_key, input_tokens, total_output_tokens)
                TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
                TOKENS_COUNT.labels(model=model, direction="output").inc(total_output_tokens)
            
            REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="chat").inc()
            return StreamingResponse(
                stream_generator(),
                media_type="text/event-stream",
                headers={
                    "X-Priority": priority,
                    "X-Backend": backend_info.get("backend", "unknown"),
                }
            )
        else:
            # Non-streaming response
            response, backend_info = await backend_manager.forward_request(
                "POST", "/v1/chat/completions", model, data
            )
            
            if response.status_code != 200:
                REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="chat").inc()
                raise HTTPException(status_code=response.status_code, detail=response.text)
            
            result = response.json()
            
            # Enrich response with backend info (OpenAI-compatible)
            result["system_fingerprint"] = backend_info.get("backend", "unknown")
            
            # Track token usage
            usage = result.get("usage", {})
            input_tokens = usage.get("prompt_tokens", 0)
            output_tokens = usage.get("completion_tokens", 0)
            await redis_client.add_token_usage(api_key, input_tokens, output_tokens)
            TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
            TOKENS_COUNT.labels(model=model, direction="output").inc(output_tokens)
            
            duration = time.time() - start_time
            REQUEST_DURATION.labels(model=model, priority=priority, endpoint="chat").observe(duration)
            REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="chat").inc()
            
            return result
    
    except httpx.HTTPError as e:
        REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="chat").inc()
        logger.error(f"Backend error: {e}")
        raise HTTPException(status_code=503, detail="Backend service unavailable")


@app.post("/v1/completions")
async def completions(
    request: CompletionRequest,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible completions endpoint."""
    start_time = time.time()
    model = config.MODEL_ALIASES.get(request.model, request.model)
    
    # Get key config
    key_config = await redis_client.get_api_key_config(api_key) or {
        "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
        "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
    }
    
    # Check rate limit
    if not await redis_client.check_rate_limit(api_key, key_config["requests_per_minute"]):
        REQUEST_COUNT.labels(model=model, priority=priority, status="rate_limited", endpoint="completions").inc()
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    
    data = {
        "model": model,
        "prompt": request.prompt,
        "temperature": request.temperature,
        "max_tokens": request.max_tokens,
        "stream": request.stream,
    }
    
    try:
        if request.stream:
            stream_gen, backend_info = await backend_manager.forward_request(
                "POST", "/v1/completions", model, data, stream=True
            )
            
            async def stream_generator():
                async for chunk in stream_gen:
                    yield chunk
            
            return StreamingResponse(
                stream_generator(),
                media_type="text/event-stream",
                headers={"X-Backend": backend_info.get("backend", "unknown")}
            )
        else:
            response, backend_info = await backend_manager.forward_request(
                "POST", "/v1/completions", model, data
            )
            
            if response.status_code != 200:
                raise HTTPException(status_code=response.status_code, detail=response.text)
            
            result = response.json()
            result["system_fingerprint"] = backend_info.get("backend", "unknown")
            
            duration = time.time() - start_time
            REQUEST_DURATION.labels(model=model, priority=priority, endpoint="completions").observe(duration)
            REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="completions").inc()
            
            return result
    
    except httpx.HTTPError as e:
        REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="completions").inc()
        raise HTTPException(status_code=503, detail="Backend service unavailable")


@app.post("/v1/embeddings")
async def embeddings(
    request: EmbeddingRequest,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible embeddings endpoint - requires \'inference\' scope."""
    await require_scope("inference", api_key)
    start_time = time.time()
    
    # Resolve model - check if it exists
    model_info = model_registry.get_model(request.model)
    if not model_info:
        available = [m["id"] for m in model_registry.get_available_models() if m.get("backend") == "embedding"]
        raise HTTPException(
            status_code=404,
            detail={
                "error": f"Embedding model '{request.model}' is not currently loaded",
                "available_models": available,
                "hint": "Call GET /v1/models first to see available models"
            }
        )
    
    model = model_info.get("name", request.model)
    
    # Get key config
    key_config = await redis_client.get_api_key_config(api_key) or {
        "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
        "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
    }
    
    # Check rate limit
    if not await redis_client.check_rate_limit(api_key, key_config["requests_per_minute"]):
        REQUEST_COUNT.labels(model=model, priority=priority, status="rate_limited", endpoint="embeddings").inc()
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    
    # Normalize input to list
    input_texts = request.input if isinstance(request.input, list) else [request.input]
    
    # Check cache for embeddings
    cache_hits = []
    cache_misses = []
    for i, text in enumerate(input_texts):
        cache_key = hashlib.md5(f"{model}:{text}".encode()).hexdigest()
        cached = await redis_client.get_cached_response(cache_key)
        if cached:
            cache_hits.append((i, json.loads(cached)))
        else:
            cache_misses.append((i, text))
    
    # Process cache misses
    backend_info = {"backend": "embedding"}
    if cache_misses:
        data = {
            "model": model,
            "input": [text for _, text in cache_misses],
        }
        
        try:
            response, backend_info = await backend_manager.forward_request(
                "POST", "/v1/embeddings", model, data
            )
            
            if response.status_code != 200:
                raise HTTPException(status_code=response.status_code, detail=response.text)
            
            result = response.json()
            
            # Cache new embeddings
            for (orig_idx, text), emb_data in zip(cache_misses, result.get("data", [])):
                cache_key = hashlib.md5(f"{model}:{text}".encode()).hexdigest()
                await redis_client.cache_response(cache_key, json.dumps(emb_data), ttl=86400)
                cache_hits.append((orig_idx, emb_data))
        
        except httpx.HTTPError as e:
            REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="embeddings").inc()
            raise HTTPException(status_code=503, detail="Backend service unavailable")
    
    # Sort by original index
    cache_hits.sort(key=lambda x: x[0])
    embeddings_data = [emb for _, emb in cache_hits]
    
    # Estimate token usage
    total_tokens = sum(len(text.split()) * 2 for text in input_texts)
    await redis_client.add_token_usage(api_key, total_tokens, 0)
    TOKENS_COUNT.labels(model=model, direction="input").inc(total_tokens)
    
    duration = time.time() - start_time
    REQUEST_DURATION.labels(model=model, priority=priority, endpoint="embeddings").observe(duration)
    REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="embeddings").inc()
    
    return {
        "object": "list",
        "data": embeddings_data,
        "model": model,
        "usage": {"prompt_tokens": total_tokens, "total_tokens": total_tokens}
    }


@app.get("/v1/usage")
async def get_usage(api_key: str = Depends(get_api_key)):
    """Get current usage for API key."""
    key_config = await redis_client.get_api_key_config(api_key) or {
        "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
        "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
    }
    
    input_tokens, output_tokens = await redis_client.get_token_usage(api_key)
    current_rpm, ttl = await redis_client.get_rate_limit_info(api_key)
    
    # Calculate reset time
    tomorrow = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    
    return UsageResponse(
        tokens_used_today=input_tokens + output_tokens,
        tokens_limit_daily=key_config["tokens_per_day"],
        requests_used_minute=current_rpm,
        requests_limit_minute=key_config["requests_per_minute"],
        quota_reset_at=tomorrow.isoformat() + "Z"
    )


# =============================================================================
# Admin UI and Endpoints
# =============================================================================

ADMIN_LOGIN_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LLM API Admin - Login</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
</head>
<body class="bg-gray-900 text-gray-100 min-h-screen flex items-center justify-center">
    <div class="max-w-md w-full mx-4">
        <div class="bg-gray-800 rounded-lg p-8 border border-gray-700 shadow-2xl">
            <div class="text-center mb-8">
                <div class="flex justify-center mb-4">
                    <i data-lucide="brain" class="w-16 h-16 text-purple-400"></i>
                </div>
                <h1 class="text-3xl font-bold text-white mb-2">LLM API Admin</h1>
                <p class="text-gray-400">Enter your admin API key to continue</p>
            </div>
            
            <form onsubmit="handleLogin(event)" class="space-y-4">
                <div>
                    <label for="api-key" class="block text-sm font-medium text-gray-300 mb-2">
                        Admin API Key
                    </label>
                    <input 
                        type="password" 
                        id="api-key" 
                        placeholder="sk-mynodeone-xxxxxxxxxxxxx"
                        class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-3 text-white placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                        required
                    />
                </div>
                
                <div id="error-message" class="hidden bg-red-900 border border-red-700 text-red-200 rounded-lg p-3 text-sm">
                </div>
                
                <button 
                    type="submit"
                    class="w-full bg-purple-600 hover:bg-purple-700 text-white font-semibold py-3 px-4 rounded-lg transition duration-200 flex items-center justify-center gap-2"
                >
                    <i data-lucide="log-in" class="w-5 h-5"></i>
                    Login to Admin Dashboard
                </button>
            </form>
            
            <div class="mt-6 p-4 bg-gray-700 rounded-lg">
                <p class="text-xs text-gray-400 mb-2">
                    <strong class="text-gray-300">Where to find your admin key:</strong>
                </p>
                <code class="text-xs text-green-400 block bg-gray-900 p-2 rounded mt-2">
                    cat ~/.mynodeone/llmapi-admin-key
                </code>
                <p class="text-xs text-gray-500 mt-2">Or use:</p>
                <code class="text-xs text-green-400 block bg-gray-900 p-2 rounded mt-1">
                    ./scripts/apps/llmapi/manage-keys.sh list
                </code>
            </div>
        </div>
        
        <p class="text-center text-gray-500 text-xs mt-6">
            Your API key is stored locally in your browser and never transmitted to any third party.
        </p>
    </div>

    <script>
        lucide.createIcons();
        
        async function handleLogin(event) {
            event.preventDefault();
            
            const apiKey = document.getElementById('api-key').value.trim();
            const errorDiv = document.getElementById('error-message');
            
            // Validate format
            if (!apiKey.startsWith('sk-mynodeone-')) {
                showError('Invalid API key format. Key must start with "sk-mynodeone-"');
                return;
            }
            
            // Test the API key by calling /admin/models
            try {
                const response = await fetch('/admin/models', {
                    headers: {
                        'Authorization': `Bearer ${apiKey}`
                    }
                });
                
                if (response.ok) {
                    // Key is valid, store it and redirect
                    localStorage.setItem('llmapi_admin_key', apiKey);
                    window.location.href = '/admin/dashboard';
                } else if (response.status === 403) {
                    const data = await response.json();
                    showError('This API key does not have admin scope. Please use an admin key.');
                } else if (response.status === 401) {
                    showError('Invalid API key. Please check your key and try again.');
                } else {
                    showError(`Authentication failed: ${response.status}`);
                }
            } catch (e) {
                showError('Failed to connect to API: ' + e.message);
            }
        }
        
        function showError(message) {
            const errorDiv = document.getElementById('error-message');
            errorDiv.textContent = message;
            errorDiv.classList.remove('hidden');
        }
        
        // Check if already logged in
        const storedKey = localStorage.getItem('llmapi_admin_key');
        if (storedKey) {
            // Verify the key is still valid
            fetch('/admin/models', {
                headers: { 'Authorization': `Bearer ${storedKey}` }
            }).then(resp => {
                if (resp.ok) {
                    window.location.href = '/admin/dashboard';
                } else {
                    localStorage.removeItem('llmapi_admin_key');
                }
            });
        }
    </script>
</body>
</html>
"""

ADMIN_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LLM API Admin</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
</head>
<body class="bg-gray-900 text-gray-100 min-h-screen">
    <div class="container mx-auto px-4 py-8 max-w-6xl">
        <header class="mb-8 flex items-start justify-between">
            <div>
                <h1 class="text-3xl font-bold text-white flex items-center gap-3">
                    <i data-lucide="brain" class="w-8 h-8 text-purple-400"></i>
                    LLM API Admin
                </h1>
                <p class="text-gray-400 mt-2">Manage models, API keys, and monitor usage</p>
            </div>
            <button onclick="logout()" class="bg-gray-700 hover:bg-gray-600 text-gray-300 px-4 py-2 rounded-lg flex items-center gap-2 transition">
                <i data-lucide="log-out" class="w-4 h-4"></i>
                Logout
            </button>
        </header>

        <!-- Status Cards -->
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
            <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
                <div class="flex items-center gap-2 mb-2">
                    <i data-lucide="cpu" class="w-5 h-5 text-green-400"></i>
                    <h3 class="font-semibold">vLLM (GPU)</h3>
                </div>
                <div id="vllm-status" class="text-sm text-gray-400">Checking...</div>
            </div>
            <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
                <div class="flex items-center gap-2 mb-2">
                    <i data-lucide="sparkles" class="w-5 h-5 text-purple-400"></i>
                    <h3 class="font-semibold">Ollama (Flex)</h3>
                </div>
                <div id="ollama-status" class="text-sm text-gray-400">Checking...</div>
            </div>
            <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
                <div class="flex items-center gap-2 mb-2">
                    <i data-lucide="hard-drive" class="w-5 h-5 text-blue-400"></i>
                    <h3 class="font-semibold">llama.cpp (CPU)</h3>
                </div>
                <div id="llamacpp-status" class="text-sm text-gray-400">Checking...</div>
            </div>
            <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
                <div class="flex items-center gap-2 mb-2">
                    <i data-lucide="binary" class="w-5 h-5 text-yellow-400"></i>
                    <h3 class="font-semibold">Embedding</h3>
                </div>
                <div id="embedding-status" class="text-sm text-gray-400">Checking...</div>
            </div>
        </div>

        <!-- Model Management -->
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700 mb-8">
            <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
                <i data-lucide="boxes" class="w-5 h-5 text-purple-400"></i>
                Model Management
            </h2>
            
            <!-- Section: Ollama (Flexible) -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-purple-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="sparkles" class="w-4 h-4 text-purple-400"></i>
                        Ollama (Flexible Backend)
                    </h3>
                    <a href="https://ollama.com/library" target="_blank" 
                       class="text-xs text-purple-400 hover:text-purple-300 flex items-center gap-1">
                        <i data-lucide="external-link" class="w-3 h-3"></i>
                        Browse Models
                    </a>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    Best for: Quick experimentation, smaller models, CPU/GPU flexible. Models are cached locally.
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="text" id="model-name" placeholder="Model name (e.g., llama3.2, qwen2.5:7b, mistral)" 
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500 col-span-2">
                    <button onclick="downloadModel()" 
                            class="bg-purple-600 hover:bg-purple-700 rounded px-4 py-2 text-sm font-medium transition flex items-center justify-center gap-2">
                        <i data-lucide="download" class="w-4 h-4"></i>
                        Download
                    </button>
                </div>
                <div id="download-progress" class="mt-3 hidden">
                    <div class="bg-gray-600 rounded-full h-2 overflow-hidden">
                        <div id="download-bar" class="bg-purple-500 h-full transition-all" style="width: 0%"></div>
                    </div>
                    <p id="download-status" class="text-xs text-gray-400 mt-1"></p>
                </div>
                <p class="text-xs text-gray-500 mt-2">
                    Popular: <code class="bg-gray-600 px-1 rounded">llama3.2</code> 
                    <code class="bg-gray-600 px-1 rounded">qwen2.5:7b</code>
                    <code class="bg-gray-600 px-1 rounded">mistral</code>
                    <code class="bg-gray-600 px-1 rounded">codellama</code>
                </p>
            </div>
            
            <!-- Section: vLLM (GPU) -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-green-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="cpu" class="w-4 h-4 text-green-400"></i>
                        vLLM (GPU - High Performance)
                    </h3>
                    <div class="flex items-center gap-2">
                        <span class="text-xs bg-red-900 text-red-300 px-2 py-1 rounded">~10-30 min to change</span>
                        <a href="https://huggingface.co/models?other=awq" target="_blank" 
                           class="text-xs text-green-400 hover:text-green-300 flex items-center gap-1">
                            <i data-lucide="external-link" class="w-3 h-3"></i>
                            Browse AWQ Models
                        </a>
                    </div>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    Best for: Production workloads, high throughput. Uses GPU VRAM. Requires AWQ/GPTQ quantized models for 24GB VRAM.
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="text" id="vllm-model" placeholder="HuggingFace model (e.g., Qwen/Qwen2.5-14B-Instruct-AWQ)" 
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-green-500 col-span-2">
                    <button onclick="changeVllmModel()" 
                            class="bg-green-700 hover:bg-green-600 rounded px-4 py-2 text-sm font-medium transition flex items-center justify-center gap-2">
                        <i data-lucide="refresh-cw" class="w-4 h-4"></i>
                        Change Model
                    </button>
                </div>
                <p id="vllm-current" class="text-xs text-gray-500 mt-2">Current: Loading...</p>
                <p class="text-xs text-gray-500 mt-1">
                    Recommended for 24GB VRAM: 
                    <code class="bg-gray-600 px-1 rounded">Qwen/Qwen2.5-14B-Instruct-AWQ</code>
                    <code class="bg-gray-600 px-1 rounded">TheBloke/Llama-2-13B-chat-AWQ</code>
                </p>
            </div>
            
            <!-- Section: llama.cpp (CPU) -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-blue-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="hard-drive" class="w-4 h-4 text-blue-400"></i>
                        llama.cpp (CPU - Large Models)
                    </h3>
                    <div class="flex items-center gap-3">
                        <span id="llamacpp-running" class="text-xs px-2 py-1 rounded bg-gray-600">Checking...</span>
                        <button onclick="toggleLlamacpp()" id="llamacpp-toggle"
                                class="text-xs bg-blue-700 hover:bg-blue-600 rounded px-3 py-1 transition">
                            Start/Stop
                        </button>
                        <a href="https://huggingface.co/models?library=gguf&sort=downloads" target="_blank" 
                           class="text-xs text-blue-400 hover:text-blue-300 flex items-center gap-1">
                            <i data-lucide="external-link" class="w-3 h-3"></i>
                            Browse GGUF Models
                        </a>
                    </div>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    Best for: 70B+ models that don't fit in GPU. Uses system RAM (~40GB for 70B). Stop when not in use to free memory.
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="text" id="llamacpp-model" placeholder="GGUF URL (e.g., https://huggingface.co/.../model.Q4_K_M.gguf)" 
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 col-span-2">
                    <button onclick="changeLlamacppModel()" 
                            class="bg-blue-700 hover:bg-blue-600 rounded px-4 py-2 text-sm font-medium transition flex items-center justify-center gap-2">
                        <i data-lucide="refresh-cw" class="w-4 h-4"></i>
                        Change Model
                    </button>
                </div>
                <p id="llamacpp-current" class="text-xs text-gray-500 mt-2">Current: Loading...</p>
                <p class="text-xs text-gray-500 mt-1">
                    Recommended for 256GB RAM: 
                    <code class="bg-gray-600 px-1 rounded text-xs">Llama-3.1-70B-Q4_K_M.gguf</code>
                    <code class="bg-gray-600 px-1 rounded text-xs">Qwen2.5-72B-Q4_K_M.gguf</code>
                </p>
            </div>
            
            <!-- Section: Embedding -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-yellow-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="binary" class="w-4 h-4 text-yellow-400"></i>
                        Embedding Model
                    </h3>
                    <a href="https://huggingface.co/models?pipeline_tag=feature-extraction&library=gguf&sort=downloads" target="_blank" 
                       class="text-xs text-yellow-400 hover:text-yellow-300 flex items-center gap-1">
                        <i data-lucide="external-link" class="w-3 h-3"></i>
                        Browse Embedding Models
                    </a>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    Used for: Document search, RAG, semantic similarity. Runs on CPU, lightweight (~150MB).
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="text" id="embedding-model" placeholder="GGUF URL (e.g., https://huggingface.co/.../nomic-embed-text.gguf)" 
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-yellow-500 col-span-2">
                    <button onclick="changeEmbeddingModel()" 
                            class="bg-yellow-700 hover:bg-yellow-600 rounded px-4 py-2 text-sm font-medium transition flex items-center justify-center gap-2">
                        <i data-lucide="refresh-cw" class="w-4 h-4"></i>
                        Change Model
                    </button>
                </div>
                <p id="embedding-current" class="text-xs text-gray-500 mt-2">Current: Loading...</p>
                <p class="text-xs text-gray-500 mt-1">
                    Recommended: 
                    <code class="bg-gray-600 px-1 rounded text-xs">nomic-embed-text-v1.5.Q8_0.gguf</code>
                    <code class="bg-gray-600 px-1 rounded text-xs">bge-base-en-v1.5.Q8_0.gguf</code>
                </p>
            </div>
            
            <!-- Section: HuggingFace Token -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-gray-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="key-round" class="w-4 h-4 text-gray-400"></i>
                        HuggingFace Token
                    </h3>
                    <a href="https://huggingface.co/settings/tokens" target="_blank" 
                       class="text-xs text-gray-400 hover:text-gray-300 flex items-center gap-1">
                        <i data-lucide="external-link" class="w-3 h-3"></i>
                        Get Token
                    </a>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    Required for gated models (Llama-3, CodeLlama, Mistral). Token is stored securely.
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="password" id="hf-token" placeholder="hf_xxxxx..." 
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-500 col-span-2">
                    <button onclick="setHfToken()" 
                            class="bg-gray-600 hover:bg-gray-500 rounded px-4 py-2 text-sm font-medium transition">
                        Save Token
                    </button>
                </div>
            </div>
            
            <!-- Advanced: Backend Configuration -->
            <details class="bg-gray-700 rounded-lg p-4 mb-4">
                <summary class="font-medium cursor-pointer flex items-center gap-2">
                    <i data-lucide="settings" class="w-4 h-4"></i>
                    Advanced Settings
                    <span class="text-xs bg-yellow-900 text-yellow-300 px-2 py-0.5 rounded ml-2">Requires Restart</span>
                </summary>
                <div class="mt-4 space-y-4">
                    <!-- vLLM Config -->
                    <div class="border-l-2 border-green-500 pl-4">
                        <h4 class="text-sm font-medium text-green-400 mb-2">vLLM Configuration</h4>
                        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
                            <div>
                                <label class="text-xs text-gray-400">Context Length</label>
                                <input type="number" id="vllm-ctx" value="16384" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">8K-32K typical</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">GPU Memory %</label>
                                <input type="number" id="vllm-gpu-mem" value="90" min="50" max="99" step="5"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">90=safe, 95=aggressive</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Max Batch Size</label>
                                <input type="number" id="vllm-batch" value="32" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">Concurrent requests</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Quantization</label>
                                <select id="vllm-quant" class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                    <option value="awq">AWQ</option>
                                    <option value="gptq">GPTQ</option>
                                    <option value="none">None (FP16)</option>
                                </select>
                            </div>
                        </div>
                        <button onclick="updateVllmConfig()" 
                                class="mt-3 bg-green-700 hover:bg-green-600 rounded px-3 py-1 text-xs">
                            Apply vLLM Config
                        </button>
                    </div>
                    
                    <!-- llama.cpp Config -->
                    <div class="border-l-2 border-blue-500 pl-4">
                        <h4 class="text-sm font-medium text-blue-400 mb-2">llama.cpp Configuration</h4>
                        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
                            <div>
                                <label class="text-xs text-gray-400">Context Length</label>
                                <input type="number" id="llamacpp-ctx" value="32768" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">32K+ for 256GB RAM</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Batch Size</label>
                                <input type="number" id="llamacpp-batch" value="4096" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">CPU Threads</label>
                                <input type="number" id="llamacpp-threads" value="16" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Parallel Slots</label>
                                <input type="number" id="llamacpp-parallel" value="4" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">Concurrent users</p>
                            </div>
                        </div>
                        <button onclick="updateLlamacppConfig()" 
                                class="mt-3 bg-blue-700 hover:bg-blue-600 rounded px-3 py-1 text-xs">
                            Apply llama.cpp Config
                        </button>
                    </div>
                    
                    <!-- Embedding Config -->
                    <div class="border-l-2 border-yellow-500 pl-4">
                        <h4 class="text-sm font-medium text-yellow-400 mb-2">Embedding Configuration</h4>
                        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
                            <div>
                                <label class="text-xs text-gray-400">Context Size</label>
                                <input type="number" id="embedding-ctx" value="8192" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Batch Size</label>
                                <input type="number" id="embedding-batch" value="512" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">CPU Threads</label>
                                <input type="number" id="embedding-threads" value="4" 
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                        </div>
                        <button onclick="updateEmbeddingConfig()" 
                                class="mt-3 bg-yellow-700 hover:bg-yellow-600 rounded px-3 py-1 text-xs">
                            Apply Embedding Config
                        </button>
                    </div>
                    
                    <p class="text-xs text-gray-500 mt-2">
                        ⚠️ <strong>OOM Prevention:</strong> If you get out-of-memory errors, reduce context length or GPU memory %.
                    </p>
                </div>
            </details>
            
            <!-- Models List -->
            <h3 class="font-medium mb-3">Loaded Models</h3>
            <div id="models-list" class="space-y-2">
                <p class="text-gray-400">Loading...</p>
            </div>
            <p class="text-sm text-gray-500 mt-4">
                <span class="text-green-400">●</span> Loaded = ready to use &nbsp;
                <span class="text-yellow-400">●</span> Cached = will load on first request (lazy loading)
            </p>
        </div>

        <!-- API Keys Management -->
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700 mb-8">
            <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
                <i data-lucide="key" class="w-5 h-5 text-yellow-400"></i>
                API Keys
            </h2>
            
            <!-- Create Key Form -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4">
                <h3 class="font-medium mb-3">Create New Key</h3>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-3">
                    <input type="text" id="key-name" placeholder="Key name" 
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500">
                    <input type="number" id="key-rpm" placeholder="Requests/min" value="60"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500">
                    <input type="number" id="key-tokens" placeholder="Tokens/day" value="100000"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500">
                </div>
                <div class="mb-3">
                    <label class="text-sm text-gray-400 mb-2 block">Scopes (permissions):</label>
                    <div class="flex gap-4">
                        <label class="flex items-center gap-2 cursor-pointer">
                            <input type="checkbox" id="scope-inference" checked class="w-4 h-4 rounded">
                            <span class="text-sm">🤖 Inference (LLM API)</span>
                        </label>
                        <label class="flex items-center gap-2 cursor-pointer">
                            <input type="checkbox" id="scope-metrics" class="w-4 h-4 rounded">
                            <span class="text-sm">📊 Metrics (Monitoring)</span>
                        </label>
                        <label class="flex items-center gap-2 cursor-pointer">
                            <input type="checkbox" id="scope-admin" class="w-4 h-4 rounded">
                            <span class="text-sm">🔑 Admin (Full Access)</span>
                        </label>
                    </div>
                    <p class="text-xs text-gray-500 mt-1">Admin scope grants all permissions</p>
                </div>
                <button onclick="createKey()" 
                        class="bg-purple-600 hover:bg-purple-700 rounded px-4 py-2 text-sm font-medium transition">
                    Create Key
                </button>
                <div id="new-key-result" class="mt-3 hidden">
                    <p class="text-sm text-gray-400">New API Key (save this!):</p>
                    <code id="new-key-value" class="block bg-gray-900 rounded p-2 mt-1 text-green-400 text-sm font-mono break-all"></code>
                </div>
            </div>
            
            <div id="keys-list" class="space-y-2">
                <p class="text-gray-400">Loading...</p>
            </div>
        </div>

        <!-- Usage Stats -->
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700">
            <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
                <i data-lucide="bar-chart-3" class="w-5 h-5 text-green-400"></i>
                Usage Statistics
            </h2>
            
            <!-- Summary Cards -->
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
                <div class="bg-gray-700 rounded-lg p-4">
                    <p class="text-sm text-gray-400">Total Requests Today</p>
                    <p id="stats-total-requests" class="text-2xl font-bold text-green-400">-</p>
                </div>
                <div class="bg-gray-700 rounded-lg p-4">
                    <p class="text-sm text-gray-400">Total Tokens Today</p>
                    <p id="stats-total-tokens" class="text-2xl font-bold text-purple-400">-</p>
                </div>
                <div class="bg-gray-700 rounded-lg p-4">
                    <p class="text-sm text-gray-400">Active API Keys</p>
                    <p id="stats-active-keys" class="text-2xl font-bold text-blue-400">-</p>
                </div>
            </div>
            
            <!-- Usage by API Key -->
            <div class="mb-6">
                <h3 class="font-medium mb-3">Usage by API Key</h3>
                <div id="stats-by-key" class="space-y-2">
                    <p class="text-gray-400 text-sm">Loading...</p>
                </div>
            </div>
            
            <!-- Hourly Chart (simple bar representation) -->
            <div>
                <h3 class="font-medium mb-3">Requests (Last 24 Hours)</h3>
                <div id="stats-hourly" class="flex items-end gap-1 h-24 bg-gray-700 rounded-lg p-2">
                    <p class="text-gray-400 text-sm">Loading...</p>
                </div>
                <div class="flex justify-between text-xs text-gray-500 mt-1 px-2">
                    <span>24h ago</span>
                    <span>Now</span>
                </div>
            </div>
        </div>
    </div>

    <script>
        // Initialize Lucide icons
        lucide.createIcons();

        const API_BASE = window.location.origin;
        
        // Get API key from localStorage
        const API_KEY = localStorage.getItem('llmapi_admin_key');
        
        // Redirect to login if no key
        if (!API_KEY) {
            window.location.href = '/admin';
        }
        
        // Admin API calls with API key authentication
        async function adminFetch(url, options = {}) {
            const headers = {
                ...options.headers,
                'Authorization': `Bearer ${API_KEY}`
            };
            return fetch(url, { 
                ...options,
                headers
            });
        }
        
        // Logout function
        function logout() {
            if (confirm('Are you sure you want to logout?')) {
                localStorage.removeItem('llmapi_admin_key');
                window.location.href = '/admin';
            }
        }

        async function loadStatus() {
            try {
                const resp = await adminFetch(`${API_BASE}/health/backends`);
                const data = await resp.json();
                
                // Update backend status
                for (const [key, healthy] of Object.entries(data.backends)) {
                    const [backend, url] = key.split(':');
                    const el = document.getElementById(`${backend}-status`);
                    if (el) {
                        el.innerHTML = healthy 
                            ? '<span class="text-green-400">● Online</span>' 
                            : '<span class="text-red-400">● Offline</span>';
                    }
                }
            } catch (e) {
                console.error('Failed to load status:', e);
            }
        }

        async function loadModels() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/models`);
                if (!resp) return; // Auth failure, already redirected
                const data = await resp.json();
                
                const list = document.getElementById('models-list');
                if (data.models && data.models.length > 0) {
                    list.innerHTML = data.models.map(m => `
                        <div class="flex items-center justify-between bg-gray-700 rounded p-3">
                            <div>
                                <span class="font-medium">${m.id}</span>
                                <span class="text-xs text-gray-400 ml-2">${m.backend}</span>
                                ${m.size ? `<span class="text-xs text-gray-500 ml-2">${formatSize(m.size)}</span>` : ''}
                            </div>
                            <div class="flex items-center gap-2">
                                <span class="text-xs px-2 py-1 rounded ${m.status === 'loaded' ? 'bg-green-900 text-green-300' : 'bg-yellow-900 text-yellow-300'}">
                                    ${m.status}
                                </span>
                                ${m.backend === 'ollama' ? `
                                    <button onclick="deleteModel('${m.id}')" 
                                            class="text-red-400 hover:text-red-300 transition p-1" title="Delete model">
                                        <i data-lucide="trash-2" class="w-4 h-4"></i>
                                    </button>
                                ` : ''}
                            </div>
                        </div>
                    `).join('');
                    lucide.createIcons();
                } else {
                    list.innerHTML = '<p class="text-yellow-400">No models loaded. Use the form above to download a model.</p>';
                }
            } catch (e) {
                console.error('Failed to load models:', e);
            }
        }
        
        function formatSize(bytes) {
            if (!bytes) return '';
            const gb = bytes / (1024 * 1024 * 1024);
            return gb >= 1 ? `${gb.toFixed(1)} GB` : `${(bytes / (1024 * 1024)).toFixed(0)} MB`;
        }
        
        async function downloadModel() {
            const modelName = document.getElementById('model-name').value.trim();
            if (!modelName) {
                alert('Please enter a model name');
                return;
            }
            
            document.getElementById('download-progress').classList.remove('hidden');
            document.getElementById('download-status').textContent = 'Starting download...';
            document.getElementById('download-bar').style.width = '0%';
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/models/download`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({model: modelName})
                });
                
                const reader = resp.body.getReader();
                const decoder = new TextDecoder();
                
                while (true) {
                    const {done, value} = await reader.read();
                    if (done) break;
                    
                    const lines = decoder.decode(value).split('\\n');
                    for (const line of lines) {
                        if (!line) continue;
                        try {
                            const data = JSON.parse(line);
                            if (data.status) {
                                document.getElementById('download-status').textContent = data.status;
                            }
                            if (data.completed && data.total) {
                                const pct = (data.completed / data.total * 100).toFixed(0);
                                document.getElementById('download-bar').style.width = pct + '%';
                            }
                            if (data.error) {
                                document.getElementById('download-status').textContent = 'Error: ' + data.error;
                            }
                        } catch (e) {}
                    }
                }
                
                document.getElementById('download-status').textContent = 'Download complete!';
                document.getElementById('download-bar').style.width = '100%';
                document.getElementById('model-name').value = '';
                loadModels();
                
                setTimeout(() => {
                    document.getElementById('download-progress').classList.add('hidden');
                }, 3000);
            } catch (e) {
                document.getElementById('download-status').textContent = 'Error: ' + e.message;
            }
        }
        
        async function deleteModel(modelName) {
            if (!confirm(`Delete model "${modelName}"? This will free up disk space but the model will need to be re-downloaded to use again.`)) return;
            
            try {
                await adminFetch(`${API_BASE}/admin/models/${encodeURIComponent(modelName)}`, {method: 'DELETE'});
                loadModels();
            } catch (e) {
                alert('Failed to delete model: ' + e.message);
            }
        }
        
        async function changeVllmModel() {
            const model = document.getElementById('vllm-model').value.trim();
            if (!model) {
                alert('Please enter a HuggingFace model ID');
                return;
            }
            
            const confirmed = confirm(
                `⚠️ CHANGE vLLM MODEL\\n\\n` +
                `New model: ${model}\\n\\n` +
                `This will:\\n` +
                `• Stop the vLLM service (~10-30 min downtime)\\n` +
                `• Download the new model from HuggingFace\\n` +
                `• Restart the service\\n\\n` +
                `Ollama models will remain available during this time.\\n\\n` +
                `Continue?`
            );
            if (!confirmed) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/vllm`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({model_id: model})
                });
                const data = await resp.json();
                if (resp.ok) {
                    alert('vLLM model change initiated! The service will restart and download the new model. This may take 10-30 minutes.');
                    document.getElementById('vllm-model').value = '';
                    loadBackendConfig();
                } else {
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed to change model: ' + e.message);
            }
        }
        
        async function changeLlamacppModel() {
            const modelUrl = document.getElementById('llamacpp-model').value.trim();
            if (!modelUrl) {
                alert('Please enter a GGUF model URL');
                return;
            }
            if (!modelUrl.endsWith('.gguf')) {
                alert('URL must point to a .gguf file');
                return;
            }
            
            const confirmed = confirm(
                `⚠️ CHANGE llama.cpp MODEL\\n\\n` +
                `New model URL: ${modelUrl}\\n\\n` +
                `This will:\\n` +
                `• Stop the llama.cpp service (~5-15 min downtime)\\n` +
                `• Download the new GGUF model\\n` +
                `• Restart the service\\n\\n` +
                `vLLM and Ollama models will remain available.\\n\\n` +
                `Continue?`
            );
            if (!confirmed) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/llamacpp`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({model_url: modelUrl})
                });
                const data = await resp.json();
                if (resp.ok) {
                    alert('llama.cpp model change initiated! The service will restart and download the new model. This may take 5-15 minutes.');
                    document.getElementById('llamacpp-model').value = '';
                    loadBackendConfig();
                } else {
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed to change model: ' + e.message);
            }
        }
        
        async function loadBackendConfig() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/config`);
                if (!resp) return; // Auth failure, already redirected
                const data = await resp.json();
                
                if (data.vllm_model) {
                    document.getElementById('vllm-current').textContent = 'Current: ' + data.vllm_model;
                }
                if (data.llamacpp_model_url) {
                    const url = data.llamacpp_model_url;
                    const filename = url.split('/').pop();
                    document.getElementById('llamacpp-current').textContent = 'Current: ' + filename;
                }
                if (data.embedding_model_url) {
                    const url = data.embedding_model_url;
                    const filename = url.split('/').pop();
                    document.getElementById('embedding-current').textContent = 'Current: ' + filename;
                }
                
                // Update llama.cpp running status
                const llamacppStatus = document.getElementById('llamacpp-running');
                if (data.llamacpp_replicas > 0) {
                    llamacppStatus.textContent = 'Running';
                    llamacppStatus.className = 'text-xs px-2 py-1 rounded bg-green-900 text-green-300';
                } else {
                    llamacppStatus.textContent = 'Stopped';
                    llamacppStatus.className = 'text-xs px-2 py-1 rounded bg-gray-600 text-gray-400';
                }
            } catch (e) {
                console.error('Failed to load backend config:', e);
            }
        }
        
        async function changeEmbeddingModel() {
            const modelUrl = document.getElementById('embedding-model').value.trim();
            if (!modelUrl) {
                alert('Please enter a GGUF model URL');
                return;
            }
            if (!modelUrl.endsWith('.gguf')) {
                alert('URL must point to a .gguf file');
                return;
            }
            
            const confirmed = confirm(
                `⚠️ CHANGE EMBEDDING MODEL\\n\\n` +
                `New model URL: ${modelUrl}\\n\\n` +
                `This will:\\n` +
                `• Stop the embedding service (~2-5 min downtime)\\n` +
                `• Download the new GGUF model\\n` +
                `• Restart the service\\n\\n` +
                `Continue?`
            );
            if (!confirmed) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/embedding`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({model_url: modelUrl})
                });
                const data = await resp.json();
                if (resp.ok) {
                    alert('Embedding model change initiated! The service will restart and download the new model.');
                    document.getElementById('embedding-model').value = '';
                    loadBackendConfig();
                } else {
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed to change model: ' + e.message);
            }
        }
        
        async function updateEmbeddingConfig() {
            const ctx = document.getElementById('embedding-ctx').value;
            const batch = document.getElementById('embedding-batch').value;
            const threads = document.getElementById('embedding-threads').value;
            
            const msg = `This will restart embedding service with:
• Context: ${ctx} tokens
• Batch Size: ${batch}
• Threads: ${threads}

Continue?`;
            
            if (!confirm(msg)) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/embedding/config`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        context_size: parseInt(ctx),
                        batch_size: parseInt(batch),
                        threads: parseInt(threads)
                    })
                });
                if (resp.ok) {
                    alert('Embedding config updated! Pod is restarting...');
                    loadBackendConfig();
                } else {
                    const data = await resp.json();
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed: ' + e.message);
            }
        }
        
        async function toggleLlamacpp() {
            const statusEl = document.getElementById('llamacpp-running');
            const isRunning = statusEl.textContent === 'Running';
            
            const action = isRunning ? 'stop' : 'start';
            const message = isRunning 
                ? 'Stop llama.cpp? This will free ~40GB RAM but the model will need to reload when started again.'
                : 'Start llama.cpp? This will load the model into RAM (~40GB for 70B models). Takes 2-5 minutes.';
            
            if (!confirm(message)) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/llamacpp/scale`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({replicas: isRunning ? 0 : 1})
                });
                if (resp.ok) {
                    alert(isRunning ? 'llama.cpp stopping...' : 'llama.cpp starting... Model will load in 2-5 minutes.');
                    loadBackendConfig();
                } else {
                    const data = await resp.json();
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed: ' + e.message);
            }
        }
        
        async function setHfToken() {
            const token = document.getElementById('hf-token').value.trim();
            if (!token) {
                alert('Please enter a HuggingFace token');
                return;
            }
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/config`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({hf_token: token})
                });
                if (resp.ok) {
                    alert('HuggingFace token saved! It will be used when vLLM restarts with a gated model.');
                    document.getElementById('hf-token').value = '';
                } else {
                    alert('Failed to save token');
                }
            } catch (e) {
                alert('Failed to save token: ' + e.message);
            }
        }
        
        async function updateVllmConfig() {
            const ctx = document.getElementById('vllm-ctx').value;
            const gpuMem = document.getElementById('vllm-gpu-mem').value;
            const batch = document.getElementById('vllm-batch').value;
            const quant = document.getElementById('vllm-quant').value;
            
            const msg = `This will restart vLLM with:
• Context: ${ctx} tokens
• GPU Memory: ${gpuMem}%
• Batch Size: ${batch}
• Quantization: ${quant}

vLLM will be unavailable for ~5-10 minutes. Continue?`;
            
            if (!confirm(msg)) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/vllm/config`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        max_model_len: parseInt(ctx),
                        gpu_memory_utilization: parseInt(gpuMem) / 100,
                        max_num_seqs: parseInt(batch),
                        quantization: quant
                    })
                });
                if (resp.ok) {
                    alert('vLLM config updated! Pod is restarting...');
                    loadBackendConfig();
                } else {
                    const data = await resp.json();
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed: ' + e.message);
            }
        }
        
        async function updateLlamacppConfig() {
            const ctx = document.getElementById('llamacpp-ctx').value;
            const batch = document.getElementById('llamacpp-batch').value;
            const threads = document.getElementById('llamacpp-threads').value;
            const parallel = document.getElementById('llamacpp-parallel').value;
            
            const msg = `This will restart llama.cpp with:
• Context: ${ctx} tokens
• Batch Size: ${batch}
• Threads: ${threads}
• Parallel Slots: ${parallel}

llama.cpp will be unavailable for ~2-5 minutes. Continue?`;
            
            if (!confirm(msg)) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/llamacpp/config`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        context_size: parseInt(ctx),
                        batch_size: parseInt(batch),
                        threads: parseInt(threads),
                        parallel: parseInt(parallel)
                    })
                });
                if (resp.ok) {
                    alert('llama.cpp config updated! Pod is restarting...');
                    loadBackendConfig();
                } else {
                    const data = await resp.json();
                    alert('Failed: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed: ' + e.message);
            }
        }

        async function loadKeys() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/keys`);
                if (!resp) return; // Auth failure, already redirected
                const data = await resp.json();
                
                const list = document.getElementById('keys-list');
                if (data.keys && data.keys.length > 0) {
                    list.innerHTML = data.keys.map(k => `
                        <div class="flex items-center justify-between bg-gray-700 rounded p-3">
                            <div>
                                <span class="font-medium">${k.name}</span>
                                <span class="text-xs text-gray-400 ml-2">${k.key_prefix}...</span>
                            </div>
                            <div class="flex items-center gap-4 text-sm text-gray-400">
                                <span>${k.requests_per_minute} rpm</span>
                                <span>${k.tokens_per_day.toLocaleString()} tokens/day</span>
                                <button onclick="revokeKey('${k.key}')" 
                                        class="text-red-400 hover:text-red-300 transition">
                                    <i data-lucide="trash-2" class="w-4 h-4"></i>
                                </button>
                            </div>
                        </div>
                    `).join('');
                    lucide.createIcons();
                } else {
                    list.innerHTML = '<p class="text-gray-400">No API keys found.</p>';
                }
            } catch (e) {
                            </div>
                        </div>
                    `).join('');
                }
                
                // Update hourly chart
                const hourlyEl = document.getElementById('stats-hourly');
                const maxReq = Math.max(...data.by_hour.map(h => h.requests), 1);
                hourlyEl.innerHTML = data.by_hour.map(h => {
                    const height = Math.max(4, (h.requests / maxReq) * 100);
                    const title = `${h.hour}: ${h.requests} requests, ${h.tokens.toLocaleString()} tokens`;
                    return `<div class="flex-1 bg-green-500 rounded-t opacity-70 hover:opacity-100 transition cursor-pointer" 
                                 style="height: ${height}%" title="${title}"></div>`;
                }).join('');
                
            } catch (e) {
                console.error('Failed to load stats:', e);
            }
        }

        // Load everything on page load
        loadStatus();
        loadModels();
        loadKeys();
        loadBackendConfig();
        loadStats();
        
        // Refresh status every 30 seconds
        setInterval(loadStatus, 30000);
        setInterval(loadBackendConfig, 60000);
        setInterval(loadModels, 30000);
        setInterval(loadStats, 60000);  // Refresh stats every minute
    </script>
</body>
</html>
"""


# =============================================================================
# Admin Endpoints (require 'admin' scope)
# =============================================================================


@app.get("/admin", response_class=HTMLResponse)
async def admin_ui():
    """Admin UI for managing the LLM API - requires 'admin' scope."""
    return ADMIN_LOGIN_HTML


@app.get("/admin/dashboard", response_class=HTMLResponse)
async def admin_dashboard():
    """Admin dashboard - authentication handled by JavaScript with localStorage API key."""
    return ADMIN_HTML


@app.get("/admin/models")
async def admin_list_models(api_key: str = Depends(get_api_key)):
    """List all models (admin endpoint)."""
    await require_scope("admin", api_key)
    return {
        "models": model_registry.get_available_models(),
        "backends": model_registry.backends,
    }


@app.get("/admin/keys")
async def admin_list_keys(api_key: str = Depends(get_api_key)):
    """List all API keys (admin endpoint)."""
    await require_scope("admin", api_key)
    keys = []
    # Scan for all API keys in Redis
    if redis_client.client:
        cursor = 0
        while True:
            cursor, found_keys = await redis_client.client.scan(cursor, match="apikey:sk-mynodeone-*", count=100)
            for key in found_keys:
                api_key = key.replace("apikey:", "")
                config_data = await redis_client.get_api_key_config(api_key)
                if config_data:
                    keys.append({
                        "key": api_key,
                        "key_prefix": api_key[:20],
                        "name": config_data.get("name", "unknown"),
                        "requests_per_minute": config_data.get("requests_per_minute", 60),
                        "tokens_per_day": config_data.get("tokens_per_day", 100000),
                        "created_at": config_data.get("created_at", ""),
                    })
            if cursor == 0:
                break
    return {"keys": keys}


@app.post("/admin/keys")
async def admin_create_key(request: Request, api_key: str = Depends(get_api_key)):
    """Create a new API key (admin endpoint)."""
    await require_scope("admin", api_key)
    import secrets
    
    body = await request.json()
    name = body.get("name", "unnamed")
    scopes = body.get("scopes", ["inference"])  # Default to inference only
    
    # Validate scopes
    valid_scopes = ["inference", "metrics", "admin"]
    if not isinstance(scopes, list) or not all(s in valid_scopes for s in scopes):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid scopes. Must be a list containing: {valid_scopes}"
        )
    
    requests_per_minute = body.get("requests_per_minute", 60)
    tokens_per_day = body.get("tokens_per_day", 100000)
    
    key_id = secrets.token_hex(16)
    api_key = f"sk-mynodeone-{key_id}"
    
    key_config = {
        "name": name,
        "scopes": scopes,
        "requests_per_minute": requests_per_minute,
        "tokens_per_day": tokens_per_day,
        "created_at": datetime.utcnow().isoformat(),
    }
    
    await redis_client.set_api_key_config(api_key, key_config)
    
    return {"api_key": api_key, "config": key_config}


@app.delete("/admin/keys/{api_key}")
async def admin_revoke_key(api_key: str, admin_key: str = Depends(get_api_key)):
    """Revoke an API key (admin endpoint)."""
    await require_scope("admin", admin_key)
    await redis_client.client.delete(f"apikey:{api_key}")
    return {"status": "revoked", "api_key": api_key}


@app.get("/admin/usage/{api_key}")
async def admin_get_usage(api_key: str, admin_key: str = Depends(get_api_key)):
    """Get usage for a specific API key."""
    await require_scope("admin", admin_key)
    key_config = await redis_client.get_api_key_config(api_key)
    if not key_config:
        raise HTTPException(status_code=404, detail="API key not found")
    
    input_tokens, output_tokens = await redis_client.get_token_usage(api_key)
    current_rpm, ttl = await redis_client.get_rate_limit_info(api_key)
    
    return {
        "api_key": api_key[:20] + "...",
        "name": key_config.get("name"),
        "tokens_used_today": input_tokens + output_tokens,
        "tokens_limit": key_config.get("tokens_per_day"),
        "requests_this_minute": current_rpm,
        "requests_limit": key_config.get("requests_per_minute"),
    }


@app.get("/admin/stats")
async def admin_get_stats(api_key: str = Depends(get_api_key)):
    """Get comprehensive usage statistics for all API keys."""
    await require_scope("admin", api_key)
    from datetime import datetime
    
    stats = {
        "summary": {
            "total_requests_today": 0,
            "total_tokens_today": 0,
            "active_keys": 0,
        },
        "by_key": [],
        "by_hour": [],
    }
    
    if not redis_client.client:
        return stats
    
    # Get all API keys and their usage
    keys = await redis_client.client.keys("apikey:*")
    today = datetime.now().strftime("%Y-%m-%d")
    
    for key in keys:
        key_str = key.decode() if isinstance(key, bytes) else key
        api_key = key_str.replace("apikey:", "")
        
        # Get key config
        key_config = await redis_client.get_api_key_config(api_key)
        if not key_config:
            continue
        
        # Get token usage
        input_tokens, output_tokens = await redis_client.get_token_usage(api_key)
        total_tokens = input_tokens + output_tokens
        
        # Get request count from rate limit
        current_rpm, _ = await redis_client.get_rate_limit_info(api_key)
        
        # Get daily request count if stored
        daily_requests = await redis_client.client.get(f"requests:{api_key}:{today}") or 0
        if isinstance(daily_requests, bytes):
            daily_requests = int(daily_requests.decode())
        elif isinstance(daily_requests, str):
            daily_requests = int(daily_requests)
        
        key_stats = {
            "name": key_config.get("name", "Unknown"),
            "api_key_preview": api_key[:16] + "..." if len(api_key) > 16 else api_key,
            "tokens_today": total_tokens,
            "tokens_limit": key_config.get("tokens_per_day", 0),
            "requests_today": daily_requests,
            "requests_per_min": current_rpm,
            "rpm_limit": key_config.get("requests_per_minute", 0),
        }
        
        stats["by_key"].append(key_stats)
        stats["summary"]["total_tokens_today"] += total_tokens
        stats["summary"]["total_requests_today"] += daily_requests
        if total_tokens > 0 or daily_requests > 0:
            stats["summary"]["active_keys"] += 1
    
    # Get hourly stats (last 24 hours)
    for hour_offset in range(24):
        hour_time = datetime.now().replace(minute=0, second=0, microsecond=0)
        hour_key = (hour_time.hour - hour_offset) % 24
        hour_label = f"{hour_key:02d}:00"
        
        # Sum requests for this hour across all keys
        hour_requests = 0
        hour_tokens = 0
        
        for key in keys:
            key_str = key.decode() if isinstance(key, bytes) else key
            api_key = key_str.replace("apikey:", "")
            
            req_count = await redis_client.client.get(f"hourly:{api_key}:{today}:{hour_key}") or 0
            tok_count = await redis_client.client.get(f"hourly_tokens:{api_key}:{today}:{hour_key}") or 0
            
            if isinstance(req_count, bytes):
                req_count = int(req_count.decode())
            elif isinstance(req_count, str):
                req_count = int(req_count)
            if isinstance(tok_count, bytes):
                tok_count = int(tok_count.decode())
            elif isinstance(tok_count, str):
                tok_count = int(tok_count)
                
            hour_requests += req_count
            hour_tokens += tok_count
        
        stats["by_hour"].insert(0, {
            "hour": hour_label,
            "requests": hour_requests,
            "tokens": hour_tokens,
        })
    
    # Sort by_key by tokens used (descending)
    stats["by_key"].sort(key=lambda x: x["tokens_today"], reverse=True)
    
    return stats


# =============================================================================
# Model Management Endpoints
# =============================================================================

@app.post("/admin/models/download")
async def admin_download_model(request: Request, api_key: str = Depends(get_api_key)):
    """Download a model from Ollama/HuggingFace. Returns streaming progress."""
    await require_scope("admin", api_key)
    body = await request.json()
    model_name = body.get("model")
    
    if not model_name:
        raise HTTPException(status_code=400, detail="Model name is required")
    
    async def stream_progress():
        async for line in backend_manager.pull_ollama_model(model_name):
            yield line + "\n"
        # Refresh model list after download
        await backend_manager.discover_models()
    
    return StreamingResponse(stream_progress(), media_type="application/x-ndjson")


@app.delete("/admin/models/{model_name}")
async def admin_delete_model(model_name: str, api_key: str = Depends(get_api_key)):
    """Delete a cached model from Ollama."""
    await require_scope("admin", api_key)
    try:
        resp = await backend_manager.http_client.delete(
            f"{config.OLLAMA_URL}/api/delete",
            json={"name": model_name}
        )
        if resp.status_code == 200:
            model_registry.unregister_model(model_name)
            if model_name in model_registry.cached_models:
                del model_registry.cached_models[model_name]
            return {"status": "deleted", "model": model_name}
        else:
            raise HTTPException(status_code=resp.status_code, detail="Failed to delete model")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/models/load")
async def admin_load_model(request: Request, api_key: str = Depends(get_api_key)):
    """Manually load a cached model into memory."""
    await require_scope("admin", api_key)
    body = await request.json()
    model_name = body.get("model")
    
    if not model_name:
        raise HTTPException(status_code=400, detail="Model name is required")
    
    success = await backend_manager.load_ollama_model(model_name)
    if success:
        return {"status": "loaded", "model": model_name}
    else:
        raise HTTPException(status_code=500, detail="Failed to load model")


@app.post("/admin/config")
async def admin_update_config(request: Request, api_key: str = Depends(get_api_key)):
    """Update configuration (e.g., HF token)."""
    await require_scope("admin", api_key)
    body = await request.json()
    
    # Store HF token in Redis for persistence
    if "hf_token" in body:
        hf_token = body["hf_token"]
        await redis_client.client.set("config:hf_token", hf_token)
        # Also update the Ollama secret (this requires kubectl access)
        # For now, just store in Redis and document that manual secret update may be needed
        return {"status": "saved", "note": "Token saved. Ollama may need restart to use new token."}
    
    return {"status": "no changes"}


@app.get("/admin/config")
async def admin_get_config(api_key: str = Depends(get_api_key)):
    """Get current configuration including current models."""
    await require_scope("admin", api_key)
    hf_token_set = False
    vllm_model = None
    llamacpp_model_url = None
    llamacpp_replicas = 0
    
    if redis_client.client:
        token = await redis_client.client.get("config:hf_token")
        hf_token_set = bool(token)
        # Get current model configs from Redis
        vllm_model = await redis_client.client.get("config:vllm_model")
        if vllm_model:
            vllm_model = vllm_model.decode() if isinstance(vllm_model, bytes) else vllm_model
        llamacpp_model_url = await redis_client.client.get("config:llamacpp_model_url")
        if llamacpp_model_url:
            llamacpp_model_url = llamacpp_model_url.decode() if isinstance(llamacpp_model_url, bytes) else llamacpp_model_url
    
    # Try to get from Kubernetes ConfigMaps if not in Redis
    try:
        from kubernetes import client, config as k8s_config
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get vLLM model from ConfigMap
        if not vllm_model:
            try:
                vllm_config = core_v1.read_namespaced_config_map("vllm-config", namespace)
                vllm_model = vllm_config.data.get("MODEL_NAME", "Not configured")
            except Exception as e:
                logger.debug(f"Could not read vllm-config: {e}")
        
        # Get llamacpp model URL from ConfigMap
        if not llamacpp_model_url:
            try:
                llamacpp_config = core_v1.read_namespaced_config_map("llamacpp-config", namespace)
                llamacpp_model_url = llamacpp_config.data.get("MODEL_URL", "Not configured")
            except Exception as e:
                logger.debug(f"Could not read llamacpp-config: {e}")
        
        # Get llama.cpp replica count
        try:
            deploy = apps_v1.read_namespaced_deployment("llamacpp", namespace)
            llamacpp_replicas = deploy.spec.replicas or 0
        except Exception as e:
            logger.debug(f"Could not get llama.cpp replicas: {e}")
        
        # Get embedding model URL from ConfigMap
        embedding_model_url = None
        try:
            embedding_config = core_v1.read_namespaced_config_map("embedding-config", namespace)
            embedding_model_url = embedding_config.data.get("MODEL_URL", "Not configured")
        except Exception as e:
            logger.debug(f"Could not read embedding-config: {e}")
            
    except Exception as e:
        logger.debug(f"Kubernetes API error: {e}")
        embedding_model_url = None
    
    # Final fallback to environment variables
    if not vllm_model or vllm_model == "Not configured":
        vllm_model = os.getenv("VLLM_MODEL_ID") or os.getenv("MODEL_NAME", "Not configured")
    if not llamacpp_model_url or llamacpp_model_url == "Not configured":
        llamacpp_model_url = os.getenv("LLAMACPP_MODEL_URL", "Not configured")
    if not embedding_model_url or embedding_model_url == "Not configured":
        embedding_model_url = os.getenv("EMBEDDING_MODEL_URL", "Not configured")
    
    return {
        "hf_token_configured": hf_token_set,
        "lazy_load_enabled": config.LAZY_LOAD_ENABLED,
        "auto_download": config.AUTO_DOWNLOAD,
        "vllm_model": vllm_model,
        "llamacpp_model_url": llamacpp_model_url,
        "llamacpp_replicas": llamacpp_replicas,
        "embedding_model_url": embedding_model_url,
        "backends": {
            "vllm": config.VLLM_URLS,
            "ollama": config.OLLAMA_URL,
            "llamacpp": config.LLAMACPP_URL,
            "embedding": config.EMBEDDING_URL,
        }
    }


# =============================================================================
# Backend Model Change Endpoints (requires RBAC permissions)
# =============================================================================

@app.post("/admin/backend/vllm")
async def admin_change_vllm_model(request: Request, api_key: str = Depends(get_api_key)):
    """Change the vLLM model. This triggers a pod restart with new model."""
    await require_scope("admin", api_key)
    body = await request.json()
    model_id = body.get("model_id")
    
    if not model_id:
        raise HTTPException(status_code=400, detail="model_id is required")
    
    try:
        # Try to use Kubernetes API
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get current StatefulSet
        sts = apps_v1.read_namespaced_stateful_set("vllm", namespace)
        
        # Update MODEL_ID environment variable
        for container in sts.spec.template.spec.containers:
            if container.name == "vllm":
                for i, env in enumerate(container.env or []):
                    if env.name == "MODEL_ID":
                        container.env[i].value = model_id
                        break
                else:
                    # Add if not exists
                    if container.env is None:
                        container.env = []
                    container.env.append(client.V1EnvVar(name="MODEL_ID", value=model_id))
        
        # Apply update
        apps_v1.patch_namespaced_stateful_set("vllm", namespace, sts)
        
        # Trigger rollout restart by updating an annotation
        if sts.spec.template.metadata.annotations is None:
            sts.spec.template.metadata.annotations = {}
        sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_stateful_set("vllm", namespace, sts)
        
        # Store in Redis for UI
        await redis_client.client.set("config:vllm_model", model_id)
        
        logger.info(f"vLLM model change initiated: {model_id}")
        return {"status": "initiated", "model_id": model_id, "message": "vLLM pod is restarting with new model"}
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available. Install 'kubernetes' package.")
    except Exception as e:
        logger.error(f"Failed to change vLLM model: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/llamacpp")
async def admin_change_llamacpp_model(request: Request, api_key: str = Depends(get_api_key)):
    """Change the llama.cpp model. This triggers a pod restart with new model."""
    await require_scope("admin", api_key)
    body = await request.json()
    model_url = body.get("model_url")
    
    if not model_url:
        raise HTTPException(status_code=400, detail="model_url is required")
    
    if not model_url.endswith(".gguf"):
        raise HTTPException(status_code=400, detail="model_url must point to a .gguf file")
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get current Deployment
        deploy = apps_v1.read_namespaced_deployment("llamacpp", namespace)
        
        # Update MODEL_URL environment variable in init container
        for container in deploy.spec.template.spec.init_containers or []:
            if container.name == "model-downloader":
                for i, env in enumerate(container.env or []):
                    if env.name == "MODEL_URL":
                        container.env[i].value = model_url
                        break
        
        # Apply update
        apps_v1.patch_namespaced_deployment("llamacpp", namespace, deploy)
        
        # Trigger rollout restart
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_deployment("llamacpp", namespace, deploy)
        
        # Store in Redis for UI
        await redis_client.client.set("config:llamacpp_model_url", model_url)
        
        logger.info(f"llama.cpp model change initiated: {model_url}")
        return {"status": "initiated", "model_url": model_url, "message": "llama.cpp pod is restarting with new model"}
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available. Install 'kubernetes' package.")
    except Exception as e:
        logger.error(f"Failed to change llama.cpp model: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/vllm/config")
async def admin_update_vllm_config(request: Request, api_key: str = Depends(get_api_key)):
    """Update vLLM configuration (context length, GPU memory, etc.). Triggers pod restart."""
    await require_scope("admin", api_key)
    body = await request.json()
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get current ConfigMap
        cm = core_v1.read_namespaced_config_map("vllm-config", namespace)
        
        # Update values
        if "max_model_len" in body:
            cm.data["MAX_MODEL_LEN"] = str(body["max_model_len"])
        if "gpu_memory_utilization" in body:
            cm.data["GPU_MEMORY_UTILIZATION"] = str(body["gpu_memory_utilization"])
        if "max_num_seqs" in body:
            cm.data["MAX_NUM_SEQS"] = str(body["max_num_seqs"])
        if "quantization" in body:
            cm.data["QUANTIZATION"] = body["quantization"]
        
        # Apply ConfigMap update
        core_v1.patch_namespaced_config_map("vllm-config", namespace, cm)
        
        # Trigger rollout restart
        sts = apps_v1.read_namespaced_stateful_set("vllm", namespace)
        if sts.spec.template.metadata.annotations is None:
            sts.spec.template.metadata.annotations = {}
        sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_stateful_set("vllm", namespace, sts)
        
        logger.info(f"vLLM config updated: {body}")
        return {"status": "updated", "config": body, "message": "vLLM pod is restarting with new config"}
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to update vLLM config: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/llamacpp/config")
async def admin_update_llamacpp_config(request: Request, api_key: str = Depends(get_api_key)):
    """Update llama.cpp configuration (context size, threads, etc.). Triggers pod restart."""
    await require_scope("admin", api_key)
    body = await request.json()
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get current ConfigMap
        cm = core_v1.read_namespaced_config_map("llamacpp-config", namespace)
        
        # Update values
        if "context_size" in body:
            cm.data["CONTEXT_SIZE"] = str(body["context_size"])
        if "batch_size" in body:
            cm.data["BATCH_SIZE"] = str(body["batch_size"])
        if "threads" in body:
            cm.data["THREADS"] = str(body["threads"])
        if "parallel" in body:
            cm.data["PARALLEL"] = str(body["parallel"])
        
        # Apply ConfigMap update
        core_v1.patch_namespaced_config_map("llamacpp-config", namespace, cm)
        
        # Trigger rollout restart
        deploy = apps_v1.read_namespaced_deployment("llamacpp", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_deployment("llamacpp", namespace, deploy)
        
        logger.info(f"llama.cpp config updated: {body}")
        return {"status": "updated", "config": body, "message": "llama.cpp pod is restarting with new config"}
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to update llama.cpp config: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/llamacpp/scale")
async def admin_scale_llamacpp(request: Request, api_key: str = Depends(get_api_key)):
    """Scale llama.cpp deployment (start/stop). Use replicas=0 to stop, replicas=1 to start."""
    await require_scope("admin", api_key)
    body = await request.json()
    replicas = body.get("replicas", 1)
    
    if replicas < 0 or replicas > 1:
        raise HTTPException(status_code=400, detail="replicas must be 0 or 1")
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Scale the deployment
        apps_v1.patch_namespaced_deployment_scale(
            "llamacpp",
            namespace,
            {"spec": {"replicas": replicas}}
        )
        
        action = "started" if replicas > 0 else "stopped"
        logger.info(f"llama.cpp {action} (replicas={replicas})")
        return {
            "status": action,
            "replicas": replicas,
            "message": f"llama.cpp {'starting - model will load in 2-5 minutes' if replicas > 0 else 'stopping - RAM will be freed'}"
        }
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to scale llama.cpp: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/embedding")
async def admin_change_embedding_model(request: Request, api_key: str = Depends(get_api_key)):
    """Change the embedding model. This triggers a pod restart with new model."""
    await require_scope("admin", api_key)
    body = await request.json()
    model_url = body.get("model_url")
    
    if not model_url:
        raise HTTPException(status_code=400, detail="model_url is required")
    
    if not model_url.endswith(".gguf"):
        raise HTTPException(status_code=400, detail="model_url must point to a .gguf file")
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Update ConfigMap with new model URL
        cm = core_v1.read_namespaced_config_map("embedding-config", namespace)
        cm.data["MODEL_URL"] = model_url
        cm.data["MODEL_FILE"] = model_url.split("/")[-1]
        core_v1.patch_namespaced_config_map("embedding-config", namespace, cm)
        
        # Trigger rollout restart
        deploy = apps_v1.read_namespaced_deployment("embedding", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_deployment("embedding", namespace, deploy)
        
        # Store in Redis for UI
        await redis_client.client.set("config:embedding_model_url", model_url)
        
        logger.info(f"Embedding model change initiated: {model_url}")
        return {"status": "initiated", "model_url": model_url, "message": "Embedding pod is restarting with new model"}
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available. Install 'kubernetes' package.")
    except Exception as e:
        logger.error(f"Failed to change embedding model: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/embedding/config")
async def admin_update_embedding_config(request: Request, api_key: str = Depends(get_api_key)):
    """Update embedding configuration (context size, batch size, threads). Triggers pod restart."""
    await require_scope("admin", api_key)
    body = await request.json()
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get current ConfigMap
        cm = core_v1.read_namespaced_config_map("embedding-config", namespace)
        
        # Update values
        if "context_size" in body:
            cm.data["CONTEXT_SIZE"] = str(body["context_size"])
        if "batch_size" in body:
            cm.data["BATCH_SIZE"] = str(body["batch_size"])
        if "threads" in body:
            cm.data["THREADS"] = str(body["threads"])
        
        # Apply ConfigMap update
        core_v1.patch_namespaced_config_map("embedding-config", namespace, cm)
        
        # Trigger rollout restart
        deploy = apps_v1.read_namespaced_deployment("embedding", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_deployment("embedding", namespace, deploy)
        
        logger.info(f"Embedding config updated: {body}")
        return {"status": "updated", "config": body, "message": "Embedding pod is restarting with new config"}
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to update embedding config: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
