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

import asyncpg
import httpx
import redis.asyncio as redis
from fastapi import FastAPI, HTTPException, Request, Header, Depends, Form
from fastapi.responses import StreamingResponse, JSONResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBasic, HTTPBasicCredentials, HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
from kubernetes.config import ConfigException

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

class Config:
    # Redis connection (for rate limiting and caching)
    REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
    
    # PostgreSQL connection (for API keys and usage tracking)
    POSTGRES_HOST = os.getenv("POSTGRES_HOST", "llmapi-postgres")
    POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
    POSTGRES_DB = os.getenv("POSTGRES_DB", "llmapi")
    POSTGRES_USER = os.getenv("POSTGRES_USER", "llmapi")
    POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")
    
    # Backend URLs
    VLLM_URLS = os.getenv("VLLM_URLS", "http://vllm:8000").split(",")
    LLAMACPP_URL = os.getenv("LLAMACPP_URL", "http://llamacpp:8080")
    EMBEDDING_URL = os.getenv("EMBEDDING_URL", "http://embedding:8080")
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
    
    # Default rate limits
    DEFAULT_REQUESTS_PER_MINUTE = int(os.getenv("DEFAULT_REQUESTS_PER_MINUTE", "60"))
    DEFAULT_TOKENS_PER_DAY = int(os.getenv("DEFAULT_TOKENS_PER_DAY", "100000"))
    
    # Concurrency cap: max simultaneous in-flight requests per API key.
    # Scales with GPU count: each GPU safely handles ~4 concurrent LLM requests.
    # Override via env: CONCURRENCY_PER_KEY_DEFAULT / CONCURRENCY_PER_GPU
    CONCURRENCY_PER_GPU = int(os.getenv("CONCURRENCY_PER_GPU", "4"))
    CONCURRENCY_PER_KEY_DEFAULT = int(os.getenv("CONCURRENCY_PER_KEY_DEFAULT", "4"))
    
    # Tokens-per-minute limit (TPM) — more accurate than RPM for LLMs.
    # A 4096-token request costs ~40x more than a 100-token request.
    DEFAULT_TOKENS_PER_MINUTE = int(os.getenv("DEFAULT_TOKENS_PER_MINUTE", "40000"))
    
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

CONCURRENCY_REJECTED = Counter(
    "llmapi_concurrency_rejected_total",
    "Requests rejected due to per-key concurrency cap",
    ["endpoint"]
)

TPM_REJECTED = Counter(
    "llmapi_tpm_rejected_total",
    "Requests rejected due to tokens-per-minute limit",
    ["endpoint"]
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
# PostgreSQL Client
# =============================================================================

class PostgresClient:
    """PostgreSQL client for API keys, usage logs, and model configs."""
    
    def __init__(self):
        self.pool: Optional[asyncpg.Pool] = None
        self._reconnect_lock = asyncio.Lock()
    
    async def connect(self):
        """Connect to PostgreSQL and initialize schema."""
        try:
            self.pool = await asyncpg.create_pool(
                host=config.POSTGRES_HOST,
                port=config.POSTGRES_PORT,
                database=config.POSTGRES_DB,
                user=config.POSTGRES_USER,
                password=config.POSTGRES_PASSWORD,
                min_size=2,
                max_size=10,
                command_timeout=60
            )
            logger.info(f"Connected to PostgreSQL at {config.POSTGRES_HOST}:{config.POSTGRES_PORT}")
            await self._init_schema()
        except Exception as e:
            logger.error(f"Failed to connect to PostgreSQL: {e}")
            raise
    
    async def _reconnect(self):
        """Recreate the connection pool after a failure (e.g. Postgres pod restart)."""
        async with self._reconnect_lock:
            # Another coroutine may have already reconnected while we waited
            try:
                if self.pool:
                    await self.pool.close()
            except Exception:
                pass
            self.pool = None
            for attempt in range(1, 6):
                try:
                    self.pool = await asyncpg.create_pool(
                        host=config.POSTGRES_HOST,
                        port=config.POSTGRES_PORT,
                        database=config.POSTGRES_DB,
                        user=config.POSTGRES_USER,
                        password=config.POSTGRES_PASSWORD,
                        min_size=2,
                        max_size=10,
                        command_timeout=60
                    )
                    logger.info(f"Reconnected to PostgreSQL (attempt {attempt})")
                    await self._init_schema()
                    return
                except Exception as e:
                    logger.warning(f"PostgreSQL reconnect attempt {attempt}/5 failed: {e}")
                    await asyncio.sleep(5 * attempt)
            logger.error("All PostgreSQL reconnect attempts failed")
    
    async def _execute_with_retry(self, fn):
        """Execute an async DB function, reconnecting once if the pool is broken."""
        for attempt in range(2):
            try:
                if self.pool is None:
                    await self._reconnect()
                return await fn()
            except (OSError, asyncpg.exceptions.ConnectionDoesNotExistError,
                    asyncpg.exceptions.InterfaceError,
                    asyncpg.exceptions.TooManyConnectionsError) as e:
                if attempt == 0:
                    logger.warning(f"PostgreSQL connection lost ({e}), reconnecting...")
                    await self._reconnect()
                else:
                    logger.error(f"PostgreSQL operation failed after reconnect: {e}")
                    raise
    
    async def close(self):
        """Close PostgreSQL connection pool."""
        if self.pool:
            await self.pool.close()
            logger.info("Closed PostgreSQL connection")
    
    async def _init_schema(self):
        """Initialize database schema if not exists."""
        async with self.pool.acquire() as conn:
            # Create api_keys table
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS api_keys (
                    api_key VARCHAR(255) PRIMARY KEY,
                    name VARCHAR(255) NOT NULL,
                    scopes TEXT[] NOT NULL DEFAULT '{inference}',
                    requests_per_minute INTEGER NOT NULL DEFAULT 60,
                    tokens_per_day INTEGER NOT NULL DEFAULT 100000,
                    tokens_per_minute INTEGER NOT NULL DEFAULT 40000,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    revoked BOOLEAN NOT NULL DEFAULT FALSE
                )
            """)
            # Migration: add tokens_per_minute to existing installs that predate this column
            await conn.execute("""
                ALTER TABLE api_keys
                ADD COLUMN IF NOT EXISTS tokens_per_minute INTEGER NOT NULL DEFAULT 40000
            """)
            
            # Create usage_logs table
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS usage_logs (
                    id BIGSERIAL PRIMARY KEY,
                    api_key VARCHAR(255) NOT NULL,
                    date DATE NOT NULL,
                    hour INTEGER NOT NULL CHECK (hour >= 0 AND hour < 24),
                    input_tokens BIGINT NOT NULL DEFAULT 0,
                    output_tokens BIGINT NOT NULL DEFAULT 0,
                    requests INTEGER NOT NULL DEFAULT 0,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    UNIQUE(api_key, date, hour)
                )
            """)
            
            # Create indexes
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_usage_logs_api_key_date 
                ON usage_logs(api_key, date DESC)
            """)
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_api_keys_created_at 
                ON api_keys(created_at DESC)
            """)
            
            logger.info("PostgreSQL schema initialized")
    
    async def get_api_key_config(self, api_key: str) -> Optional[dict]:
        """Get API key configuration."""
        async def _query():
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow("""
                    SELECT api_key, name, scopes, requests_per_minute, tokens_per_day,
                           tokens_per_minute, created_at, revoked
                    FROM api_keys
                    WHERE api_key = $1 AND revoked = FALSE
                """, api_key)
                if row:
                    return {
                        "name": row["name"],
                        "scopes": list(row["scopes"]),
                        "requests_per_minute": row["requests_per_minute"],
                        "tokens_per_day": row["tokens_per_day"],
                        "tokens_per_minute": row["tokens_per_minute"],
                        "created_at": row["created_at"].isoformat(),
                    }
                return None
        try:
            return await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error fetching API key config: {e}")
            return None
    
    async def set_api_key_config(self, api_key: str, config_data: dict):
        """Create or update API key configuration."""
        async def _query():
            async with self.pool.acquire() as conn:
                await conn.execute("""
                    INSERT INTO api_keys (api_key, name, scopes, requests_per_minute, 
                                         tokens_per_day, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, $5, $6, NOW())
                    ON CONFLICT (api_key) 
                    DO UPDATE SET 
                        name = EXCLUDED.name,
                        scopes = EXCLUDED.scopes,
                        requests_per_minute = EXCLUDED.requests_per_minute,
                        tokens_per_day = EXCLUDED.tokens_per_day,
                        updated_at = NOW()
                """,
                    api_key,
                    config_data.get("name", "unnamed"),
                    config_data.get("scopes", ["inference"]),
                    config_data.get("requests_per_minute", 60),
                    config_data.get("tokens_per_day", 100000),
                    datetime.fromisoformat(config_data.get("created_at", datetime.utcnow().isoformat()))
                )
        try:
            await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error setting API key config: {e}")
            raise
    
    async def delete_api_key(self, api_key: str):
        """Mark API key as revoked."""
        async def _query():
            async with self.pool.acquire() as conn:
                await conn.execute("""
                    UPDATE api_keys 
                    SET revoked = TRUE, updated_at = NOW()
                    WHERE api_key = $1
                """, api_key)
        try:
            await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error deleting API key: {e}")
            raise
    
    async def list_api_keys(self, prefix: str = "sk-mynodeone-") -> list[dict]:
        """List all non-revoked API keys with given prefix."""
        async def _query():
            async with self.pool.acquire() as conn:
                rows = await conn.fetch("""
                    SELECT api_key, name, scopes, requests_per_minute, tokens_per_day, created_at
                    FROM api_keys
                    WHERE api_key LIKE $1 AND revoked = FALSE
                    ORDER BY created_at DESC
                """, f"{prefix}%")
                return [
                    {
                        "key": row["api_key"],
                        "name": row["name"],
                        "scopes": list(row["scopes"]),
                        "requests_per_minute": row["requests_per_minute"],
                        "tokens_per_day": row["tokens_per_day"],
                        "created_at": row["created_at"].isoformat(),
                    }
                    for row in rows
                ]
        try:
            return await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error listing API keys: {e}")
            return []
    
    async def add_token_usage(self, api_key: str, input_tokens: int, output_tokens: int):
        """Track token usage (hourly aggregation)."""
        now = datetime.utcnow()
        today = now.date()
        hour = now.hour
        async def _query():
            async with self.pool.acquire() as conn:
                await conn.execute("""
                    INSERT INTO usage_logs (api_key, date, hour, input_tokens, output_tokens, requests, updated_at)
                    VALUES ($1, $2, $3, $4, $5, 1, NOW())
                    ON CONFLICT (api_key, date, hour)
                    DO UPDATE SET
                        input_tokens = usage_logs.input_tokens + EXCLUDED.input_tokens,
                        output_tokens = usage_logs.output_tokens + EXCLUDED.output_tokens,
                        requests = usage_logs.requests + 1,
                        updated_at = NOW()
                """, api_key, today, hour, input_tokens, output_tokens)
        try:
            await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error adding token usage: {e}")
            # Don't raise - usage tracking failures shouldn't block requests
    
    async def get_token_usage(self, api_key: str) -> tuple[int, int]:
        """Get today's token usage for an API key."""
        today = datetime.utcnow().date()
        async def _query():
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow("""
                    SELECT 
                        COALESCE(SUM(input_tokens), 0) as input_total,
                        COALESCE(SUM(output_tokens), 0) as output_total
                    FROM usage_logs
                    WHERE api_key = $1 AND date = $2
                """, api_key, today)
                if row:
                    return int(row["input_total"]), int(row["output_total"])
                return 0, 0
        try:
            return await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error getting token usage: {e}")
            return 0, 0
    
    async def check_token_quota(self, api_key: str, daily_limit: int) -> bool:
        """Check if within daily token quota."""
        input_tokens, output_tokens = await self.get_token_usage(api_key)
        return (input_tokens + output_tokens) < daily_limit
    
    async def get_usage_stats(self, api_key: str, days: int = 7) -> dict:
        """Get usage statistics for an API key over the last N days."""
        start_date = datetime.utcnow().date() - timedelta(days=days)
        async def _query():
            async with self.pool.acquire() as conn:
                rows = await conn.fetch("""
                    SELECT date, hour,
                        SUM(input_tokens) as input_tokens,
                        SUM(output_tokens) as output_tokens,
                        SUM(requests) as requests
                    FROM usage_logs
                    WHERE api_key = $1 AND date >= $2
                    GROUP BY date, hour
                    ORDER BY date DESC, hour DESC
                """, api_key, start_date)
                return {
                    "api_key": api_key,
                    "period_days": days,
                    "hourly_data": [
                        {
                            "date": row["date"].isoformat(),
                            "hour": row["hour"],
                            "input_tokens": row["input_tokens"],
                            "output_tokens": row["output_tokens"],
                            "requests": row["requests"],
                        }
                        for row in rows
                    ]
                }
        try:
            return await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error getting usage stats: {e}")
            return {"api_key": api_key, "period_days": days, "hourly_data": []}
    
    async def get_all_keys_stats(self) -> dict:
        """Get aggregate statistics for all API keys."""
        today = datetime.utcnow().date()
        async def _query():
            async with self.pool.acquire() as conn:
                summary_row = await conn.fetchrow("""
                    SELECT 
                        COALESCE(SUM(input_tokens + output_tokens), 0) as total_tokens,
                        COALESCE(SUM(requests), 0) as total_requests
                    FROM usage_logs
                    WHERE date = $1
                """, today)
                active_keys = await conn.fetchval("""
                    SELECT COUNT(DISTINCT api_key)
                    FROM usage_logs
                    WHERE date = $1
                """, today)
                key_rows = await conn.fetch("""
                    SELECT 
                        u.api_key,
                        k.name,
                        SUM(u.input_tokens + u.output_tokens) as tokens_today,
                        SUM(u.requests) as requests_today,
                        k.tokens_per_day as tokens_limit,
                        k.requests_per_minute as rpm_limit
                    FROM usage_logs u
                    JOIN api_keys k ON u.api_key = k.api_key
                    WHERE u.date = $1 AND k.revoked = FALSE
                    GROUP BY u.api_key, k.name, k.tokens_per_day, k.requests_per_minute
                    ORDER BY tokens_today DESC
                """, today)
                hourly_rows = await conn.fetch("""
                    SELECT 
                        date, hour,
                        SUM(input_tokens + output_tokens) as tokens,
                        SUM(requests) as requests
                    FROM usage_logs
                    WHERE date >= $1
                    GROUP BY date, hour
                    ORDER BY date DESC, hour DESC
                    LIMIT 24
                """, today - timedelta(days=1))
                return {
                    "summary": {
                        "total_tokens_today": int(summary_row["total_tokens"]),
                        "total_requests_today": int(summary_row["total_requests"]),
                        "active_keys": int(active_keys or 0),
                    },
                    "by_key": [
                        {
                            "name": row["name"],
                            "api_key_preview": row["api_key"][:16] + "...",
                            "tokens_today": int(row["tokens_today"]),
                            "tokens_limit": int(row["tokens_limit"]),
                            "requests_today": int(row["requests_today"]),
                            "rpm_limit": int(row["rpm_limit"]),
                        }
                        for row in key_rows
                    ],
                    "by_hour": [
                        {
                            "hour": f"{row['hour']:02d}:00",
                            "tokens": int(row["tokens"]),
                            "requests": int(row["requests"]),
                        }
                        for row in hourly_rows
                    ]
                }
        try:
            return await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error getting all keys stats: {e}")
            return {"summary": {"total_tokens_today": 0, "total_requests_today": 0, "active_keys": 0}, "by_key": [], "by_hour": []}


postgres_client = PostgresClient()

# =============================================================================
# Redis Client
# =============================================================================

class RedisClient:
    def __init__(self):
        self.client: Optional[redis.Redis] = None
        self._reconnect_lock = asyncio.Lock()
    
    async def connect(self):
        self.client = redis.from_url(config.REDIS_URL, decode_responses=True)
        logger.info(f"Connected to Redis at {config.REDIS_URL}")
    
    async def close(self):
        if self.client:
            await self.client.close()
    
    async def _reconnect(self):
        """Recreate the Redis client after a connection failure."""
        async with self._reconnect_lock:
            try:
                if self.client:
                    await self.client.close()
            except Exception:
                pass
            for attempt in range(1, 6):
                try:
                    self.client = redis.from_url(config.REDIS_URL, decode_responses=True)
                    # Ping to confirm the connection is live
                    await self.client.ping()
                    logger.info(f"Reconnected to Redis (attempt {attempt})")
                    return
                except Exception as e:
                    logger.warning(f"Redis reconnect attempt {attempt}/5 failed: {e}")
                    await asyncio.sleep(3 * attempt)
            logger.error("All Redis reconnect attempts failed; running without Redis")
            self.client = None
    
    async def _safe(self, coro_fn, default=None):
        """Execute a Redis coroutine, reconnecting once on failure.
        
        Returns `default` if Redis is unavailable so callers can fail-open
        (rate limiting skipped, cache miss, etc.) rather than crashing.
        """
        for attempt in range(2):
            if self.client is None:
                # Redis was previously marked down; try to recover.
                await self._reconnect()
                if self.client is None:
                    return default
            try:
                return await coro_fn()
            except (redis.exceptions.ConnectionError,
                    redis.exceptions.TimeoutError,
                    ConnectionRefusedError,
                    OSError) as e:
                if attempt == 0:
                    logger.warning(f"Redis connection lost ({e}), reconnecting...")
                    await self._reconnect()
                else:
                    logger.error(f"Redis operation failed after reconnect: {e}")
                    return default
            except Exception as e:
                logger.error(f"Redis unexpected error: {e}")
                return default
        return default
    
    async def check_rate_limit_with_info(self, api_key: str, requests_per_minute: int) -> tuple[bool, int]:
        """Check RPM limit. Returns (allowed, retry_after_seconds).
        
        Fails OPEN (allows request) if Redis is unavailable so a Redis pod
        crash does not block all inference traffic.
        """
        key = f"ratelimit:{api_key}:rpm"
        async def _fn():
            pipe = self.client.pipeline()
            pipe.get(key)
            pipe.ttl(key)
            current_str, ttl = await pipe.execute()
            current = int(current_str) if current_str else 0
            if current >= requests_per_minute:
                return False, max(1, ttl)
            pipe2 = self.client.pipeline()
            pipe2.incr(key)
            pipe2.expire(key, 60)
            await pipe2.execute()
            return True, 0
        result = await self._safe(_fn, default=(True, 0))  # fail-open
        return result

    async def check_tpm_limit(self, api_key: str, estimated_tokens: int, tokens_per_minute: int) -> tuple[bool, int]:
        """Check TPM limit using a sliding 60-second window. Returns (allowed, retry_after_seconds).
        
        Charges estimated_tokens against the window.  Actual output tokens are
        charged separately after completion via add_tpm_usage().
        Fails OPEN if Redis is unavailable.
        """
        key = f"ratelimit:{api_key}:tpm"
        async def _fn():
            pipe = self.client.pipeline()
            pipe.get(key)
            pipe.ttl(key)
            current_str, ttl = await pipe.execute()
            current = int(current_str) if current_str else 0
            if current + estimated_tokens > tokens_per_minute:
                return False, max(1, ttl)
            pipe2 = self.client.pipeline()
            pipe2.incrby(key, estimated_tokens)
            pipe2.expire(key, 60)
            await pipe2.execute()
            return True, 0
        return await self._safe(_fn, default=(True, 0))  # fail-open

    async def add_tpm_usage(self, api_key: str, output_tokens: int) -> None:
        """Charge output tokens to the TPM window after a request completes."""
        key = f"ratelimit:{api_key}:tpm"
        async def _fn():
            pipe = self.client.pipeline()
            pipe.incrby(key, output_tokens)
            pipe.expire(key, 60)
            await pipe.execute()
        await self._safe(_fn)

    async def get_rate_limit_info(self, api_key: str) -> tuple[int, int]:
        """Get current RPM usage and TTL."""
        rpm_key = f"ratelimit:{api_key}:rpm"
        async def _fn():
            current_rpm = await self.client.get(rpm_key) or 0
            ttl = await self.client.ttl(rpm_key)
            return int(current_rpm), max(0, ttl)
        return await self._safe(_fn, default=(0, 0))
    
    async def enqueue_request(self, priority: str, request_id: str, data: dict):
        """Add request to priority queue."""
        queue_key = f"queue:{priority}"
        async def _fn():
            await self.client.zadd(queue_key, {request_id: time.time()})
            await self.client.set(f"request:{request_id}", json.dumps(data), ex=3600)
            QUEUE_DEPTH.labels(priority=priority).inc()
        await self._safe(_fn)
    
    async def dequeue_request(self, priority: str) -> Optional[tuple[str, dict]]:
        """Get next request from queue."""
        queue_key = f"queue:{priority}"
        async def _fn():
            result = await self.client.zpopmin(queue_key)
            if result:
                request_id = result[0][0]
                data = await self.client.get(f"request:{request_id}")
                await self.client.delete(f"request:{request_id}")
                QUEUE_DEPTH.labels(priority=priority).dec()
                if data:
                    return request_id, json.loads(data)
            return None
        return await self._safe(_fn, default=None)
    
    async def cache_response(self, cache_key: str, response: str, ttl: int = 3600):
        """Cache a response."""
        async def _fn():
            await self.client.set(f"cache:{cache_key}", response, ex=ttl)
        await self._safe(_fn)
    
    async def get_cached_response(self, cache_key: str) -> Optional[str]:
        """Get cached response."""
        async def _fn():
            return await self.client.get(f"cache:{cache_key}")
        return await self._safe(_fn, default=None)
    
    async def get_api_key_config(self, api_key: str) -> Optional[dict]:
        """Get API key configuration."""
        async def _fn():
            data = await self.client.get(f"apikey:{api_key}")
            if data:
                return json.loads(data)
            return None
        return await self._safe(_fn, default=None)
    
    async def set_api_key_config(self, api_key: str, config: dict):
        """Set API key configuration."""
        async def _fn():
            await self.client.set(f"apikey:{api_key}", json.dumps(config))
        await self._safe(_fn)

    async def delete_api_key_config(self, api_key: str):
        """Delete API key configuration from Redis cache."""
        async def _fn():
            await self.client.delete(f"apikey:{api_key}")
        await self._safe(_fn)

    async def get_value(self, key: str, default=None):
        """Get a generic Redis key with reconnect/fallback handling."""
        async def _fn():
            return await self.client.get(key)
        return await self._safe(_fn, default=default)

    async def set_value(self, key: str, value, ex: Optional[int] = None):
        """Set a generic Redis key with reconnect/fallback handling."""
        async def _fn():
            if ex is None:
                await self.client.set(key, value)
            else:
                await self.client.set(key, value, ex=ex)
        await self._safe(_fn)


redis_client = RedisClient()

# =============================================================================
# Rate Limiter  (enterprise pattern: immediate 429, no server-side queuing)
# =============================================================================

class RateLimiter:
    """
    Enterprise-grade rate limiting following the pattern used by OpenAI,
    Anthropic, and Azure OpenAI:

      1. RPM  — requests per minute per key (sliding window via Redis INCR/EXPIRE)
      2. TPM  — tokens per minute per key   (sliding window, charged on completion)
      3. Concurrency — max simultaneous in-flight requests per key
                       scales automatically with the number of healthy GPU backends

    All limits return HTTP 429 immediately with a structured error body and
    an accurate Retry-After header.  No server-side queuing — the client SDK
    (openai-python, etc.) handles exponential backoff, which is the universal
    standard across every major LLM provider.

    Why no server-side queue?
      - Each waiting coroutine holds a uvicorn worker slot + Redis connection.
      - A DDoS / runaway client can exhaust all worker slots before the GPU
        is ever touched.
      - The client already has retry logic; duplicating it server-side wastes
        resources and adds latency unpredictability.
    """

    # In-process concurrency counters: {api_key: current_inflight}
    # Redis is NOT used here — in-process is sufficient because each gateway
    # pod tracks its own share; the concurrency cap is per-pod intentionally
    # (a 2-replica gateway effectively doubles the global cap, matching the
    # fact that 2 pods can serve 2x as many requests).
    _inflight: dict[str, int] = {}
    _lock = asyncio.Lock()

    def _healthy_gpu_count(self) -> int:
        """Count healthy GPU (vLLM) backends to scale concurrency cap.
        
        Defensive: returns 1 (not 0) if backend_manager is not yet initialised
        or its health dict is empty, so the cap is never accidentally zero.
        """
        try:
            count = sum(
                1 for key, healthy in backend_manager.backend_health.items()
                if key.startswith("vllm:") and healthy
            )
            return max(1, count)
        except Exception:
            return 1  # safe default during startup / health-check races

    def _concurrency_cap(self, key_config: dict) -> int:
        """Per-key concurrency cap, scaled by healthy GPU count.
        
        Values coming from Redis JSON may be strings; int() coercion is applied.
        Clamped to [1, 256] to prevent misconfiguration from opening unlimited slots.
        """
        try:
            raw = key_config.get(
                "concurrency_per_key",
                config.CONCURRENCY_PER_KEY_DEFAULT * self._healthy_gpu_count()
            )
            return max(1, min(256, int(raw)))
        except (TypeError, ValueError):
            return config.CONCURRENCY_PER_KEY_DEFAULT

    def _safe_int(self, value, default: int, min_val: int = 1, max_val: int = 10_000_000) -> int:
        """Coerce a value from key_config (may be str from Redis JSON) to int,
        clamped to [min_val, max_val].  Returns default on any error."""
        try:
            return max(min_val, min(max_val, int(value)))
        except (TypeError, ValueError):
            return default

    async def check_and_acquire(
        self,
        api_key: str,
        key_config: dict,
        estimated_prompt_tokens: int,
        endpoint: str,
        model: str,
        priority: str,
    ) -> None:
        """
        Run all three checks in order.  Raises HTTPException(429) immediately
        on the first violation with a structured body and Retry-After header.
        On success, increments the in-flight counter (caller MUST call release()).

        Defensive guarantees:
          - If any unexpected exception occurs AFTER the concurrency counter has
            been incremented, it is decremented before re-raising so the counter
            never leaks.
          - All config values are coerced and clamped; bad data in Redis cannot
            produce a zero limit or an integer overflow.
          - Redis failures in RPM/TPM checks fail-open (allow the request) so a
            Redis outage does not block inference.
        """
        # Coerce all limits — key_config values from Redis JSON may be strings
        rpm_limit = self._safe_int(
            key_config.get("requests_per_minute", config.DEFAULT_REQUESTS_PER_MINUTE),
            default=config.DEFAULT_REQUESTS_PER_MINUTE, min_val=1, max_val=100_000
        )
        tpm_limit = self._safe_int(
            key_config.get("tokens_per_minute", config.DEFAULT_TOKENS_PER_MINUTE),
            default=config.DEFAULT_TOKENS_PER_MINUTE, min_val=1, max_val=10_000_000
        )
        estimated_prompt_tokens = max(0, int(estimated_prompt_tokens))
        concurrency_cap = self._concurrency_cap(key_config)
        acquired = False

        try:
            # --- 1. Concurrency cap (cheapest check, no Redis, no network) ---
            async with self._lock:
                current = self._inflight.get(api_key, 0)
                if current >= concurrency_cap:
                    CONCURRENCY_REJECTED.labels(endpoint=endpoint).inc()
                    REQUEST_COUNT.labels(model=model, priority=priority, status="concurrency_exceeded", endpoint=endpoint).inc()
                    raise HTTPException(
                        status_code=429,
                        detail={
                            "error": {"type": "concurrency_limit_exceeded",
                                      "message": f"You have {current} requests in-flight. "
                                                 f"Limit is {concurrency_cap} (scales with GPU count: "
                                                 f"{self._healthy_gpu_count()} GPU(s) \u00d7 {config.CONCURRENCY_PER_GPU} slots). "
                                                 f"Retry in ~5s when an in-flight request completes.",
                                      "current_inflight": current,
                                      "limit": concurrency_cap,
                                      "retry_after": 5},
                        },
                        headers={"Retry-After": "5"},
                    )
                self._inflight[api_key] = current + 1
                acquired = True

            # --- 2. RPM check (Redis sliding window, fails-open on Redis error) ---
            try:
                rpm_ok, retry_after_rpm = await redis_client.check_rate_limit_with_info(api_key, rpm_limit)
            except Exception as e:
                logger.warning(f"RPM check failed for {api_key[:16]}… (fail-open): {e}")
                rpm_ok, retry_after_rpm = True, 0

            if not rpm_ok:
                REQUEST_COUNT.labels(model=model, priority=priority, status="rate_limited", endpoint=endpoint).inc()
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": {"type": "rate_limit_exceeded",
                                  "message": f"Rate limit exceeded: {rpm_limit} requests/minute. "
                                             f"Retry in {retry_after_rpm}s.",
                                  "limit": rpm_limit,
                                  "retry_after": retry_after_rpm},
                    },
                    headers={"Retry-After": str(retry_after_rpm)},
                )

            # --- 3. TPM check (Redis sliding window, fails-open on Redis error) ---
            try:
                tpm_ok, retry_after_tpm = await redis_client.check_tpm_limit(api_key, estimated_prompt_tokens, tpm_limit)
            except Exception as e:
                logger.warning(f"TPM check failed for {api_key[:16]}… (fail-open): {e}")
                tpm_ok, retry_after_tpm = True, 0

            if not tpm_ok:
                TPM_REJECTED.labels(endpoint=endpoint).inc()
                REQUEST_COUNT.labels(model=model, priority=priority, status="tpm_exceeded", endpoint=endpoint).inc()
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": {"type": "tokens_per_minute_exceeded",
                                  "message": f"Token rate limit exceeded: {tpm_limit} tokens/minute. "
                                             f"Retry in {retry_after_tpm}s.",
                                  "limit": tpm_limit,
                                  "estimated_prompt_tokens": estimated_prompt_tokens,
                                  "retry_after": retry_after_tpm},
                    },
                    headers={"Retry-After": str(retry_after_tpm)},
                )

        except HTTPException:
            # Release counter if we acquired it but a limit check failed
            if acquired:
                async with self._lock:
                    self._inflight[api_key] = max(0, self._inflight.get(api_key, 1) - 1)
            raise
        except Exception as e:
            # Unexpected error: release counter and fail-open (log + allow)
            if acquired:
                async with self._lock:
                    self._inflight[api_key] = max(0, self._inflight.get(api_key, 1) - 1)
            logger.error(f"Unexpected error in rate limiter check_and_acquire: {e}", exc_info=True)
            # Fail-open: do not block inference due to rate-limiter bugs

    async def release(self, api_key: str) -> None:
        """Decrement in-flight counter after request completes or errors.
        
        Safe to call multiple times — counter is clamped to 0.
        Swallows all exceptions so a release failure never crashes a request handler.
        """
        try:
            async with self._lock:
                self._inflight[api_key] = max(0, self._inflight.get(api_key, 1) - 1)
        except Exception as e:
            logger.error(f"Failed to release rate-limiter counter for {api_key[:16]}…: {e}")

    def get_inflight(self) -> dict[str, int]:
        """Return current per-key in-flight counts (zero-value keys excluded)."""
        return {k: v for k, v in self._inflight.items() if v > 0}


rate_limiter = RateLimiter()

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
                # Try to get actual model name from MODEL_FILE env var
                model_file = os.getenv("EMBEDDING_MODEL_FILE", "")
                if model_file:
                    # Extract model name from filename (e.g., "nomic-embed-text-v1.5.Q8_0.gguf" -> "nomic-embed-text-v1.5")
                    model_name = model_file.rsplit('.', 2)[0] if '.' in model_file else model_file
                else:
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
        
        if not backend_type or not url:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": "No healthy backend available",
                    "hint": "All inference backends are currently unhealthy. Check /health/backends for status."
                }
            )
        
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
                        except Exception:
                            pass  # If parsing fails, send original chunk
                    yield chunk
        finally:
            self.backend_inflight[backend_key] = max(0, self.backend_inflight.get(backend_key, 0) - 1)
            BACKEND_INFLIGHT.labels(backend=backend_type).dec()


backend_manager = BackendManager()

# =============================================================================
# Authentication
# =============================================================================

# HTTPBearer security scheme for proper OpenAPI/Swagger integration
security = HTTPBearer()

async def get_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    """Extract and validate API key from Authorization header.
    
    Auth path: Redis cache first (fast) → Postgres fallback (authoritative).
    On a Redis cache miss the key is written back so subsequent requests are fast.
    This means auth survives a Postgres pod restart (Redis serves the cached copy)
    and also survives a Redis pod restart (Postgres re-warms the cache on next hit).
    """
    api_key = credentials.credentials
    
    # 1. Try Redis cache first
    key_config = await redis_client.get_api_key_config(api_key)
    if key_config:
        return api_key
    
    # 2. Cache miss - check Postgres (authoritative source)
    key_config = await postgres_client.get_api_key_config(api_key)
    if not key_config:
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    # 3. Write back to Redis cache for future requests
    await redis_client.set_api_key_config(api_key, key_config)
    return api_key



async def require_scope(required_scope: str, api_key: str) -> str:
    """Verify API key has required scope."""
    key_config = await redis_client.get_api_key_config(api_key) or await postgres_client.get_api_key_config(api_key)
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

async def warm_redis_from_postgres():
    """Load all active API keys from Postgres into Redis cache.
    
    Called on startup and periodically so Redis always has a fresh
    copy of every key.  This means auth survives a Redis restart
    (next request re-warms the cache) and also means the gateway
    keeps working even if Postgres is briefly unreachable (Redis
    serves the cached copy).
    """
    try:
        keys = await postgres_client.list_api_keys()
        if not keys:
            logger.warning("warm_redis_from_postgres: no keys found in Postgres")
            return
        for k in keys:
            config_data = {
                "name": k["name"],
                "scopes": k["scopes"],
                "requests_per_minute": k["requests_per_minute"],
                "tokens_per_day": k["tokens_per_day"],
                "created_at": k["created_at"],
            }
            await redis_client.set_api_key_config(k["key"], config_data)
        logger.info(f"warm_redis_from_postgres: cached {len(keys)} key(s) in Redis")
    except Exception as e:
        logger.error(f"warm_redis_from_postgres failed: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup
    await postgres_client.connect()
    await redis_client.connect()
    await backend_manager.start()
    
    # Pre-populate Redis with all API keys from Postgres so auth
    # works immediately even if Postgres becomes temporarily unavailable
    await warm_redis_from_postgres()
    
    # Start background health check
    async def health_check_loop():
        while True:
            try:
                await backend_manager.health_check()
            except Exception as e:
                logger.error(f"Health check failed: {e}")
            await asyncio.sleep(30)
    
    # Periodically re-sync Postgres → Redis (every 5 minutes)
    # Handles: Redis pod restart (cache wiped), new keys added via psql/manage-keys.sh
    async def postgres_redis_sync_loop():
        while True:
            await asyncio.sleep(300)
            await warm_redis_from_postgres()
    
    health_task = asyncio.create_task(health_check_loop())
    sync_task = asyncio.create_task(postgres_redis_sync_loop())
    
    yield
    
    # Shutdown
    health_task.cancel()
    sync_task.cancel()
    await postgres_client.close()
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
        "rate_limiter": {
            "per_key_inflight": rate_limiter.get_inflight(),
            "healthy_gpus": rate_limiter._healthy_gpu_count(),
            "concurrency_cap_per_key": rate_limiter._concurrency_cap({}),
        },
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
    
    # Get key config - Redis cache first (already warmed by get_api_key auth), Postgres fallback
    key_config = (
        await redis_client.get_api_key_config(api_key)
        or await postgres_client.get_api_key_config(api_key)
        or {
            "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
            "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
        }
    )
    
    # Estimate prompt tokens (word count × 1.3 is a fast approximation)
    estimated_prompt_tokens = int(sum(len(m.content.split()) * 1.3 for m in request.messages))

    # Rate limit checks: concurrency → RPM → TPM (immediate 429, no server-side queuing)
    await rate_limiter.check_and_acquire(api_key, key_config, estimated_prompt_tokens, "chat", model, priority)

    # Check token quota
    if not await postgres_client.check_token_quota(api_key, key_config["tokens_per_day"]):
        await rate_limiter.release(api_key)
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
                await postgres_client.add_token_usage(api_key, input_tokens, total_output_tokens)
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
            await postgres_client.add_token_usage(api_key, input_tokens, output_tokens)
            await redis_client.add_tpm_usage(api_key, output_tokens)  # charge actual output tokens to TPM window
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
    finally:
        await rate_limiter.release(api_key)


@app.post("/v1/completions")
async def completions(
    request: CompletionRequest,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible completions endpoint."""
    start_time = time.time()
    model = config.MODEL_ALIASES.get(request.model, request.model)
    
    # Get key config - Redis cache first, Postgres fallback
    key_config = (
        await redis_client.get_api_key_config(api_key)
        or await postgres_client.get_api_key_config(api_key)
        or {
            "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
            "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
        }
    )
    
    # Estimate prompt tokens
    estimated_prompt_tokens = int(len(request.prompt.split()) * 1.3)

    # Rate limit checks: concurrency → RPM → TPM (immediate 429, no server-side queuing)
    await rate_limiter.check_and_acquire(api_key, key_config, estimated_prompt_tokens, "completions", model, priority)

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
    finally:
        await rate_limiter.release(api_key)


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
    
    # Get key config - Redis cache first, Postgres fallback
    key_config = (
        await redis_client.get_api_key_config(api_key)
        or await postgres_client.get_api_key_config(api_key)
        or {
            "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
            "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
        }
    )
    
    # Estimate prompt tokens
    input_list = request.input if isinstance(request.input, list) else [request.input]
    estimated_prompt_tokens = int(sum(len(t.split()) * 1.3 for t in input_list))

    # Rate limit checks: concurrency → RPM → TPM (immediate 429, no server-side queuing)
    await rate_limiter.check_and_acquire(api_key, key_config, estimated_prompt_tokens, "embeddings", model, priority)

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
            await rate_limiter.release(api_key)
            raise HTTPException(status_code=503, detail="Backend service unavailable")
    
    # Sort by original index
    cache_hits.sort(key=lambda x: x[0])
    embeddings_data = [emb for _, emb in cache_hits]
    
    # Estimate token usage
    total_tokens = sum(len(text.split()) * 2 for text in input_texts)
    await postgres_client.add_token_usage(api_key, total_tokens, 0)
    await redis_client.add_tpm_usage(api_key, total_tokens)
    TOKENS_COUNT.labels(model=model, direction="input").inc(total_tokens)
    
    duration = time.time() - start_time
    REQUEST_DURATION.labels(model=model, priority=priority, endpoint="embeddings").observe(duration)
    REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="embeddings").inc()
    
    await rate_limiter.release(api_key)
    return {
        "object": "list",
        "data": embeddings_data,
        "model": model,
        "usage": {"prompt_tokens": total_tokens, "total_tokens": total_tokens}
    }


@app.get("/v1/usage")
async def get_usage(api_key: str = Depends(get_api_key)):
    """Get current usage for API key."""
    key_config = (
        await redis_client.get_api_key_config(api_key)
        or await postgres_client.get_api_key_config(api_key)
        or {
            "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
            "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
        }
    )
    
    input_tokens, output_tokens = await postgres_client.get_token_usage(api_key)
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

        <!-- GPU Scaling & Resource Management -->
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700 mb-8">
            <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
                <i data-lucide="zap" class="w-5 h-5 text-orange-400"></i>
                GPU Scaling & Resource Management
            </h2>
            
            <!-- Cluster GPU Overview -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="server" class="w-4 h-4 text-cyan-400"></i>
                        Cluster GPU Status
                    </h3>
                    <button onclick="refreshGpuStatus()" class="text-xs text-cyan-400 hover:text-cyan-300 flex items-center gap-1">
                        <i data-lucide="refresh-cw" class="w-3 h-3"></i>
                        Refresh
                    </button>
                </div>
                <div id="cluster-gpus" class="space-y-2">
                    <p class="text-sm text-gray-400">Loading GPU information...</p>
                </div>
            </div>
            
            <!-- vLLM Scaling Control -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-green-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="cpu" class="w-4 h-4 text-green-400"></i>
                        vLLM (GPU Inference)
                    </h3>
                    <span id="vllm-replica-status" class="text-xs bg-gray-600 px-2 py-1 rounded">
                        Loading...
                    </span>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    Scale vLLM replicas to use multiple GPUs for higher throughput. Each replica uses 1 GPU.
                </p>
                
                <!-- Replica Buttons (dynamically generated based on available GPUs) -->
                <div class="flex items-center gap-3 mb-3">
                    <span class="text-sm text-gray-400">Replicas:</span>
                    <div id="vllm-replica-buttons" class="flex gap-2 flex-wrap">
                        <!-- Buttons will be dynamically generated -->
                        <button onclick="scaleVllm(0)" class="px-4 py-2 rounded text-sm font-medium transition bg-gray-600 hover:bg-gray-500">
                            0 (Off)
                        </button>
                    </div>
                </div>
                <p class="text-xs text-gray-500 mb-2">
                    Buttons adjust automatically based on available GPUs in cluster
                </p>
                
                <!-- Pod Status -->
                <div id="vllm-pods" class="mt-3 space-y-1 text-xs">
                    <!-- Dynamic pod status will be inserted here -->
                </div>
                
                <div class="mt-3 p-3 bg-gray-800 rounded text-xs text-gray-400">
                    <p><strong class="text-gray-300">💡 Tip:</strong> Each vLLM replica:</p>
                    <ul class="list-disc list-inside mt-1 ml-2 space-y-1">
                        <li>Uses 1 GPU and ~16-32 GB RAM</li>
                        <li>Takes 5-10 minutes to initialize</li>
                        <li>Automatically load balanced by gateway</li>
                        <li>Requires GPU available on cluster</li>
                    </ul>
                </div>
            </div>
            
            <!-- llamacpp Control -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4 border-l-4 border-blue-500">
                <div class="flex items-center justify-between mb-3">
                    <h3 class="font-medium flex items-center gap-2">
                        <i data-lucide="hard-drive" class="w-4 h-4 text-blue-400"></i>
                        llama.cpp (CPU - Large Models)
                    </h3>
                    <div class="flex items-center gap-3">
                        <span id="llamacpp-status-badge" class="text-xs px-2 py-1 rounded bg-gray-600">
                            Checking...
                        </span>
                        <button onclick="toggleLlamacppNew()" id="llamacpp-toggle-btn"
                                class="text-xs bg-blue-700 hover:bg-blue-600 rounded px-3 py-1.5 transition font-medium">
                            Toggle
                        </button>
                    </div>
                </div>
                <p class="text-xs text-gray-400 mb-3">
                    llama.cpp uses CPU and RAM for 70B+ models. Stop when not needed to free up ~64 GB RAM.
                </p>
                
                <div class="mt-3 p-3 bg-yellow-900 bg-opacity-30 rounded text-xs border border-yellow-600">
                    <p class="text-yellow-200"><strong>⚠️ RAM Management:</strong></p>
                    <p class="text-yellow-300 mt-1">
                        Stopping llamacpp frees ~64 GB RAM on control plane, allowing vLLM to schedule if RAM was insufficient.
                        Use this to free resources for additional GPU replicas.
                    </p>
                </div>
            </div>
            
            <!-- Quick Actions -->
            <div class="bg-gray-700 rounded-lg p-4">
                <h3 class="font-medium mb-3 flex items-center gap-2">
                    <i data-lucide="play-circle" class="w-4 h-4 text-purple-400"></i>
                    Quick Actions
                </h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <button onclick="quickAction('max-gpu')" 
                            class="bg-green-700 hover:bg-green-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="zap" class="w-4 h-4"></i>
                        Max GPU Mode (Use All GPUs)
                    </button>
                    <button onclick="quickAction('save-ram')" 
                            class="bg-blue-700 hover:bg-blue-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="save" class="w-4 h-4"></i>
                        Save RAM (Stop llamacpp)
                    </button>
                    <button onclick="quickAction('balanced')" 
                            class="bg-purple-700 hover:bg-purple-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="scale" class="w-4 h-4"></i>
                        Balanced Mode (1 GPU + CPU)
                    </button>
                    <button onclick="quickAction('stop-all')" 
                            class="bg-red-700 hover:bg-red-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="power" class="w-4 h-4"></i>
                        Stop All (Free Resources)
                    </button>
                </div>
                <p class="text-xs text-gray-500 mt-3">
                    Quick actions automatically configure backends for common usage patterns.
                </p>
            </div>
        </div>

        <!-- API Keys Management -->
        <div class="bg-gray-800 rounded-lg p-6 border border-gray-700 mb-8">
            <div class="flex items-center justify-between mb-4">
                <h2 class="text-xl font-semibold flex items-center gap-2">
                    <i data-lucide="key" class="w-5 h-5 text-yellow-400"></i>
                    API Keys
                </h2>
                <button onclick="toggleKeyVisibility()" id="toggle-keys-btn" 
                        class="bg-gray-700 hover:bg-gray-600 px-3 py-1.5 rounded text-xs flex items-center gap-2 transition">
                    <i data-lucide="eye-off" class="w-4 h-4" id="toggle-icon"></i>
                    <span id="toggle-text">Show Keys</span>
                </button>
            </div>
            
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
        
        // API Key visibility state
        let keysVisible = false;
        
        function maskKey(key) {
            if (!key) return '';
            return key.substring(0, 12) + '...' + key.substring(key.length - 4);
        }
        
        function toggleKeyVisibility() {
            keysVisible = !keysVisible;
            const toggleIcon = document.getElementById('toggle-icon');
            const toggleText = document.getElementById('toggle-text');
            const keyElements = document.querySelectorAll('.api-key-display');
            
            if (keysVisible) {
                toggleIcon.setAttribute('data-lucide', 'eye');
                toggleText.textContent = 'Hide Keys';
                keyElements.forEach(el => {
                    el.textContent = el.getAttribute('data-key');
                });
            } else {
                toggleIcon.setAttribute('data-lucide', 'eye-off');
                toggleText.textContent = 'Show Keys';
                keyElements.forEach(el => {
                    el.textContent = maskKey(el.getAttribute('data-key'));
                });
            }
            lucide.createIcons();
        }
        
        // Admin API calls with API key authentication
        async function adminFetch(url, options = {}) {
            try {
                const headers = {
                    ...options.headers,
                    'Authorization': `Bearer ${API_KEY}`
                };
                const response = await fetch(url, { 
                    ...options,
                    headers
                });
                
                // Handle authentication failures
                if (response.status === 401 || response.status === 403) {
                    localStorage.removeItem('llmapi_admin_key');
                    alert('Your API key is invalid or has been revoked. Please login again.');
                    window.location.href = '/admin';
                    return null;
                }
                
                return response;
            } catch (e) {
                console.error('API call failed:', e);
                throw e;
            }
        }
        
        // Validate API key works on page load
        async function validateApiKey() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/models`);
                if (!resp) return false; // Already redirected
                if (!resp.ok) {
                    localStorage.removeItem('llmapi_admin_key');
                    alert('Failed to validate API key. Please login again.');
                    window.location.href = '/admin';
                    return false;
                }
                return true;
            } catch (e) {
                console.error('API key validation failed:', e);
                localStorage.removeItem('llmapi_admin_key');
                alert('Failed to connect to API. Please check your connection and login again.');
                window.location.href = '/admin';
                return false;
            }
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
                if (!resp) return; // Auth failure, already redirected
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
                let html = '';
                
                // Show download status if present
                if (data.download_status) {
                    const ds = data.download_status;
                    if (ds.status === 'downloading') {
                        html += `
                            <div class="bg-blue-900/30 border border-blue-700 rounded p-3 mb-3">
                                <div class="flex items-center gap-2">
                                    <div class="animate-spin rounded-full h-4 w-4 border-2 border-blue-400 border-t-transparent"></div>
                                    <span class="text-blue-300 font-medium">Downloading: ${ds.model}</span>
                                </div>
                                <p class="text-xs text-blue-400 mt-1">This may take several minutes depending on model size...</p>
                            </div>
                        `;
                    } else if (ds.status === 'failed' && ds.error) {
                        html += `
                            <div class="bg-red-900/30 border border-red-700 rounded p-3 mb-3">
                                <div class="flex items-start gap-2">
                                    <i data-lucide="alert-circle" class="w-5 h-5 text-red-400 mt-0.5"></i>
                                    <div class="flex-1">
                                        <span class="text-red-300 font-medium block">Download Failed: ${ds.model}</span>
                                        <p class="text-sm text-red-400 mt-1">${ds.error}</p>
                                        <p class="text-xs text-red-500 mt-2">Check the model name and try again. vLLM pod is crash-looping until a valid model is configured.</p>
                                    </div>
                                </div>
                            </div>
                        `;
                    }
                }
                
                // Show loaded models
                if (data.models && data.models.length > 0) {
                    html += data.models.map(m => `
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
                } else if (!data.download_status || data.download_status.status !== 'downloading') {
                    html += '<p class="text-yellow-400">No models loaded. Use the form above to download a model.</p>';
                }
                
                list.innerHTML = html;
                lucide.createIcons();
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
        
        // GPU Scaling Functions
        async function refreshGpuStatus() {
            try {
                const gpuResp = await adminFetch(`${API_BASE}/admin/cluster/gpus`);
                if (!gpuResp) return;
                const gpuData = await gpuResp.json();
                
                const gpuContainer = document.getElementById('cluster-gpus');
                if (gpuData.gpus && gpuData.gpus.length > 0) {
                    gpuContainer.innerHTML = `
                        <div class="text-sm mb-2">
                            <strong class="text-cyan-300">Total: ${gpuData.total_gpus} GPUs</strong>
                            <span class="text-gray-400"> | Available: ${gpuData.available_gpus}</span>
                        </div>
                        ${gpuData.gpus.map(gpu => `
                            <div class="flex items-center justify-between p-2 bg-gray-800 rounded text-sm">
                                <span class="text-gray-300">${gpu.node}</span>
                                <div class="flex gap-2 items-center">
                                    <span class="text-xs text-gray-400">${gpu.total} total</span>
                                    <span class="text-xs ${gpu.available > 0 ? 'text-green-400' : 'text-yellow-400'}">
                                        ${gpu.available} available
                                    </span>
                                    ${gpu.allocated > 0 ? `<span class="text-xs text-orange-400">${gpu.allocated} in use</span>` : ''}
                                </div>
                            </div>
                        `).join('')}
                    `;
                    
                    // Dynamically generate vLLM replica buttons based on total GPUs
                    updateVllmReplicaButtons(gpuData.total_gpus);
                } else {
                    gpuContainer.innerHTML = '<p class="text-sm text-gray-400">No GPUs detected in cluster</p>';
                    updateVllmReplicaButtons(0);
                }
                
                lucide.createIcons();
            } catch (e) {
                console.error('Failed to load GPU status:', e);
                document.getElementById('cluster-gpus').innerHTML = 
                    '<p class="text-sm text-red-400">Failed to load GPU info</p>';
            }
            
            // Also refresh vLLM replica status
            await refreshVllmStatus();
        }
        
        function updateVllmReplicaButtons(totalGpus) {
            const container = document.getElementById('vllm-replica-buttons');
            if (!container) return;
            
            // Generate buttons from 0 to totalGpus (max 10 for sanity)
            const maxButtons = Math.min(totalGpus, 10);
            let buttonsHtml = '';
            
            // Button 0 (Off)
            buttonsHtml += `
                <button onclick="scaleVllm(0)" id="vllm-btn-0" 
                        class="px-4 py-2 rounded text-sm font-medium transition bg-gray-600 hover:bg-gray-500">
                    0 (Off)
                </button>
            `;
            
            // Buttons 1 to maxButtons
            for (let i = 1; i <= maxButtons; i++) {
                buttonsHtml += `
                    <button onclick="scaleVllm(${i})" id="vllm-btn-${i}"
                            class="px-4 py-2 rounded text-sm font-medium transition bg-gray-600 hover:bg-gray-500">
                        ${i} GPU${i > 1 ? 's' : ''}
                    </button>
                `;
            }
            
            container.innerHTML = buttonsHtml;
        }
        
        async function refreshVllmStatus() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/vllm/replicas`);
                if (!resp) return;
                const data = await resp.json();
                
                // Update status badge
                const badge = document.getElementById('vllm-replica-status');
                badge.textContent = `${data.ready}/${data.desired} Ready`;
                badge.className = `text-xs px-2 py-1 rounded ${
                    data.ready === data.desired && data.desired > 0 
                        ? 'bg-green-900 text-green-300' 
                        : 'bg-yellow-900 text-yellow-300'
                }`;
                
                // Update button states
                for (let i = 0; i <= 2; i++) {
                    const btn = document.getElementById(`vllm-btn-${i}`);
                    if (btn) {
                        if (i === data.desired) {
                            btn.className = 'px-4 py-2 rounded text-sm font-medium transition bg-green-700 text-white';
                        } else {
                            btn.className = 'px-4 py-2 rounded text-sm font-medium transition bg-gray-600 hover:bg-gray-500';
                        }
                    }
                }
                
                // Update pod status
                const podContainer = document.getElementById('vllm-pods');
                if (data.pods && data.pods.length > 0) {
                    podContainer.innerHTML = data.pods.map(pod => `
                        <div class="flex items-center justify-between p-2 bg-gray-800 rounded">
                            <span class="text-gray-300">${pod.name}</span>
                            <div class="flex gap-2 items-center">
                                <span class="text-gray-400">${pod.node || 'scheduling...'}</span>
                                <span class="${pod.ready ? 'text-green-400' : 'text-yellow-400'}">
                                    ${pod.phase}
                                </span>
                            </div>
                        </div>
                    `).join('');
                } else if (data.desired === 0) {
                    podContainer.innerHTML = '<p class="text-gray-500">vLLM is scaled down to 0 replicas</p>';
                } else {
                    podContainer.innerHTML = '<p class="text-gray-500">No pods found</p>';
                }
            } catch (e) {
                console.error('Failed to load vLLM status:', e);
            }
        }
        
        async function scaleVllm(replicas) {
            const message = replicas === 0 
                ? 'Scale vLLM down to 0 replicas? This will stop GPU inference and free all GPUs.'
                : `Scale vLLM to ${replicas} replica${replicas > 1 ? 's' : ''}? This requires ${replicas} available GPU${replicas > 1 ? 's' : ''} and takes 5-10 minutes to initialize.`;
            
            if (!confirm(message)) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/backend/vllm/scale`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({replicas: replicas})
                });
                
                if (resp.ok) {
                    const data = await resp.json();
                    alert(data.message || `vLLM scaling to ${replicas} replicas`);
                    await refreshGpuStatus();
                } else {
                    const data = await resp.json();
                    alert('Failed to scale vLLM: ' + (data.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed to scale vLLM: ' + e.message);
            }
        }
        
        async function toggleLlamacppNew() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/config`);
                if (!resp) return;
                const data = await resp.json();
                const isRunning = data.llamacpp_replicas > 0;
                
                const message = isRunning
                    ? 'Stop llama.cpp? This will free ~64GB RAM, allowing vLLM to schedule if RAM was insufficient.'
                    : 'Start llama.cpp? This uses ~64GB RAM for 70B models. Takes 2-5 minutes to load.';
                
                if (!confirm(message)) return;
                
                const scaleResp = await adminFetch(`${API_BASE}/admin/backend/llamacpp/scale`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({replicas: isRunning ? 0 : 1})
                });
                
                if (scaleResp.ok) {
                    alert(isRunning ? 'llamacpp stopping - RAM will be freed' : 'llamacpp starting - takes 2-5 min');
                    await refreshLlamacppStatus();
                } else {
                    const errData = await scaleResp.json();
                    alert('Failed: ' + (errData.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed: ' + e.message);
            }
        }
        
        async function refreshLlamacppStatus() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/config`);
                if (!resp) return;
                const data = await resp.json();
                
                const badge = document.getElementById('llamacpp-status-badge');
                if (data.llamacpp_replicas > 0) {
                    badge.textContent = 'Running';
                    badge.className = 'text-xs px-2 py-1 rounded bg-green-900 text-green-300';
                } else {
                    badge.textContent = 'Stopped';
                    badge.className = 'text-xs px-2 py-1 rounded bg-gray-600 text-gray-400';
                }
            } catch (e) {
                console.error('Failed to refresh llamacpp status:', e);
            }
        }
        
        async function quickAction(action) {
            try {
                // Get current GPU count
                const gpuResp = await adminFetch(`${API_BASE}/admin/cluster/gpus`);
                if (!gpuResp) return;
                const gpuData = await gpuResp.json();
                const totalGpus = gpuData.total_gpus || 0;
                
                let message = '';
                let actions = [];
                
                switch (action) {
                    case 'max-gpu':
                        if (totalGpus === 0) {
                            alert('No GPUs detected in cluster. Cannot enable Max GPU Mode.');
                            return;
                        }
                        message = `Max GPU Mode: Scale vLLM to use all ${totalGpus} available GPU${totalGpus > 1 ? 's' : ''} and stop llamacpp to free RAM. Continue?`;
                        actions = [
                            {type: 'llamacpp', replicas: 0},
                            {type: 'vllm', replicas: totalGpus}
                        ];
                        break;
                    case 'save-ram':
                        message = 'Save RAM Mode: Stop llamacpp to free ~64GB RAM. vLLM will continue running. Continue?';
                        actions = [{type: 'llamacpp', replicas: 0}];
                        break;
                    case 'balanced':
                        if (totalGpus === 0) {
                            alert('No GPUs detected in cluster. Cannot enable Balanced Mode.');
                            return;
                        }
                        message = 'Balanced Mode: 1 vLLM replica on GPU + llamacpp on CPU for large models. Continue?';
                        actions = [
                            {type: 'vllm', replicas: 1},
                            {type: 'llamacpp', replicas: 1}
                        ];
                        break;
                    case 'stop-all':
                        message = 'Stop All: Turn off vLLM and llamacpp to free all resources. Continue?';
                        actions = [
                            {type: 'vllm', replicas: 0},
                            {type: 'llamacpp', replicas: 0}
                        ];
                        break;
                }
                
                if (!confirm(message)) return;
                
                for (const act of actions) {
                    const endpoint = act.type === 'vllm' 
                        ? `${API_BASE}/admin/backend/vllm/scale`
                        : `${API_BASE}/admin/backend/llamacpp/scale`;
                    
                    await adminFetch(endpoint, {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({replicas: act.replicas})
                    });
                }
                
                alert('Quick action applied! Services are scaling...');
                setTimeout(() => {
                    refreshGpuStatus();
                    refreshLlamacppStatus();
                }, 2000);
            } catch (e) {
                alert('Failed to apply quick action: ' + e.message);
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
                            <div class="flex-1 min-w-0">
                                <div class="font-medium">${k.name}</div>
                                <code class="text-xs text-gray-400 break-all api-key-display" data-key="${k.key}">${maskKey(k.key)}</code>
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
                console.error('Failed to load keys:', e);
            }
        }
        
        async function loadStats() {
            try {
                const resp = await adminFetch(`${API_BASE}/admin/stats`);
                if (!resp) return; // Auth failure, already redirected
                const data = await resp.json();
                
                // Update stats cards with null checks
                document.getElementById('stats-total-requests').textContent = (data.summary?.total_requests_today || 0).toLocaleString();
                document.getElementById('stats-total-tokens').textContent = (data.summary?.total_tokens_today || 0).toLocaleString();
                document.getElementById('stats-active-keys').textContent = data.summary?.active_keys || 0;
                
                // Update usage by API key
                const byKeyEl = document.getElementById('stats-by-key');
                if (data.by_key && data.by_key.length > 0) {
                    byKeyEl.innerHTML = data.by_key.map(k => `
                        <div class="flex items-center justify-between bg-gray-700 rounded p-3">
                            <div class="flex-1">
                                <div class="font-medium text-sm">${k.name}</div>
                                <code class="text-xs text-gray-500">${k.api_key_preview}</code>
                            </div>
                            <div class="flex items-center gap-4 text-sm text-gray-400">
                                <span>${k.requests_today || 0} requests</span>
                                <span>${(k.tokens_today || 0).toLocaleString()} tokens</span>
                            </div>
                        </div>
                    `).join('');
                } else {
                    byKeyEl.innerHTML = '<p class="text-gray-400 text-sm">No usage data yet</p>';
                }
                
                // Update hourly chart with null checks
                const hourlyEl = document.getElementById('stats-hourly');
                if (data.by_hour && data.by_hour.length > 0) {
                    const maxReq = Math.max(...data.by_hour.map(h => h.requests || 0), 1);
                    hourlyEl.innerHTML = data.by_hour.map(h => {
                        const height = Math.max(4, ((h.requests || 0) / maxReq) * 100);
                        const title = `${h.hour}: ${h.requests || 0} requests, ${(h.tokens || 0).toLocaleString()} tokens`;
                        return `<div class="flex-1 bg-green-500 rounded-t opacity-70 hover:opacity-100 transition cursor-pointer" 
                                     style="height: ${height}%" title="${title}"></div>`;
                    }).join('');
                } else {
                    hourlyEl.innerHTML = '<div class="text-gray-400 text-center py-4">No data yet</div>';
                }
                
            } catch (e) {
                console.error('Failed to load stats:', e);
            }
        }
        
        // API Key Management Functions
        async function createKey() {
            const name = document.getElementById('key-name').value.trim();
            const rpm = parseInt(document.getElementById('key-rpm').value) || 60;
            const tokens = parseInt(document.getElementById('key-tokens').value) || 100000;
            
            // Get selected scopes
            const scopes = [];
            if (document.getElementById('scope-inference').checked) scopes.push('inference');
            if (document.getElementById('scope-metrics').checked) scopes.push('metrics');
            if (document.getElementById('scope-admin').checked) scopes.push('admin');
            
            if (!name) {
                alert('Please enter a key name');
                return;
            }
            
            if (scopes.length === 0) {
                alert('Please select at least one scope');
                return;
            }
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/keys`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        name: name,
                        requests_per_minute: rpm,
                        tokens_per_day: tokens,
                        scopes: scopes
                    })
                });
                
                if (resp.ok) {
                    const data = await resp.json();
                    const resultDiv = document.getElementById('new-key-result');
                    const keyValueEl = document.getElementById('new-key-value');
                    
                    keyValueEl.textContent = data.key;
                    resultDiv.classList.remove('hidden');
                    
                    // Clear form
                    document.getElementById('key-name').value = '';
                    document.getElementById('key-rpm').value = '60';
                    document.getElementById('key-tokens').value = '100000';
                    document.getElementById('scope-inference').checked = true;
                    document.getElementById('scope-metrics').checked = false;
                    document.getElementById('scope-admin').checked = false;
                    
                    // Reload keys list
                    loadKeys();
                    
                    alert('API key created! Save it now - this is the only time it will be shown.');
                } else {
                    const errData = await resp.json();
                    alert('Failed to create key: ' + (errData.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed to create key: ' + e.message);
            }
        }
        
        async function revokeKey(key) {
            if (!confirm('Are you sure you want to revoke this API key? This action cannot be undone.')) return;
            
            try {
                const resp = await adminFetch(`${API_BASE}/admin/keys/${encodeURIComponent(key)}`, {
                    method: 'DELETE'
                });
                
                if (resp.ok) {
                    alert('API key revoked successfully');
                    loadKeys();
                    loadStats();
                } else {
                    const errData = await resp.json();
                    alert('Failed to revoke key: ' + (errData.detail || 'Unknown error'));
                }
            } catch (e) {
                alert('Failed to revoke key: ' + e.message);
            }
        }

        // Validate API key and load everything on page load
        (async function() {
            const isValid = await validateApiKey();
            if (!isValid) return; // Validation failed, already redirected
            
            loadStatus();
            loadModels();
            loadKeys();
            loadBackendConfig();
            loadStats();
            refreshGpuStatus();
            refreshLlamacppStatus();
        })();
        
        // Refresh status every 30 seconds
        setInterval(loadStatus, 30000);
        setInterval(loadBackendConfig, 60000);
        setInterval(loadModels, 30000);
        setInterval(loadStats, 60000);  // Refresh stats every minute
        setInterval(refreshGpuStatus, 30000);  // Refresh GPU status every 30 seconds
        setInterval(refreshLlamacppStatus, 30000);  // Refresh llamacpp status every 30 seconds
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
    
    # Get vLLM download status from Redis
    download_status = None
    status = await redis_client.get_value("vllm:download:status")
    error = await redis_client.get_value("vllm:download:error")
    model = await redis_client.get_value("vllm:download:model")
    
    if status:
        download_status = {
            "status": status,
            "model": model if model else "unknown",
            "error": error if error else None
        }
    
    return {
        "models": model_registry.get_available_models(),
        "backends": model_registry.backends,
        "download_status": download_status,
    }


@app.get("/admin/keys")
async def admin_list_keys(api_key: str = Depends(get_api_key)):
    """List all API keys (admin endpoint)."""
    await require_scope("admin", api_key)
    keys = await postgres_client.list_api_keys()
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
    
    await postgres_client.set_api_key_config(api_key, key_config)
    await redis_client.set_api_key_config(api_key, key_config)
    
    return {"key": api_key, "config": key_config}


@app.delete("/admin/keys/{api_key}")
async def admin_revoke_key(api_key: str, admin_key: str = Depends(get_api_key)):
    """Revoke an API key (admin endpoint)."""
    await require_scope("admin", admin_key)
    await postgres_client.delete_api_key(api_key)
    # Remove from Redis cache immediately so the key stops working right away
    await redis_client.delete_api_key_config(api_key)
    return {"status": "revoked", "api_key": api_key}


@app.get("/admin/usage/{api_key}")
async def admin_get_usage(api_key: str, admin_key: str = Depends(get_api_key)):
    """Get usage for a specific API key."""
    await require_scope("admin", admin_key)
    key_config = await postgres_client.get_api_key_config(api_key)
    if not key_config:
        raise HTTPException(status_code=404, detail="API key not found")
    
    input_tokens, output_tokens = await postgres_client.get_token_usage(api_key)
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
    return await postgres_client.get_all_keys_stats()


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
    
    # Update HF token in Kubernetes secret
    if "hf_token" in body:
        hf_token = body["hf_token"]
        
        try:
            from kubernetes import client, config as k8s_config
            import base64
            
            try:
                k8s_config.load_incluster_config()
            except:
                k8s_config.load_kube_config()
            
            core_v1 = client.CoreV1Api()
            namespace = os.getenv("NAMESPACE", "llmapi")
            
            # Update hf-token secret
            secret = core_v1.read_namespaced_secret("hf-token", namespace)
            secret.data["token"] = base64.b64encode(hf_token.encode()).decode()
            core_v1.replace_namespaced_secret("hf-token", namespace, secret)
            
            # Also store in Redis for UI display
            await redis_client.set_value("config:hf_token", hf_token)
            
            logger.info("HuggingFace token updated successfully")
            return {"status": "saved", "message": "HuggingFace token updated. Restart vLLM pods to use new token."}
            
        except ImportError as e:
            # Kubernetes client required for proper token storage
            logger.error(f"Kubernetes client not available: {e}")
            raise HTTPException(
                status_code=503,
                detail="Kubernetes client required for token storage. Cannot save token."
            )
        except Exception as e:
            logger.error(f"Failed to update HF token: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to update token: {str(e)}")
    
    return {"status": "no changes"}


@app.get("/admin/config")
async def admin_get_config(api_key: str = Depends(get_api_key)):
    """Get current configuration including current models."""
    await require_scope("admin", api_key)
    token = await redis_client.get_value("config:hf_token")
    hf_token_set = bool(token)
    vllm_model = await redis_client.get_value("config:vllm_model")
    llamacpp_model_url = await redis_client.get_value("config:llamacpp_model_url")
    llamacpp_replicas = 0
    
    # Try to get from Kubernetes ConfigMaps if not in Redis
    try:
        from kubernetes import client, config as k8s_config
        try:
            k8s_config.load_incluster_config()
        except ConfigException:
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
        except ConfigException:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Derive served model name from model ID (e.g., "Qwen/Qwen2.5-14B-Instruct-AWQ" -> "qwen2.5-14b")
        served_model_name = model_id.split('/')[-1].lower()
        served_model_name = served_model_name.replace('-instruct', '').replace('-awq', '').replace('-gptq', '')
        # Keep only model name without quantization suffixes
        if '-' in served_model_name:
            parts = served_model_name.split('-')
            # Usually format is: modelname-version-size, keep first 2-3 parts
            served_model_name = '-'.join(parts[:3]) if len(parts) > 2 else served_model_name
        
        # Update vllm-config ConfigMap with new MODEL_NAME and SERVED_MODEL_NAME
        # This is what the init container reads to download the model
        try:
            configmap = core_v1.read_namespaced_config_map("vllm-config", namespace)
            configmap.data["MODEL_NAME"] = model_id
            configmap.data["SERVED_MODEL_NAME"] = served_model_name
            core_v1.replace_namespaced_config_map("vllm-config", namespace, configmap)
            logger.info(f"Updated vllm-config ConfigMap: MODEL_NAME={model_id}, SERVED_MODEL_NAME={served_model_name}")
        except Exception as e:
            logger.error(f"Failed to update ConfigMap: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to update ConfigMap: {str(e)}")
        
        # Trigger rollout restart by updating pod template annotation
        # This will cause StatefulSet to recreate pods with new ConfigMap values
        sts = apps_v1.read_namespaced_stateful_set("vllm", namespace)
        if sts.spec.template.metadata.annotations is None:
            sts.spec.template.metadata.annotations = {}
        sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_stateful_set("vllm", namespace, sts)
        
        # Store in Redis for UI
        await redis_client.set_value("config:vllm_model", model_id)
        
        logger.info(f"vLLM model change initiated: {model_id} (served as {served_model_name})")
        return {"status": "initiated", "model_id": model_id, "served_model_name": served_model_name, "message": "vLLM pod is restarting with new model"}
        
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
        except ConfigException:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        apps_v1 = client.AppsV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Extract model filename from URL
        model_file = model_url.split("/")[-1]
        
        # Update llamacpp-config ConfigMap with new MODEL_URL and MODEL_FILE
        # This is what the init container reads to download the model
        try:
            configmap = core_v1.read_namespaced_config_map("llamacpp-config", namespace)
            configmap.data["MODEL_URL"] = model_url
            configmap.data["MODEL_FILE"] = model_file
            core_v1.replace_namespaced_config_map("llamacpp-config", namespace, configmap)
            logger.info(f"Updated llamacpp-config ConfigMap: MODEL_URL={model_url}, MODEL_FILE={model_file}")
        except Exception as e:
            logger.error(f"Failed to update ConfigMap: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to update ConfigMap: {str(e)}")
        
        # Trigger rollout restart by updating pod template annotation
        # This will cause Deployment to recreate pods with new ConfigMap values
        deploy = apps_v1.read_namespaced_deployment("llamacpp", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_deployment("llamacpp", namespace, deploy)
        
        # Store in Redis for UI
        await redis_client.set_value("config:llamacpp_model_url", model_url)
        
        logger.info(f"llama.cpp model change initiated: {model_url} (file: {model_file})")
        return {"status": "initiated", "model_url": model_url, "model_file": model_file, "message": "llama.cpp pod is restarting with new model"}
        
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
        except ConfigException:
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
        except ConfigException:
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


@app.get("/admin/cluster/gpus")
async def admin_get_cluster_gpus(api_key: str = Depends(get_api_key)):
    """Get GPU availability across cluster nodes."""
    await require_scope("admin", api_key)
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except ConfigException:
            k8s_config.load_kube_config()
        
        core_v1 = client.CoreV1Api()
        
        # Get all nodes
        nodes = core_v1.list_node()
        
        gpu_info = []
        for node in nodes.items:
            node_name = node.metadata.name
            allocatable = node.status.allocatable or {}
            capacity = node.status.capacity or {}
            
            # Check for NVIDIA GPUs
            gpu_allocatable = int(allocatable.get("nvidia.com/gpu", 0))
            gpu_capacity = int(capacity.get("nvidia.com/gpu", 0))
            
            if gpu_capacity > 0:
                gpu_info.append({
                    "node": node_name,
                    "total": gpu_capacity,
                    "available": gpu_allocatable,
                    "allocated": gpu_capacity - gpu_allocatable
                })
        
        return {
            "gpus": gpu_info,
            "total_gpus": sum(g["total"] for g in gpu_info),
            "available_gpus": sum(g["available"] for g in gpu_info)
        }
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to get GPU info: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/admin/backend/vllm/replicas")
async def admin_get_vllm_replicas(api_key: str = Depends(get_api_key)):
    """Get current vLLM replica count and status."""
    await require_scope("admin", api_key)
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except ConfigException:
            k8s_config.load_kube_config()
        
        apps_v1 = client.AppsV1Api()
        core_v1 = client.CoreV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Get StatefulSet
        sts = apps_v1.read_namespaced_stateful_set("vllm", namespace)
        desired = sts.spec.replicas or 0
        ready = sts.status.ready_replicas or 0
        
        # Get pod statuses
        pods = core_v1.list_namespaced_pod(
            namespace,
            label_selector="app=vllm"
        )
        
        pod_status = []
        for pod in pods.items:
            pod_status.append({
                "name": pod.metadata.name,
                "node": pod.spec.node_name,
                "phase": pod.status.phase,
                "ready": all(cs.ready for cs in pod.status.container_statuses or [])
            })
        
        return {
            "desired": desired,
            "ready": ready,
            "pods": pod_status
        }
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to get vLLM replicas: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/admin/backend/vllm/scale")
async def admin_scale_vllm(request: Request, api_key: str = Depends(get_api_key)):
    """Scale vLLM StatefulSet. Requires available GPUs."""
    await require_scope("admin", api_key)
    body = await request.json()
    replicas = body.get("replicas", 1)
    
    if replicas < 0 or replicas > 10:
        raise HTTPException(status_code=400, detail="replicas must be between 0 and 10")
    
    try:
        from kubernetes import client, config as k8s_config
        
        try:
            k8s_config.load_incluster_config()
        except ConfigException:
            k8s_config.load_kube_config()
        
        apps_v1 = client.AppsV1Api()
        core_v1 = client.CoreV1Api()
        namespace = os.getenv("NAMESPACE", "llmapi")
        
        # Check GPU availability
        nodes = core_v1.list_node()
        total_gpus = 0
        for node in nodes.items:
            allocatable = node.status.allocatable or {}
            total_gpus += int(allocatable.get("nvidia.com/gpu", 0))
        
        if replicas > total_gpus:
            raise HTTPException(
                status_code=400,
                detail=f"Requested {replicas} replicas but only {total_gpus} GPUs available in cluster"
            )
        
        # Scale the StatefulSet
        apps_v1.patch_namespaced_stateful_set_scale(
            "vllm",
            namespace,
            {"spec": {"replicas": replicas}}
        )
        
        # Update gateway config with new vLLM URLs
        if replicas > 0:
            vllm_urls = ",".join([f"http://vllm-{i}.vllm:8000" for i in range(replicas)])
            try:
                cm = core_v1.read_namespaced_config_map("gateway-config", namespace)
                cm.data["VLLM_URLS"] = vllm_urls
                core_v1.patch_namespaced_config_map("gateway-config", namespace, cm)
                
                # Restart gateway to pick up new URLs
                deploy = apps_v1.read_namespaced_deployment("gateway", namespace)
                if deploy.spec.template.metadata.annotations is None:
                    deploy.spec.template.metadata.annotations = {}
                deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
                apps_v1.patch_namespaced_deployment("gateway", namespace, deploy)
            except Exception as e:
                logger.warning(f"Gateway config update failed (non-critical): {e}")
                # Don't fail the scale operation, but log it
        
        logger.info(f"vLLM scaled to {replicas} replicas")
        return {
            "status": "scaled",
            "replicas": replicas,
            "message": f"vLLM {'scaling up - pods will initialize in 5-10 minutes' if replicas > 0 else 'scaling down - GPUs will be freed'}"
        }
        
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to scale vLLM: {e}")
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
        except ConfigException:
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
        except ConfigException:
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
        await redis_client.set_value("config:embedding_model_url", model_url)
        
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
        except ConfigException:
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
