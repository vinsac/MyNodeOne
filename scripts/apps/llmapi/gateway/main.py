"""
LLM API Gateway — OpenAI-compatible front door for vLLM, llama.cpp, embeddings, and Ollama.

==============================================================================
Architecture at a glance
==============================================================================

::

    client (openai SDK / curl)
            │
            ▼
    ┌─────────────────────────────────────────────────────────────────────┐
    │  FastAPI handlers  (chat_completions, completions, embeddings)      │
    │  ───────────────────────────────────────────────────────────────────│
    │  async with await acquire_request_leases(model, api_key, ...):      │
    │      └─ acquires BACKEND lease + PER-KEY lease atomically           │
    │  forward(lease) | stream(lease)                                     │
    │      └─ on streaming, lease ownership transfers to the generator    │
    └─────────────────────────────────────────────────────────────────────┘
            │                                  │
            ▼                                  ▼
    ┌──────────────────────┐         ┌────────────────────────────────────┐
    │  RateLimiter         │         │  BackendManager                    │
    │  ───────────         │         │  ──────────────                    │
    │  Per-(api_key,bucket)│         │  Per-(backend_type, url)           │
    │  Slot+Lease pools    │         │  Slot+Lease pools                  │
    │  RPM + TPM (Redis)   │         │  Health check loop                 │
    └──────────────────────┘         │  acquire_slot(model) picks the     │
                                     │  least-loaded healthy slot that    │
                                     │  serves THIS model (multi-backend) │
                                     └────────────────────────────────────┘
                                                │
                                                ▼
                                  ┌──────────────────────────────┐
                                  │  vLLM pods │ llama.cpp │     │
                                  │  embedding │ Ollama          │
                                  └──────────────────────────────┘

Three pieces work together:

  1. **Slot + Lease primitive** (single concurrency primitive used everywhere)
     A bounded counter with atomic acquire/release. Each successful acquire
     returns a Lease holding ``weakref(asyncio.current_task())``. A 5-second
     reconciler reaps any lease whose owning Task is ``done()`` — the
     structural replacement for the old TTL-based pruning. Counter cannot
     drift from reality because the lease's lifetime is bound to its owning
     Task, not to a wall clock.

  2. **ModelRegistry** (multi-backend aware)
     Maps a logical model name (e.g. ``qwen2.5:7b``) to the SET of backend
     types that can serve it. So if you have ``qwen2.5:7b`` loaded on both a
     vLLM GPU pod and a llama.cpp CPU pod, the registry records both, and
     ``register_model`` MERGES (it never overwrites a previous backend).

  3. **BackendManager.acquire_slot(model)** (capacity-aware routing)
     For a given model, asks the registry which backend types serve it, then
     iterates those backends in priority order (vllm → llamacpp → ollama),
     least-loaded first within a type, and returns a Lease on the first slot
     whose ``try_acquire`` succeeds. Returns 503 if no backend serves the
     model, 429 if every eligible backend is at capacity.

==============================================================================
Multi-backend example
==============================================================================

Suppose the same Qwen-7B model is loaded on both backend pools::

    VLLM_URLS=http://vllm-0.vllm:8000,http://vllm-1.vllm:8000   # 2 GPU pods
    LLAMACPP_URL=http://llamacpp:8080                            # 1 CPU pod
    LLAMACPP_MODEL_NAME=qwen2.5:7b                               # same name as vLLM

After discovery the registry holds::

    loaded_models["qwen2.5:7b"] = {
        "backends": {"vllm": {...}, "llamacpp": {...}},
        ...
    }

Routing for ``POST /v1/chat/completions {"model":"qwen2.5:7b"}``:

  * Request 1 → vllm-0 (both GPUs empty, alphabetical tie-break)
  * Request 2 → vllm-1 (vllm-0 now at 1/1)
  * Request 3 → llamacpp (both GPUs at 1/1, spill to CPU)
  * Request 4 → 429 (entire cluster at capacity)

Routing for ``model="qwen2.5:32b"`` (vLLM-only, not on llama.cpp):

  * Request 1 → vllm-0
  * Request 2 → vllm-1
  * Request 3 → 429 — does NOT spill to llama.cpp, because llama.cpp
    doesn't serve that model.

Adding a third GPU just means bumping the vLLM StatefulSet replicas, adding
the new URL to ``VLLM_URLS``, and restarting the gateway. The new Slot is
registered automatically; the per-key cap grows from 2 → 3 because it derives
from ``len(VLLM_URLS)``, not from "currently healthy" GPU count.

==============================================================================
Concurrency safety
==============================================================================

Every exit path from a handler releases its leases. There is no flag to forget:

  * Non-streaming: ``RequestLeases.__aexit__`` releases both leases on success,
    HTTPException, httpx error, or ``CancelledError``.
  * Streaming: handler calls ``leases.detach()`` before constructing the
    StreamingResponse, transferring ownership to the generator's ``finally``.
  * Crash / force-cancel / partial finally: the 5-second reconciler reaps any
    lease whose owning Task is dead.

A leaked counter is therefore impossible by construction; recovery time is
bounded by ``SLOT_RECONCILE_INTERVAL_SECONDS`` (default 5s).
"""

import asyncio
import base64
import hashlib
import json
import logging
import math
import os
import re
import time
import weakref
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import AsyncGenerator, Optional
from urllib.parse import urlsplit

import anyio
import asyncpg
import httpx
import redis.asyncio as redis
from redis.asyncio.retry import Retry
from redis.backoff import NoBackoff
from redis.exceptions import ConnectionError as RedisConnectionError, TimeoutError as RedisTimeoutError
from fastapi import FastAPI, HTTPException, Request, Header, Depends, Form
from fastapi.exceptions import RequestValidationError
from fastapi.responses import StreamingResponse, JSONResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBasic, HTTPBasicCredentials, HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field, ValidationError
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
from kubernetes.client.exceptions import ApiException
from kubernetes.config import ConfigException
from urllib3.exceptions import HTTPError as Urllib3Error

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

class Config:
    # Redis connection (for rate limiting and caching)
    REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
    # Supplied separately from Secret llmapi-redis-auth so REDIS_URL stays
    # credential-free. Empty means a Redis without auth.
    REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", "")

    # PostgreSQL connection (for API keys and usage tracking)
    POSTGRES_HOST = os.getenv("POSTGRES_HOST", "llmapi-postgres")
    POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
    POSTGRES_DB = os.getenv("POSTGRES_DB", "llmapi")
    POSTGRES_USER = os.getenv("POSTGRES_USER", "llmapi")
    POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "")

    # Outage limits. Normal operations take milliseconds, so these can be short.
    # A request answers within them; see the store outage section below.
    REDIS_CONNECT_TIMEOUT_SECONDS = float(os.getenv("REDIS_CONNECT_TIMEOUT_SECONDS", "2"))
    REDIS_OP_TIMEOUT_SECONDS = float(os.getenv("REDIS_OP_TIMEOUT_SECONDS", "2"))
    REDIS_BULK_OP_TIMEOUT_SECONDS = float(os.getenv("REDIS_BULK_OP_TIMEOUT_SECONDS", "30"))
    POSTGRES_CONNECT_TIMEOUT_SECONDS = float(os.getenv("POSTGRES_CONNECT_TIMEOUT_SECONDS", "3"))
    # One whole reconnect: opening the pool and re-checking the schema.
    POSTGRES_RECONNECT_TIMEOUT_SECONDS = float(os.getenv("POSTGRES_RECONNECT_TIMEOUT_SECONDS", "10"))
    POSTGRES_OP_TIMEOUT_SECONDS = float(os.getenv("POSTGRES_OP_TIMEOUT_SECONDS", "5"))
    # Admin statistics, key sync and migrations, which can scan whole tables.
    POSTGRES_BULK_OP_TIMEOUT_SECONDS = float(os.getenv("POSTGRES_BULK_OP_TIMEOUT_SECONDS", "30"))
    # Between reconnect attempts: starts at 1s and doubles up to this.
    STORE_RECONNECT_MAX_BACKOFF_SECONDS = float(os.getenv("STORE_RECONNECT_MAX_BACKOFF_SECONDS", "30"))

    # Read timeout of one Kubernetes API call. The client retries a failed
    # connection on its own, so the gateway gives up at twice this overall.
    K8S_REQUEST_TIMEOUT_SECONDS = float(os.getenv("K8S_REQUEST_TIMEOUT_SECONDS", "15"))

    # Backend URLs
    VLLM_URLS = os.getenv("VLLM_URLS", "http://vllm:8000").split(",")
    LLAMACPP_URL = os.getenv("LLAMACPP_URL", "http://llamacpp:8080")
    EMBEDDING_URL = os.getenv("EMBEDDING_URL", "http://embedding:8080")
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")

    # Default rate limits
    DEFAULT_REQUESTS_PER_MINUTE = int(os.getenv("DEFAULT_REQUESTS_PER_MINUTE", "60"))
    DEFAULT_TOKENS_PER_DAY = int(os.getenv("DEFAULT_TOKENS_PER_DAY", "100000"))

    # Concurrency cap: max simultaneous in-flight requests per API key.
    # Scales with GPU count: the default 32K-context 3090 profile handles 1 request per GPU.
    # Override via env: CONCURRENCY_PER_KEY_DEFAULT / CONCURRENCY_PER_GPU
    CONCURRENCY_PER_GPU = int(os.getenv("CONCURRENCY_PER_GPU", "1"))
    CONCURRENCY_PER_KEY_DEFAULT = int(os.getenv("CONCURRENCY_PER_KEY_DEFAULT", "1"))
    # Embeddings run on their own service, so they must not consume chat/GPU slots.
    CONCURRENCY_PER_EMBEDDING_REPLICA = int(os.getenv("CONCURRENCY_PER_EMBEDDING_REPLICA", "4"))
    CONCURRENCY_PER_LLAMACPP_REPLICA = int(os.getenv("CONCURRENCY_PER_LLAMACPP_REPLICA", "1"))
    CONCURRENCY_PER_OLLAMA_REPLICA = int(os.getenv("CONCURRENCY_PER_OLLAMA_REPLICA", "1"))
    # Legacy TTL knobs (kept for backward-compat with old configs but no longer
    # used by the slot-based limiter: leaked slots are now reaped by a 5s
    # asyncio.Task-liveness reconciler rather than a wall-clock TTL).
    CONCURRENCY_LEASE_TTL_SECONDS = int(os.getenv("CONCURRENCY_LEASE_TTL_SECONDS", "600"))
    BACKEND_INFLIGHT_LEASE_TTL_SECONDS = int(os.getenv(
        "BACKEND_INFLIGHT_LEASE_TTL_SECONDS",
        os.getenv("CONCURRENCY_LEASE_TTL_SECONDS", "600")
    ))
    # How often the reconciler force-releases slots whose owning asyncio.Task
    # has died (uvicorn shutdown, worker crash, cancellation mid-finally).
    SLOT_RECONCILE_INTERVAL_SECONDS = int(os.getenv("SLOT_RECONCILE_INTERVAL_SECONDS", "5"))
    # When enabled, the gateway scrapes each healthy vLLM /metrics endpoint and
    # logs a warning if its `vllm:num_requests_running` disagrees with the
    # gateway's slot count. Audit only; never auto-corrects.
    RECONCILE_VLLM_METRICS = os.getenv("RECONCILE_VLLM_METRICS", "true").lower() == "true"
    RECONCILE_VLLM_METRICS_INTERVAL_SECONDS = int(os.getenv("RECONCILE_VLLM_METRICS_INTERVAL_SECONDS", "15"))
    # Per-backend HTTP timeout for forwarded inference requests. Set this above
    # the slowest expected generation; clients should configure their own read
    # timeout to be >= this value so they don't give up before vLLM responds.
    BACKEND_HTTP_TIMEOUT_SECONDS = float(os.getenv("BACKEND_HTTP_TIMEOUT_SECONDS", "300"))
    # A stream is ended when one write to the client stays blocked this long,
    # which means the client has stopped reading. A slow client whose writes
    # complete is not affected. 0 disables the check.
    STREAM_CLIENT_STALL_TIMEOUT_SECONDS = float(os.getenv("STREAM_CLIENT_STALL_TIMEOUT_SECONDS", "300"))
    # Last resort for a stream that keeps its slots however slowly it progresses.
    # Well above the longest generation expected on CPU. 0 disables the limit.
    STREAM_MAX_DURATION_SECONDS = float(os.getenv("STREAM_MAX_DURATION_SECONDS", "14400"))

    # Tokens-per-minute limit (TPM) — more accurate than RPM for LLMs.
    # A 4096-token request costs ~40x more than a 100-token request.
    DEFAULT_TOKENS_PER_MINUTE = int(os.getenv("DEFAULT_TOKENS_PER_MINUTE", "200000"))
    MIN_TOKENS_PER_MINUTE = int(os.getenv(
        "MIN_TOKENS_PER_MINUTE",
        os.getenv("DEFAULT_TOKENS_PER_MINUTE", "200000")
    ))
    DEFAULT_EMBEDDING_REQUESTS_PER_MINUTE = int(os.getenv(
        "DEFAULT_EMBEDDING_REQUESTS_PER_MINUTE",
        os.getenv("DEFAULT_REQUESTS_PER_MINUTE", "60")
    ))
    DEFAULT_EMBEDDING_TOKENS_PER_MINUTE = int(os.getenv(
        "DEFAULT_EMBEDDING_TOKENS_PER_MINUTE",
        os.getenv("DEFAULT_TOKENS_PER_MINUTE", "200000")
    ))
    DEFAULT_LLAMACPP_REQUESTS_PER_MINUTE = int(os.getenv(
        "DEFAULT_LLAMACPP_REQUESTS_PER_MINUTE",
        os.getenv("DEFAULT_REQUESTS_PER_MINUTE", "60")
    ))
    DEFAULT_LLAMACPP_TOKENS_PER_MINUTE = int(os.getenv(
        "DEFAULT_LLAMACPP_TOKENS_PER_MINUTE",
        os.getenv("DEFAULT_TOKENS_PER_MINUTE", "200000")
    ))
    DEFAULT_OLLAMA_REQUESTS_PER_MINUTE = int(os.getenv(
        "DEFAULT_OLLAMA_REQUESTS_PER_MINUTE",
        os.getenv("DEFAULT_REQUESTS_PER_MINUTE", "60")
    ))
    DEFAULT_OLLAMA_TOKENS_PER_MINUTE = int(os.getenv(
        "DEFAULT_OLLAMA_TOKENS_PER_MINUTE",
        os.getenv("DEFAULT_TOKENS_PER_MINUTE", "200000")
    ))
    # Higher default TPM for admin-scoped keys when not explicitly provided.
    ADMIN_DEFAULT_TOKENS_PER_MINUTE = int(os.getenv("ADMIN_DEFAULT_TOKENS_PER_MINUTE", "200000"))

    # Largest accepted request body. Larger bodies get a 413, whether they
    # declare a Content-Length or arrive as a chunked stream.
    MAX_REQUEST_BODY_BYTES = int(os.getenv("MAX_REQUEST_BODY_BYTES", str(10 * 1024 * 1024)))

    # Hosts that admin-supplied GGUF URLs may point at. The model download sends
    # the HuggingFace token to this URL, so it must stay a short allowlist.
    GGUF_MODEL_ALLOWED_HOSTS = {
        host.strip().lower()
        for host in os.getenv("GGUF_MODEL_ALLOWED_HOSTS", "huggingface.co,hf.co").split(",")
        if host.strip()
    }

    # Admin password (set via env var for security)
    ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "admin")

    # Lazy loading settings
    LAZY_LOAD_ENABLED = os.getenv("LAZY_LOAD_ENABLED", "true").lower() == "true"
    LAZY_LOAD_BACKEND = os.getenv("LAZY_LOAD_BACKEND", "ollama")
    AUTO_DOWNLOAD = os.getenv("AUTO_DOWNLOAD", "false").lower() == "true"

    # Horizontal scaling: route chat requests to least-loaded backend
    # When enabled, any chat model request routes to: GPU1 → GPU2 → ... → CPU
    # This assumes all chat backends run equivalent models (e.g., all run Qwen3-14B)
    HORIZONTAL_SCALING = os.getenv("HORIZONTAL_SCALING", "true").lower() == "true"
    # Max concurrent requests per backend before routing to next
    MAX_INFLIGHT_PER_BACKEND = int(os.getenv("MAX_INFLIGHT_PER_BACKEND", "32"))
    MAX_INFLIGHT_PER_VLLM_BACKEND = int(os.getenv(
        "MAX_INFLIGHT_PER_VLLM_BACKEND",
        os.getenv("CONCURRENCY_PER_GPU", "1")
    ))
    MAX_INFLIGHT_PER_EMBEDDING_BACKEND = int(os.getenv(
        "MAX_INFLIGHT_PER_EMBEDDING_BACKEND",
        os.getenv("CONCURRENCY_PER_EMBEDDING_REPLICA", "4")
    ))
    MAX_INFLIGHT_PER_LLAMACPP_BACKEND = int(os.getenv(
        "MAX_INFLIGHT_PER_LLAMACPP_BACKEND",
        os.getenv("CONCURRENCY_PER_LLAMACPP_REPLICA", "1")
    ))
    MAX_INFLIGHT_PER_OLLAMA_BACKEND = int(os.getenv(
        "MAX_INFLIGHT_PER_OLLAMA_BACKEND",
        os.getenv("CONCURRENCY_PER_OLLAMA_REPLICA", "1")
    ))

    # Model name aliases (map OpenAI names to our internal names)
    MODEL_ALIASES = {
        "gpt-4": "default",
        "gpt-3.5-turbo": "default",
        "text-embedding-ada-002": "embedding",
    }


config = Config()


# =============================================================================
# API key identifiers
# =============================================================================
#
# Raw API keys are never stored. Postgres and Redis hold the key id, which is
# "sha256:" + the SHA-256 of the raw key, and a short non-secret prefix for
# display. Keys carry 128 bits of randomness, so a fast hash is sufficient.
#
# get_api_key() turns the presented bearer token into the key id, and everything
# after it (scopes, leases, rate limits, usage) works on the id. A key id is not
# a credential: the bearer token is always hashed, so presenting an id fails.

API_KEY_ID_PREFIX = "sha256:"
_API_KEY_ID_RE = re.compile(r"sha256:[0-9a-f]{64}")


def hash_api_key(raw_key: str) -> str:
    """Return the key id stored for a raw API key."""
    return API_KEY_ID_PREFIX + hashlib.sha256(raw_key.encode("utf-8")).hexdigest()


def is_api_key_id(value: str) -> bool:
    return bool(_API_KEY_ID_RE.fullmatch(value))


def api_key_display_prefix(raw_key: str) -> str:
    """Non-secret leading part of a key. Standard keys show sk-mynodeone- plus
    7 hex characters. Never more than half, in case a legacy key is short."""
    return raw_key[:min(20, len(raw_key) // 2)]


def key_ref_to_id(key_ref: str) -> str:
    """Admin endpoints accept either a key id or a raw key."""
    return key_ref if is_api_key_id(key_ref) else hash_api_key(key_ref)


def get_k8s_clients():
    """Return Kubernetes API clients with an explicit in-cluster auth header.

    kubernetes-client 36.x can load the service-account token but omit the
    Authorization header for generated clients. Setting the header here keeps
    the admin UI working across client versions.
    """
    from kubernetes import client, config as k8s_config

    try:
        k8s_config.load_incluster_config()
    except ConfigException:
        k8s_config.load_kube_config()

    api_client = client.ApiClient()
    token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    if os.getenv("KUBERNETES_SERVICE_HOST") and os.path.exists(token_path):
        try:
            with open(token_path, "r", encoding="utf-8") as token_file:
                token = token_file.read().strip()
            if token:
                api_client.default_headers["Authorization"] = f"Bearer {token}"
        except OSError as e:
            logger.warning(f"Could not read Kubernetes service-account token: {e}")

    return client.CoreV1Api(api_client), client.AppsV1Api(api_client)


async def _k8s_off_loop(fn, *args, **kwargs):
    """Run a blocking Kubernetes client function in a thread, within a time limit.

    The Kubernetes client is synchronous, and on the event loop it would stall
    every request, including inference, for as long as the API server takes.
    """
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(fn, *args, **kwargs),
            config.K8S_REQUEST_TIMEOUT_SECONDS * 2,
        )
    except (asyncio.TimeoutError, Urllib3Error) as e:
        # Only the type: a urllib3 error's text includes the URL and can run long.
        logger.error(f"Kubernetes API did not respond: {type(e).__name__}")
        raise HTTPException(
            status_code=504,
            detail="The Kubernetes API did not respond. A change may or may not have been applied.",
        )


async def _k8s_clients():
    """get_k8s_clients() off the event loop: it reads files and loads the client."""
    return await _k8s_off_loop(get_k8s_clients)


async def _k8s_call(method, *args, **kwargs):
    """Call a Kubernetes API method off the event loop, with a request timeout."""
    # (connect, read). The read part applies to each read from the socket.
    kwargs.setdefault("_request_timeout", (min(5.0, config.K8S_REQUEST_TIMEOUT_SECONDS), config.K8S_REQUEST_TIMEOUT_SECONDS))
    return await _k8s_off_loop(method, *args, **kwargs)

# =============================================================================
# Model Registry - Tracks loaded models dynamically
# =============================================================================

class ModelRegistry:
    """Maps each loaded model to the set of backend types that can serve it.

    Multi-backend rationale
    -----------------------
    The same logical model (e.g. ``qwen2.5:7b``) can be loaded simultaneously on:

      * **vLLM** for GPU-served inference at high throughput.
      * **llama.cpp** as a CPU fallback when GPUs are saturated or unhealthy.
      * **Ollama** as a third pool (also CPU, usually for lazy-loaded models).

    The router (``BackendManager._candidates_for``) needs to know *all* the
    backends that serve a given model so it can:

      1. Prefer the fastest available pool (GPU first).
      2. Spill over to slower pools when the preferred pool is full.
      3. Refuse to route to a backend that *doesn't* serve that model
         (otherwise the upstream returns a 404 the client sees as confusing).

    Internal shape
    --------------
    ``loaded_models`` is keyed by the *logical* model name. Each value records
    which backend types serve that name and the per-backend metadata returned
    by discovery::

        {
          "qwen2.5:7b": {
            "backends": {
                "vllm":      {... vLLM /v1/models entry ...},
                "llamacpp":  {... env-derived stub ...}
            },
            "status": "ready",
            "registered_at": "2026-05-26T17:00:00Z"
          },
          "nomic-embed-text-v1.5": {
            "backends": {
                "embedding": {...}
            },
            ...
          }
        }

    ``register_model`` MERGES (a second call adds a backend; it never
    overwrites a previous registration on a different backend). This is the
    structural fix for the bug where vLLM discovery ran after llama.cpp
    discovery and silently erased the vLLM mapping.
    """

    # Priority order used to pick the *primary* backend when a model is on
    # several, and to order candidates for the router. GPU first, then the
    # CPU fallbacks in order of expected throughput.
    _BACKEND_PRIORITY: tuple = ("vllm", "llamacpp", "ollama", "embedding")

    def __init__(self):
        # See class docstring for shape.
        self.loaded_models: dict[str, dict] = {}
        # Models downloaded into Ollama but not yet loaded — lazy-load targets.
        self.cached_models: dict[str, dict] = {}
        # Per-backend health + model list for the admin UI / /v1/models response.
        self.backends: dict[str, dict] = {
            "vllm": {"url": config.VLLM_URLS[0] if config.VLLM_URLS else "", "status": "unknown", "models": []},
            "llamacpp": {"url": config.LLAMACPP_URL, "status": "unknown", "models": []},
            "embedding": {"url": config.EMBEDDING_URL, "status": "unknown", "models": []},
            "ollama": {"url": config.OLLAMA_URL, "status": "unknown", "models": [], "cached": []},
        }

    # ------------------------------------------------------------------ helpers

    def _sorted_backends(self, backends_dict: dict) -> list[str]:
        """Return the backend keys of ``backends_dict`` in routing-priority order.

        ``backends_dict`` is the inner per-model ``{"vllm": info, ...}`` map.
        Returned order matches ``_BACKEND_PRIORITY`` so callers can iterate from
        "fastest" to "slowest" without re-sorting."""
        return [bt for bt in self._BACKEND_PRIORITY if bt in backends_dict]

    def _resolve_alias(self, model_name: str) -> str:
        return config.MODEL_ALIASES.get(model_name, model_name)

    # ------------------------------------------------------------------ queries

    def get_model_backends(self, model_name: str) -> list[str]:
        """Return the *list* of backend types that serve ``model_name``,
        ordered by routing priority (GPU first).

        Used by the router to decide which slots are eligible for a request.

        Returns ``[]`` if the model is unknown (not loaded and not lazy-loadable).

        Examples
        --------
        >>> reg.get_model_backends("qwen2.5:7b")
        ['vllm', 'llamacpp']        # served by both
        >>> reg.get_model_backends("llama-cpu")
        ['llamacpp']                # CPU only
        >>> reg.get_model_backends("nomic-embed-text-v1.5")
        ['embedding']
        >>> reg.get_model_backends("nonexistent")
        []
        """
        resolved = self._resolve_alias(model_name)
        if resolved == "default":
            # "default" → pick the first ready chat model. Its backends become
            # the candidate set.
            for name, entry in self.loaded_models.items():
                if "embedding" in entry["backends"]:
                    continue
                if entry.get("status") == "ready":
                    return self._sorted_backends(entry["backends"])
            return []
        if resolved == "embedding":
            for name, entry in self.loaded_models.items():
                if "embedding" in entry["backends"] and entry.get("status") == "ready":
                    return ["embedding"]
            return []
        if resolved in self.loaded_models:
            return self._sorted_backends(self.loaded_models[resolved]["backends"])
        if resolved in self.cached_models and config.LAZY_LOAD_ENABLED:
            return ["ollama"]
        return []

    def get_model(self, model_name: str) -> Optional[dict]:
        """Return a single-dict view of the model for handler use.

        Shape (backward-compatible plus new ``backends`` field)::

            {
              "name": "qwen2.5:7b",
              "backend": "vllm",          # primary (highest-priority healthy backend)
              "backends": ["vllm", "llamacpp"],  # NEW: full list, for router
              "status": "ready",
              "info": {...}               # per-backend metadata of the primary
            }

        Returns ``None`` if the model isn't loaded or lazy-loadable.
        """
        resolved = self._resolve_alias(model_name)
        backends = self.get_model_backends(model_name)
        if not backends:
            return None
        # Resolve to the canonical name in the registry (alias targets may
        # differ from the user-supplied name).
        if resolved == "default":
            for name, entry in self.loaded_models.items():
                if "embedding" in entry["backends"]:
                    continue
                if entry.get("status") == "ready":
                    resolved = name
                    break
        elif resolved == "embedding":
            for name, entry in self.loaded_models.items():
                if "embedding" in entry["backends"] and entry.get("status") == "ready":
                    resolved = name
                    break

        primary = backends[0]
        if resolved in self.loaded_models:
            entry = self.loaded_models[resolved]
            return {
                "name": resolved,
                "backend": primary,
                "backends": backends,
                "status": entry.get("status", "ready"),
                "info": entry["backends"].get(primary, {}),
            }
        # Lazy-load path (cached in Ollama).
        if resolved in self.cached_models and config.LAZY_LOAD_ENABLED:
            return {
                "name": resolved,
                "backend": "ollama",
                "backends": ["ollama"],
                "status": "cached",
                "lazy_load": True,
                **self.cached_models[resolved],
            }
        return None

    def get_available_models(self) -> list[dict]:
        """List every available model, one entry per logical name.

        Each entry includes a ``backends`` list so the client can see, e.g.,
        that ``qwen2.5:7b`` is served by both vllm and llamacpp."""
        models = []
        for name, entry in self.loaded_models.items():
            if entry.get("status") != "ready":
                continue
            backends = self._sorted_backends(entry["backends"])
            if not backends:
                continue
            models.append({
                "id": name,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "mynodeone",
                "backend": backends[0],   # primary, for legacy clients
                "backends": backends,     # all backends serving this model
                "status": "loaded",
            })
        if config.LAZY_LOAD_ENABLED:
            for name, info in self.cached_models.items():
                if name in self.loaded_models:
                    continue
                models.append({
                    "id": name,
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "mynodeone",
                    "backend": info.get("backend", "ollama"),
                    "backends": [info.get("backend", "ollama")],
                    "status": "cached",
                    "size": info.get("size"),
                })
        return models

    # ----------------------------------------------------------------- mutation

    def update_cached_models(self, models: list[dict]):
        """Refresh the Ollama cached-models snapshot."""
        self.cached_models = {}
        for model in models:
            name = model.get("name") or model.get("model", "")
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
        """Register a model as being served by ``backend``.

        **Merging semantics**: calling this twice with the same ``name`` and
        different ``backend`` values records BOTH backends. The most recent
        ``status`` wins. This is what enables a model to be routed to either
        vLLM or llama.cpp when both have it loaded."""
        entry = self.loaded_models.get(name)
        if entry is None:
            entry = {
                "backends": {},
                "status": status,
                "registered_at": datetime.utcnow().isoformat(),
            }
            self.loaded_models[name] = entry
        entry["backends"][backend] = info or {}
        entry["status"] = status
        if name not in self.backends[backend]["models"]:
            self.backends[backend]["models"].append(name)
        all_backends = self._sorted_backends(entry["backends"])
        logger.info(
            "Registered model: %s on %s (now served by: %s)",
            name, backend, ", ".join(all_backends),
        )

    def unregister_model(self, name: str, backend: Optional[str] = None):
        """Remove a model from the registry.

        If ``backend`` is given, only that backend's mapping is removed; the
        model entry remains as long as at least one other backend still serves
        it. Without ``backend``, the model is fully removed from all backends.

        Used by ``DELETE /admin/models/<name>`` to drop the Ollama mapping
        without also forgetting that vLLM still serves the same name."""
        if name not in self.loaded_models:
            return
        entry = self.loaded_models[name]
        if backend is None:
            # Remove from every backend's list, then drop the entry.
            for bt in list(entry["backends"]):
                if name in self.backends.get(bt, {}).get("models", []):
                    self.backends[bt]["models"].remove(name)
            del self.loaded_models[name]
            logger.info(f"Unregistered model from all backends: {name}")
            return
        if backend in entry["backends"]:
            del entry["backends"][backend]
            if name in self.backends.get(backend, {}).get("models", []):
                self.backends[backend]["models"].remove(name)
        if not entry["backends"]:
            del self.loaded_models[name]
            logger.info(f"Unregistered model: {name} (no remaining backends)")
        else:
            logger.info(
                "Unregistered model: %s from %s (still served by: %s)",
                name, backend, ", ".join(self._sorted_backends(entry["backends"])),
            )

    def reconcile_backend_models(self, backend: str, current_models: set[str]) -> None:
        """Make one backend's model list match the latest successful discovery.

        Discovery must be a reconciliation, not append-only. Otherwise a model
        change on vLLM/llama.cpp leaves a stale registry mapping and the router
        can send requests to a backend that no longer serves the model.

        Only call this after a successful discovery response from that backend.
        If the backend is unhealthy or the discovery request fails, keep the
        previous registry mapping; health filtering already prevents routing to
        unhealthy slots, and preserving the mapping avoids flapping on transient
        network errors.
        """
        if backend not in self.backends:
            return
        current_models = {name for name in current_models if name}
        previous_models = set(self.backends[backend].get("models", []))
        for stale_model in sorted(previous_models - current_models):
            self.unregister_model(stale_model, backend=backend)

    def update_backend_status(self, backend: str, status: str):
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
# Store outages
# =============================================================================
#
# A Redis or Postgres outage must cost a request at most a few seconds, and must
# never make a request wait while it holds a lease. So:
#
#   * Every store operation has a hard time limit (_bounded).
#   * After a failure the store is marked down, and only one caller at a time
#     tries to reconnect, with one bounded attempt per backoff interval. Everyone
#     else gets the outage answer at once, without touching the network. No lock
#     is held while connecting, so there is nothing to queue on.
#   * Inference checks the daily quota before it takes leases, and gives them back
#     before it records usage.
#
# What each request gets during an outage:
#
#   Redis down, Postgres up:
#     Auth and scopes come from Postgres, so requests work. RPM and TPM aren't
#     enforced (fail open); per-key concurrency is, as it needs no store.
#   Postgres down, Redis up:
#     Keys in the Redis cache keep working. The daily quota isn't enforced (fail
#     open) and usage for those requests is not recorded. A key not in the cache
#     gets a 503, not a 401, as it can't be checked. So do /v1/usage and the admin
#     endpoints that need Postgres, such as creating or revoking a key.
#   Both down:
#     Every authenticated endpoint gets a 503 with Retry-After. Nothing is
#     authorized, because auth fails closed (see get_api_key).
#
# /health and / use neither store, so an outage doesn't restart the gateway.


class StoreUnavailable(Exception):
    """Postgres can't answer. The API turns this into a 503 (see the app's handler)."""


def _consume_task_result(task: asyncio.Future) -> None:
    if not task.cancelled():
        task.exception()


async def _bounded(awaitable, timeout: float):
    """Await with a hard limit, raising asyncio.TimeoutError when it runs out.

    Unlike asyncio.wait_for this doesn't wait for the operation to finish being
    cancelled. Cancelling a query on a hung server can itself hang (asyncpg opens
    a new connection to send the cancel), and that is exactly when this must return.
    """
    task = asyncio.ensure_future(awaitable)
    try:
        done, _ = await asyncio.wait({task}, timeout=timeout)
    except asyncio.CancelledError:
        task.cancel()
        task.add_done_callback(_consume_task_result)
        raise
    if not done:
        task.cancel()
        task.add_done_callback(_consume_task_result)
        raise asyncio.TimeoutError()
    return task.result()


class _ReconnectGate:
    """Lets one caller at a time try to reconnect, with exponential backoff."""

    INITIAL_BACKOFF_SECONDS = 1.0

    def __init__(self):
        self._backoff = self.INITIAL_BACKOFF_SECONDS
        self._retry_at = 0.0
        self._in_progress = False

    def try_begin(self) -> bool:
        # No await between the check and the set, so this is atomic on the event loop.
        if self._in_progress or time.monotonic() < self._retry_at:
            return False
        self._in_progress = True
        return True

    def succeeded(self) -> None:
        self._in_progress = False
        self._backoff = self.INITIAL_BACKOFF_SECONDS
        self._retry_at = 0.0

    def failed(self) -> None:
        self._in_progress = False
        self._retry_at = time.monotonic() + self._backoff
        self._backoff = min(self._backoff * 2, max(1.0, config.STORE_RECONNECT_MAX_BACKOFF_SECONDS))


# =============================================================================
# PostgreSQL Client
# =============================================================================

# Failures that mean the connection or the server is gone, not that a query is wrong.
_POSTGRES_OUTAGE_ERRORS = (
    OSError,
    asyncpg.exceptions.PostgresConnectionError,
    asyncpg.exceptions.OperatorInterventionError,  # shutting down or still starting
    asyncpg.exceptions.InterfaceError,
    asyncpg.exceptions.TooManyConnectionsError,
)


class PostgresClient:
    """PostgreSQL client for API keys, usage logs, and model configs."""

    def __init__(self):
        self.pool: Optional[asyncpg.Pool] = None
        self._reconnect_gate = _ReconnectGate()

    async def _open_pool(self) -> None:
        """Open a pool and make sure the schema exists."""
        pool = await asyncpg.create_pool(
            host=config.POSTGRES_HOST,
            port=config.POSTGRES_PORT,
            database=config.POSTGRES_DB,
            user=config.POSTGRES_USER,
            password=config.POSTGRES_PASSWORD,
            min_size=2,
            max_size=10,
            timeout=config.POSTGRES_CONNECT_TIMEOUT_SECONDS,
            command_timeout=60
        )
        self.pool = pool
        try:
            await self._init_schema()
        except BaseException:
            self._drop_pool(pool)
            raise

    async def connect(self):
        """Connect to PostgreSQL and initialize schema."""
        try:
            await _bounded(self._open_pool(), config.POSTGRES_BULK_OP_TIMEOUT_SECONDS)
            logger.info(f"Connected to PostgreSQL at {config.POSTGRES_HOST}:{config.POSTGRES_PORT}")
        except Exception as e:
            logger.error(f"Failed to connect to PostgreSQL: {type(e).__name__}: {e}")
            raise

    def _drop_pool(self, pool: Optional[asyncpg.Pool]) -> None:
        """Mark Postgres down, unless a newer pool has replaced this one.

        terminate() rather than close(): close() waits for connections in use,
        which on a hung server is forever.
        """
        if pool is None:
            return
        if self.pool is pool:
            self.pool = None
        pool.terminate()

    async def _reconnect(self) -> bool:
        """Make one bounded reconnect attempt. False if down, or another caller is on it."""
        if not self._reconnect_gate.try_begin():
            return False
        try:
            await _bounded(self._open_pool(), config.POSTGRES_RECONNECT_TIMEOUT_SECONDS)
        except BaseException as e:
            self._reconnect_gate.failed()
            logger.warning(f"PostgreSQL reconnect failed: {type(e).__name__}")
            if not isinstance(e, Exception):
                raise
            return False
        self._reconnect_gate.succeeded()
        logger.info("Reconnected to PostgreSQL")
        return True

    async def _execute_with_retry(self, fn, timeout: Optional[float] = None):
        """Run an async DB function within a time limit, or raise StoreUnavailable.

        A lost connection is retried once on a new pool, so a Postgres restart
        doesn't fail requests that could succeed. If the pool has never been
        established (postgres was down at startup), this also opens it, so
        degraded-mode gateways self-heal. A timeout isn't retried.

        Passing `timeout` marks a bulk operation. One that runs out of time says
        nothing about Postgres's health, so it doesn't mark Postgres down, which
        would also fail everyone else's queries on the pool.
        """
        for attempt in range(2):
            if self.pool is None and not await self._reconnect():
                raise StoreUnavailable("PostgreSQL is unavailable")
            pool = self.pool
            try:
                return await _bounded(fn(), timeout or config.POSTGRES_OP_TIMEOUT_SECONDS)
            except asyncio.TimeoutError as e:
                logger.warning("PostgreSQL operation timed out")
                if timeout is None:
                    self._drop_pool(pool)
                raise StoreUnavailable("PostgreSQL timed out") from e
            except _POSTGRES_OUTAGE_ERRORS as e:
                self._drop_pool(pool)
                if attempt:
                    raise StoreUnavailable("PostgreSQL is unavailable") from e
                logger.warning(f"PostgreSQL connection lost ({type(e).__name__}), reconnecting...")
            except Exception as e:
                # fn uses self.pool, which fails oddly if another request has just dropped it.
                if self.pool is not pool:
                    raise StoreUnavailable("PostgreSQL is unavailable") from e
                raise

    async def close(self):
        """Close PostgreSQL connection pool."""
        if self.pool:
            try:
                await _bounded(self.pool.close(), config.POSTGRES_OP_TIMEOUT_SECONDS)
            except asyncio.TimeoutError:
                self.pool.terminate()
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
                    tokens_per_minute INTEGER NOT NULL DEFAULT 200000,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    revoked BOOLEAN NOT NULL DEFAULT FALSE
                )
            """)
            # Migration: add tokens_per_minute to existing installs that predate this column
            await conn.execute("""
                ALTER TABLE api_keys
                ADD COLUMN IF NOT EXISTS tokens_per_minute INTEGER NOT NULL DEFAULT 200000
            """)
            await conn.execute("""
                ALTER TABLE api_keys
                ALTER COLUMN tokens_per_minute SET DEFAULT 200000
            """)
            await conn.execute(
                """
                UPDATE api_keys
                SET tokens_per_minute = $1,
                    updated_at = NOW()
                WHERE tokens_per_minute < $1
                """,
                config.MIN_TOKENS_PER_MINUTE,
            )

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
            await conn.execute("""
                ALTER TABLE api_keys
                ADD COLUMN IF NOT EXISTS key_prefix VARCHAR(32)
            """)

            logger.info("PostgreSQL schema initialized")
            await self._migrate_plaintext_rows(conn)

    async def _migrate_plaintext_rows(self, conn) -> int:
        """Replace every plaintext key in api_keys and usage_logs with its key id.

        Safe to repeat: rows that are already hashed are not selected. It runs
        at startup and on each sync, because older copies of install-llmapi.sh and
        manage-keys.sh inserted plaintext rows.
        """
        rows = await conn.fetch("""
            SELECT api_key FROM api_keys WHERE api_key NOT LIKE 'sha256:%'
            UNION
            SELECT api_key FROM usage_logs WHERE api_key NOT LIKE 'sha256:%'
        """)
        migrated = 0
        for row in rows:
            try:
                await self._migrate_plaintext_key_row(conn, row["api_key"])
                migrated += 1
            except (asyncpg.PostgresError, asyncpg.InterfaceError) as e:
                # Only the exception type: asyncpg error text can quote row values.
                logger.error(f"API key hash migration failed for one row: {type(e).__name__}")
        if migrated:
            logger.info(f"Migrated {migrated} plaintext API key(s) to hashed storage")
        return migrated

    async def _migrate_plaintext_key_row(self, conn, raw_key: str) -> None:
        """Move one plaintext key and its usage to the key id, atomically."""
        key_id = hash_api_key(raw_key)
        async with conn.transaction():
            # Serializes replicas migrating at once, so usage is never merged twice.
            await conn.execute("SELECT pg_advisory_xact_lock(7236001)")
            # A key revoked under either identity stays revoked.
            await conn.execute("""
                INSERT INTO api_keys (api_key, key_prefix, name, scopes, requests_per_minute,
                                      tokens_per_day, tokens_per_minute, created_at, updated_at, revoked)
                SELECT $2, $3, name, scopes, requests_per_minute,
                       tokens_per_day, tokens_per_minute, created_at, NOW(), revoked
                FROM api_keys WHERE api_key = $1
                ON CONFLICT (api_key) DO UPDATE SET
                    revoked = api_keys.revoked OR EXCLUDED.revoked,
                    key_prefix = COALESCE(api_keys.key_prefix, EXCLUDED.key_prefix),
                    updated_at = NOW()
            """, raw_key, key_id, api_key_display_prefix(raw_key))
            await conn.execute("""
                INSERT INTO usage_logs (api_key, date, hour, input_tokens, output_tokens,
                                        requests, created_at, updated_at)
                SELECT $2, date, hour, input_tokens, output_tokens, requests, created_at, NOW()
                FROM usage_logs WHERE api_key = $1
                ON CONFLICT (api_key, date, hour) DO UPDATE SET
                    input_tokens = usage_logs.input_tokens + EXCLUDED.input_tokens,
                    output_tokens = usage_logs.output_tokens + EXCLUDED.output_tokens,
                    requests = usage_logs.requests + EXCLUDED.requests,
                    updated_at = NOW()
            """, raw_key, key_id)
            await conn.execute("DELETE FROM usage_logs WHERE api_key = $1", raw_key)
            await conn.execute("DELETE FROM api_keys WHERE api_key = $1", raw_key)

    async def migrate_plaintext_keys(self) -> int:
        """Migrate any plaintext rows inserted since the last run."""
        async def _query():
            async with self.pool.acquire() as conn:
                return await self._migrate_plaintext_rows(conn)
        try:
            return await self._execute_with_retry(_query, timeout=config.POSTGRES_BULK_OP_TIMEOUT_SECONDS)
        except Exception as e:
            logger.error(f"API key hash migration failed: {type(e).__name__}")
            return 0

    async def migrate_plaintext_key(self, raw_key: str) -> Optional[dict]:
        """At lookup, migrate a plaintext row inserted since the last sync.

        Returns the key's config if the presented token was such a row. A token
        shaped like a key id is refused here, or presenting a stored id would
        match its row and be treated as a valid plaintext key.
        """
        if raw_key.startswith(API_KEY_ID_PREFIX):
            return None

        async def _query():
            async with self.pool.acquire() as conn:
                exists = await conn.fetchval("SELECT 1 FROM api_keys WHERE api_key = $1", raw_key)
                if not exists:
                    return False
                await self._migrate_plaintext_key_row(conn, raw_key)
                return True
        try:
            migrated = await self._execute_with_retry(_query)
        except StoreUnavailable:
            raise
        except Exception as e:
            logger.error(f"API key hash migration failed at lookup: {type(e).__name__}")
            return None
        return await self.get_api_key_config(hash_api_key(raw_key)) if migrated else None

    async def get_api_key_config(self, api_key: str) -> Optional[dict]:
        """Get API key configuration. None means the key doesn't exist or is revoked.

        Raises StoreUnavailable if that can't be determined, so an outage is never
        mistaken for an invalid key.
        """
        async def _query():
            async with self.pool.acquire() as conn:
                row = await conn.fetchrow("""
                    SELECT api_key, key_prefix, name, scopes, requests_per_minute, tokens_per_day,
                           tokens_per_minute, created_at, revoked
                    FROM api_keys
                    WHERE api_key = $1 AND revoked = FALSE
                """, api_key)
                if row:
                    return {
                        "key_prefix": row["key_prefix"],
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
            logger.error(f"Error fetching API key config: {type(e).__name__}")
            raise StoreUnavailable("Could not read the API key") from e

    async def set_api_key_config(self, api_key: str, config_data: dict):
        """Create or update API key configuration."""
        async def _query():
            async with self.pool.acquire() as conn:
                await conn.execute("""
                    INSERT INTO api_keys (api_key, name, scopes, requests_per_minute,
                                         tokens_per_day, tokens_per_minute, created_at, updated_at, key_prefix)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), $8)
                    ON CONFLICT (api_key)
                    DO UPDATE SET
                        key_prefix = COALESCE(EXCLUDED.key_prefix, api_keys.key_prefix),
                        name = EXCLUDED.name,
                        scopes = EXCLUDED.scopes,
                        requests_per_minute = EXCLUDED.requests_per_minute,
                        tokens_per_day = EXCLUDED.tokens_per_day,
                        tokens_per_minute = EXCLUDED.tokens_per_minute,
                        updated_at = NOW()
                """,
                    api_key,
                    config_data.get("name", "unnamed"),
                    config_data.get("scopes", ["inference"]),
                    config_data.get("requests_per_minute", 60),
                    config_data.get("tokens_per_day", 100000),
                    max(
                        config.MIN_TOKENS_PER_MINUTE,
                        int(config_data.get("tokens_per_minute", config.DEFAULT_TOKENS_PER_MINUTE)),
                    ),
                    datetime.fromisoformat(config_data.get("created_at", datetime.utcnow().isoformat())),
                    config_data.get("key_prefix"),
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
        """List all non-revoked API keys whose display prefix matches.

        Only hashed rows are returned, so a row awaiting migration can never
        expose a raw key. Raises StoreUnavailable in an outage, rather than
        reporting that there are no keys."""
        async def _query():
            async with self.pool.acquire() as conn:
                rows = await conn.fetch("""
                    SELECT api_key, key_prefix, name, scopes, requests_per_minute, tokens_per_day,
                           tokens_per_minute, created_at
                    FROM api_keys
                    WHERE api_key LIKE 'sha256:%'
                      AND (key_prefix IS NULL OR key_prefix LIKE $1)
                      AND revoked = FALSE
                    ORDER BY created_at DESC
                """, f"{prefix}%")
                return [
                    {
                        "key_id": row["api_key"],
                        "key_prefix": row["key_prefix"],
                        "name": row["name"],
                        "scopes": list(row["scopes"]),
                        "requests_per_minute": row["requests_per_minute"],
                        "tokens_per_day": row["tokens_per_day"],
                        "tokens_per_minute": row["tokens_per_minute"],
                        "created_at": row["created_at"].isoformat(),
                    }
                    for row in rows
                ]
        try:
            return await self._execute_with_retry(_query, timeout=config.POSTGRES_BULK_OP_TIMEOUT_SECONDS)
        except StoreUnavailable:
            raise
        except Exception as e:
            logger.error(f"Error listing API keys: {e}")
            return []

    async def get_key_revocation_states(self) -> dict[str, bool]:
        """Map every key id to its revoked flag. Raises if Postgres is unavailable,
        so callers can't mistake an outage for an empty key table."""
        async def _query():
            async with self.pool.acquire() as conn:
                rows = await conn.fetch("SELECT api_key, revoked FROM api_keys")
                return {row["api_key"]: row["revoked"] for row in rows}
        return await self._execute_with_retry(_query, timeout=config.POSTGRES_BULK_OP_TIMEOUT_SECONDS)

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
        """Get today's token usage for an API key. Raises StoreUnavailable in an
        outage, rather than reporting no usage."""
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
            logger.error(f"Error getting token usage: {type(e).__name__}")
            raise StoreUnavailable("Could not read token usage") from e

    async def check_token_quota(self, api_key: str, daily_limit: int) -> bool:
        """Check if within daily token quota. Fails open if Postgres is unavailable,
        so a Postgres outage doesn't stop inference for keys that can still authenticate."""
        try:
            input_tokens, output_tokens = await self.get_token_usage(api_key)
        except StoreUnavailable:
            logger.warning("Daily quota not enforced: PostgreSQL is unavailable")
            return True
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

    async def get_all_keys_stats(self, hours: int = 96) -> dict:
        """Get aggregate statistics for all API keys over a rolling UTC window."""
        window_hours = max(24, min(int(hours or 96), 168))
        now_utc = datetime.utcnow().replace(minute=0, second=0, microsecond=0)
        start_dt = now_utc - timedelta(hours=window_hours - 1)
        start_date = start_dt.date()

        async def _query():
            async with self.pool.acquire() as conn:
                active_keys = await conn.fetchval("""
                    SELECT COUNT(*)
                    FROM api_keys
                    WHERE revoked = FALSE
                """)
                usage_rows = await conn.fetch("""
                    SELECT
                        u.api_key,
                        k.key_prefix,
                        k.name,
                        u.date,
                        u.hour,
                        u.input_tokens,
                        u.output_tokens,
                        u.requests,
                        k.tokens_per_day as tokens_limit,
                        k.requests_per_minute as rpm_limit,
                        k.tokens_per_minute as tpm_limit
                    FROM usage_logs u
                    JOIN api_keys k ON u.api_key = k.api_key
                    WHERE u.date >= $1 AND k.revoked = FALSE AND u.api_key LIKE 'sha256:%'
                    ORDER BY u.date ASC, u.hour ASC, k.name ASC
                """, start_date)

                bucket_map = {}
                bucket_order = []
                for i in range(window_hours):
                    bucket_dt = start_dt + timedelta(hours=i)
                    iso = bucket_dt.isoformat() + "Z"
                    bucket_map[iso] = {
                        "timestamp_utc": iso,
                        "hour_label_utc": bucket_dt.strftime("%Y-%m-%d %H:00 UTC"),
                        "tokens": 0,
                        "requests": 0,
                    }
                    bucket_order.append(iso)

                key_totals = {}
                key_hourly = []
                total_tokens = 0
                total_requests = 0

                for row in usage_rows:
                    bucket_dt = datetime.combine(row["date"], datetime.min.time()) + timedelta(hours=row["hour"])
                    if bucket_dt < start_dt or bucket_dt > now_utc:
                        continue

                    iso = bucket_dt.isoformat() + "Z"
                    tokens = int(row["input_tokens"]) + int(row["output_tokens"])
                    requests = int(row["requests"])
                    api_key = row["api_key"]
                    api_key_preview = (row["key_prefix"] or api_key[:16]) + "..."

                    bucket_map[iso]["tokens"] += tokens
                    bucket_map[iso]["requests"] += requests
                    total_tokens += tokens
                    total_requests += requests

                    if api_key not in key_totals:
                        key_totals[api_key] = {
                            "api_key": api_key,
                            "name": row["name"],
                            "api_key_preview": api_key_preview,
                            "tokens_window": 0,
                            "requests_window": 0,
                            "tokens_limit": int(row["tokens_limit"]),
                            "rpm_limit": int(row["rpm_limit"]),
                            "tpm_limit": int(row["tpm_limit"]),
                        }

                    key_totals[api_key]["tokens_window"] += tokens
                    key_totals[api_key]["requests_window"] += requests

                    key_hourly.append({
                        "api_key": api_key,
                        "name": row["name"],
                        "api_key_preview": api_key_preview,
                        "timestamp_utc": iso,
                        "tokens": tokens,
                        "requests": requests,
                    })

                by_key = sorted(
                    key_totals.values(),
                    key=lambda item: (item["tokens_window"], item["requests_window"]),
                    reverse=True,
                )

                return {
                    "timezone": "UTC",
                    "generated_at": now_utc.isoformat() + "Z",
                    "window_hours": window_hours,
                    "summary": {
                        "total_tokens_window": total_tokens,
                        "total_requests_window": total_requests,
                        "total_tokens_today": total_tokens,
                        "total_requests_today": total_requests,
                        "active_keys": int(active_keys or 0),
                    },
                    "by_key": by_key,
                    "by_hour": [bucket_map[iso] for iso in bucket_order],
                    "by_key_hour": key_hourly,
                }
        # An outage raises StoreUnavailable, a 503. Zeros would read as "no usage".
        return await self._execute_with_retry(_query, timeout=config.POSTGRES_BULK_OP_TIMEOUT_SECONDS)


postgres_client = PostgresClient()

# =============================================================================
# Redis Client
# =============================================================================

class RedisClient:
    def __init__(self):
        self.client: Optional[redis.Redis] = None
        self._reconnect_gate = _ReconnectGate()

    def _new_client(self) -> redis.Redis:
        kwargs = {
            "decode_responses": True,
            "socket_connect_timeout": config.REDIS_CONNECT_TIMEOUT_SECONDS,
            "socket_timeout": config.REDIS_OP_TIMEOUT_SECONDS,
            # _safe does the retrying. The client's own retries would use up the time limit.
            "retry": Retry(NoBackoff(), 0),
        }
        if config.REDIS_PASSWORD:
            kwargs["password"] = config.REDIS_PASSWORD
        return redis.from_url(config.REDIS_URL, **kwargs)

    @staticmethod
    def _log_safe_url() -> str:
        """REDIS_URL without any userinfo, for logs."""
        parts = urlsplit(config.REDIS_URL)
        host = parts.netloc.rsplit("@", 1)[-1]
        return f"{parts.scheme}://{host}{parts.path}"

    async def connect(self):
        self.client = self._new_client()
        logger.info(f"Connected to Redis at {self._log_safe_url()}")

    async def close(self):
        if self.client:
            await self.client.close()

    def _drop_client(self, client: Optional[redis.Redis]) -> None:
        """Mark Redis down, unless a newer client has replaced this one."""
        if self.client is client:
            self.client = None
        if client is not None:
            # In the background, as closing may wait on a connection to a hung server.
            asyncio.ensure_future(_bounded(client.aclose(), config.REDIS_OP_TIMEOUT_SECONDS)).add_done_callback(
                _consume_task_result
            )

    async def _reconnect(self) -> bool:
        """Make one bounded reconnect attempt. False if down, or another caller is on it."""
        if not self._reconnect_gate.try_begin():
            return False
        client = None
        try:
            client = self._new_client()
            await _bounded(client.ping(), config.REDIS_CONNECT_TIMEOUT_SECONDS)
        except BaseException as e:
            self._reconnect_gate.failed()
            self._drop_client(client)
            logger.warning(f"Redis reconnect failed: {type(e).__name__}")
            if not isinstance(e, Exception):
                raise
            return False
        self.client = client
        self._reconnect_gate.succeeded()
        logger.info("Reconnected to Redis")
        return True

    async def _safe(self, coro_fn, default=None, timeout: Optional[float] = None):
        """Execute a Redis coroutine within a time limit, reconnecting once on failure.

        Returns `default` if Redis is unavailable so callers can fail-open
        (rate limiting skipped, cache miss, etc.) rather than crashing.

        Passing `timeout` marks a bulk operation, whose running out of time doesn't
        mark Redis down. See PostgresClient._execute_with_retry.
        """
        for attempt in range(2):
            # A client left over from a failure was dropped; try to recover.
            if self.client is None and not await self._reconnect():
                return default
            client = self.client
            try:
                return await _bounded(coro_fn(), timeout or config.REDIS_OP_TIMEOUT_SECONDS)
            except (asyncio.TimeoutError, RedisTimeoutError):
                logger.warning("Redis operation timed out")
                if timeout is None:
                    self._drop_client(client)
                return default
            except (RedisConnectionError,
                    ConnectionRefusedError,
                    OSError) as e:
                self._drop_client(client)
                if attempt:
                    logger.error(f"Redis operation failed after reconnect: {type(e).__name__}")
                    return default
                logger.warning(f"Redis connection lost ({type(e).__name__}), reconnecting...")
            except Exception as e:
                logger.error(f"Redis unexpected error: {e}")
                return default
        return default

    # Rate windows are fixed and named by the minute, so a window ends when the
    # clock moves on, whatever was written to it. The TTL only cleans up, and is
    # longer than the window to allow for clock differences between replicas.
    RATE_WINDOW_SECONDS = 60
    RATE_KEY_TTL_SECONDS = 120

    def _rate_key(self, api_key: str, bucket: Optional[str], metric: str) -> tuple[str, int]:
        """Return the current window's Redis key and the seconds until the next window.

        Bucketed keys isolate chat and embeddings quotas."""
        now = time.time()
        window = int(now // self.RATE_WINDOW_SECONDS)
        seconds_left = max(1, math.ceil((window + 1) * self.RATE_WINDOW_SECONDS - now))
        if bucket:
            return f"ratelimit:{api_key}:{bucket}:{metric}:{window}", seconds_left
        return f"ratelimit:{api_key}:{metric}:{window}", seconds_left

    async def _charge_rate_window(self, key: str, amount: int) -> None:
        """Add to a window. MULTI/EXEC, so a key can't exist without its expiry."""
        pipe = self.client.pipeline(transaction=True)
        pipe.incrby(key, amount)
        pipe.expire(key, self.RATE_KEY_TTL_SECONDS)
        await pipe.execute()

    async def check_rate_limit_with_info(
        self,
        api_key: str,
        requests_per_minute: int,
        bucket: Optional[str] = None,
    ) -> tuple[bool, int]:
        """Check RPM limit. Returns (allowed, retry_after_seconds).

        Fails OPEN (allows request) if Redis is unavailable so a Redis pod
        crash does not block all inference traffic.
        """
        key, seconds_left = self._rate_key(api_key, bucket, "rpm")
        async def _fn():
            current = int(await self.client.get(key) or 0)
            if current >= requests_per_minute:
                return False, seconds_left
            await self._charge_rate_window(key, 1)
            return True, 0
        result = await self._safe(_fn, default=(True, 0))  # fail-open
        return result

    async def check_tpm_limit(
        self,
        api_key: str,
        estimated_tokens: int,
        tokens_per_minute: int,
        bucket: Optional[str] = None,
    ) -> tuple[bool, int]:
        """Check TPM limit using a fixed one-minute window. Returns (allowed, retry_after_seconds).

        Charges estimated_tokens against the window.  Actual output tokens are
        charged separately after completion via add_tpm_usage().
        Fails OPEN if Redis is unavailable.
        """
        key, seconds_left = self._rate_key(api_key, bucket, "tpm")
        async def _fn():
            current = int(await self.client.get(key) or 0)
            if current + estimated_tokens > tokens_per_minute:
                return False, seconds_left
            await self._charge_rate_window(key, estimated_tokens)
            return True, 0
        return await self._safe(_fn, default=(True, 0))  # fail-open

    async def add_tpm_usage(self, api_key: str, output_tokens: int, bucket: Optional[str] = None) -> None:
        """Charge output tokens to the TPM window after a request completes."""
        key, _ = self._rate_key(api_key, bucket, "tpm")
        async def _fn():
            await self._charge_rate_window(key, output_tokens)
        await self._safe(_fn)

    async def get_rate_limit_info(self, api_key: str, bucket: Optional[str] = None) -> tuple[int, int]:
        """Get current RPM usage and the seconds until the window ends."""
        rpm_key, seconds_left = self._rate_key(api_key, bucket, "rpm")
        async def _fn():
            current_rpm = await self.client.get(rpm_key) or 0
            return int(current_rpm), seconds_left
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

    async def list_cached_key_ids(self) -> Optional[list[str]]:
        """Key ids in the auth cache. None if Redis is unavailable."""
        async def _fn():
            return [
                key.removeprefix("apikey:")
                async for key in self.client.scan_iter(match=f"apikey:{API_KEY_ID_PREFIX}*", count=500)
            ]
        return await self._safe(_fn, default=None, timeout=config.REDIS_BULK_OP_TIMEOUT_SECONDS)

    async def migrate_legacy_keys(self, delete_plaintext: bool) -> None:
        """Move entries an older gateway stored under raw keys to the key id.

        The copy keeps auth working if Postgres is down at startup. Deleting the
        plaintext entries waits for the first periodic sync, in case an old pod is
        still running next to this one and reading them. upgrade-llmapi.sh stops the
        old pods first, because once Redis requires a password they can't reach it.
        """
        async def _fn():
            async for key in self.client.scan_iter(match="apikey:*", count=500):
                raw_key = key.removeprefix("apikey:")
                if raw_key.startswith(API_KEY_ID_PREFIX):
                    continue
                value = await self.client.get(key)
                if value is not None:
                    await self.client.set(f"apikey:{hash_api_key(raw_key)}", value, nx=True)
                if delete_plaintext:
                    await self.client.delete(key)
            if delete_plaintext:
                async for key in self.client.scan_iter(match="ratelimit:*", count=500):
                    if not key.startswith(f"ratelimit:{API_KEY_ID_PREFIX}"):
                        await self.client.delete(key)
        await self._safe(_fn, timeout=config.REDIS_BULK_OP_TIMEOUT_SECONDS)

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

    async def delete_value(self, key: str):
        """Delete a generic Redis key with reconnect/fallback handling."""
        async def _fn():
            await self.client.delete(key)
        await self._safe(_fn)


redis_client = RedisClient()

# =============================================================================
# Slot + Lease — the single concurrency primitive used everywhere
# =============================================================================
#
# Design intent (first principles):
#
#   The gateway is the source of truth for "how many requests are in flight"
#   because:
#     * vLLM exposes inflight via /metrics, but Ollama / llama.cpp / embedding
#       do not, so we need a uniform abstraction across heterogeneous backends.
#     * Per-API-key concurrency is purely the gateway's concern — no backend
#       tracks it.
#
#   To make the gateway's counter incapable of drifting from reality we use:
#
#     1. An atomic try_acquire / release pair guarded by a single asyncio.Lock.
#     2. Each successful acquire returns a Lease that holds a weakref to the
#        owning asyncio.Task.
#     3. A background reconciler walks all leases every SLOT_RECONCILE_INTERVAL
#        seconds; any lease whose owning Task is done() is force-released.
#
#   This covers every leak path that the old TTL-based scheme tried to patch:
#     - uvicorn force-shutdown mid-request
#     - worker OOM kill
#     - asyncio.CancelledError injected at a bad await point
#     - a release() coroutine that itself gets cancelled before completing
#
#   There is no TTL. A long-running request keeps its slot for as long as its
#   asyncio.Task is alive. The slot is freed the moment the Task ends, by
#   either the natural async-with exit OR the reconciler (whichever wins).
#   The reconciler can't help while a Task is alive but stuck, as it is when a
#   client stops reading a stream. LeaseStreamingResponse covers that case.
#
#   For vLLM (which publishes its own inflight) the reconciler additionally
#   audits gateway vs vLLM and logs warnings on drift. This is informational
#   only — vLLM is never the source of truth; it is a second opinion.
# =============================================================================


class Slot:
    """Bounded counter for a single resource (a backend pod, or a per-key bucket).

    Acquire returns a Lease that MUST be released exactly once. The Lease is
    an async context manager, so the recommended idiom is:

        async with await slot.try_acquire_or_raise() as lease:
            ...  # use the slot

    `try_acquire()` is the lower-level non-raising variant; callers can decide
    how to surface "at capacity" (e.g. 429, fall through to a different
    backend, etc.).
    """

    __slots__ = ("name", "backend_type", "meta", "capacity", "_leases", "_lock")

    def __init__(self, name: str, capacity: int, *, backend_type: Optional[str] = None, **meta):
        self.name = name
        self.backend_type = backend_type
        self.meta = meta
        self.capacity = max(1, int(capacity))
        self._leases: list["Lease"] = []
        self._lock = asyncio.Lock()

    def update_capacity(self, capacity: int) -> None:
        """Adjust capacity (e.g. when key config changes). Already-held leases
        are unaffected; the new ceiling applies to future acquires."""
        self.capacity = max(1, int(capacity))

    @property
    def inflight(self) -> int:
        return len(self._leases)

    @property
    def available(self) -> int:
        return max(0, self.capacity - len(self._leases))

    @property
    def full(self) -> bool:
        return len(self._leases) >= self.capacity

    async def try_acquire(self) -> Optional["Lease"]:
        """Atomic acquire. Returns a Lease on success, None if at capacity.

        Before checking capacity we reap leases whose owning Task is dead, so
        a stuck slot self-heals on the next attempt without waiting for the
        background reconciler."""
        async with self._lock:
            self._reap_dead_locked()
            if len(self._leases) >= self.capacity:
                return None
            try:
                task = asyncio.current_task()
            except RuntimeError:
                task = None
            lease = Lease(self, task, time.time())
            self._leases.append(lease)
            return lease

    async def _release(self, lease: "Lease") -> None:
        async with self._lock:
            try:
                self._leases.remove(lease)
            except ValueError:
                pass  # already released (e.g. reaped by reconciler)

    def _reap_dead_locked(self) -> int:
        """Drop leases whose owning Task is gone. Caller holds _lock."""
        if not self._leases:
            return 0
        alive: list[Lease] = []
        dead: list[Lease] = []
        for lease in self._leases:
            (alive if lease.task_alive else dead).append(lease)
        if dead:
            for lease in dead:
                lease.released = True
            logger.warning(
                "Reaped %s dead lease(s) on slot=%s (owning asyncio.Task ended without release)",
                len(dead), self.name,
            )
            self._leases = alive
        return len(dead)

    async def reconcile(self) -> int:
        """Reap dead leases. Called periodically by the background reconciler."""
        async with self._lock:
            return self._reap_dead_locked()

    def oldest_lease_age(self, now: Optional[float] = None) -> Optional[float]:
        if not self._leases:
            return None
        now = now or time.time()
        return now - min(l.acquired_at for l in self._leases)

    async def force_clear(self) -> int:
        """Admin-only: drop every lease. Intended for emergency reset."""
        async with self._lock:
            cleared = len(self._leases)
            for lease in self._leases:
                lease.released = True
            self._leases = []
            return cleared


class Lease:
    """An acquired slot. Auto-releases via async-context-manager OR when the
    owning asyncio.Task dies (whichever happens first)."""

    __slots__ = ("_slot", "_task_ref", "acquired_at", "released")

    def __init__(self, slot: Slot, task: Optional[asyncio.Task], acquired_at: float):
        self._slot = slot
        self._task_ref = weakref.ref(task) if task is not None else None
        self.acquired_at = acquired_at
        self.released = False

    @property
    def slot(self) -> Slot:
        return self._slot

    @property
    def task_alive(self) -> bool:
        if self._task_ref is None:
            return True  # synthesized lease (e.g. tests)
        task = self._task_ref()
        if task is None:
            return False
        return not task.done()

    def rebind_to_current_task(self) -> None:
        """Re-anchor this lease's liveness watchdog to the *currently* running
        asyncio.Task.

        Use this when transferring ownership from a request handler to a
        streaming-response generator that may continue running after the
        handler frame returns. Without rebinding, the reconciler could reap a
        still-streaming lease as soon as the original task ends."""
        try:
            task = asyncio.current_task()
        except RuntimeError:
            task = None
        self._task_ref = weakref.ref(task) if task is not None else None

    async def release(self) -> None:
        if self.released:
            return
        self.released = True
        await self._slot._release(self)

    async def __aenter__(self) -> "Lease":
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        await self.release()


class RequestLeases:
    """The pair of leases required to serve one inference request:

      * ``backend`` — a slot on a specific vLLM / llamacpp / embedding / ollama
        instance. Determines the bucket.
      * ``key``     — a slot in the per-(api_key, bucket) concurrency pool.

    Why a bundle (and not just two leases)?

    The two leases must be acquired *and released as a unit*, but for streaming
    responses ownership has to be transferred to a generator that outlives the
    handler frame. The old code used local boolean flags
    (``leases_owned_by_handler``, ``release_on_exit``, ``backend_owned_by_handler``,
    ``pre_acquired``) to track who owns release at each branch — a pattern that
    leaks slots the moment a maintainer adds a new ``return`` or ``raise`` site
    and forgets to flip a flag.

    ``RequestLeases`` encodes the contract as a type:

      * Used as ``async with``: both leases auto-release on exit (success,
        ``HTTPException``, cancellation, anything).
      * Call ``.detach()`` to transfer ownership to a streaming generator;
        ``__aexit__`` then becomes a no-op and the generator's own ``finally``
        is solely responsible for release.

    There is no way to forget the flag, because there is no flag — only the
    object's state, which the only entry point (the context manager protocol)
    consults automatically.
    """

    __slots__ = ("backend", "key", "_detached")

    def __init__(self, backend_lease: Lease, key_lease: Lease):
        self.backend = backend_lease
        self.key = key_lease
        self._detached = False

    @property
    def bucket(self) -> str:
        """Bucket name (``vllm`` / ``llamacpp`` / ``embedding`` / ``ollama``)."""
        return self.backend.slot.backend_type or "vllm"

    @property
    def backend_info(self) -> dict:
        """Compatibility shape for headers + SSE ``system_fingerprint``."""
        return {
            "backend": self.backend.slot.backend_type,
            "backend_url": self.backend.slot.meta.get("url"),
        }

    def detach(self) -> None:
        """Transfer ownership of both leases to the caller (typically a
        streaming generator). After ``detach()``, ``__aexit__`` is a no-op."""
        self._detached = True

    def rebind_to_current_task(self) -> None:
        """Re-anchor both leases' liveness watchdog to the current task. Call
        this at the top of a streaming generator after ``detach()`` so the
        reconciler tracks the right task."""
        self.backend.rebind_to_current_task()
        self.key.rebind_to_current_task()

    async def release(self) -> None:
        """Manual release of both leases. Idempotent. Used by streaming
        generators in their ``finally`` block after ``detach()``."""
        # Release in reverse-acquisition order. Both are best-effort: a release
        # failure on one must not block the other.
        for lease in (self.key, self.backend):
            try:
                await lease.release()
            except Exception as e:
                logger.error(f"lease release failed during bundle release: {e}")

    async def __aenter__(self) -> "RequestLeases":
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        if self._detached:
            return
        await self.release()


async def acquire_request_leases(
    model: str,
    api_key: str,
    key_config: dict,
    endpoint: str,
    priority: str,
    estimated_prompt_tokens: int,
) -> RequestLeases:
    """Acquire the backend Slot first (it determines the bucket), then the
    per-key Slot in that bucket.

    Atomicity guarantee: if the second acquire raises *for any reason*
    (HTTPException 429, CancelledError, network glitch, anything that derives
    from BaseException), the first acquire is rolled back before the exception
    propagates. After this function returns successfully, the caller holds
    exactly two leases — both of which will be released by the returned
    ``RequestLeases`` context manager (unless explicitly detached).

    This eliminates the hand-written ``try/except BaseException: await
    release(); raise`` boilerplate that appeared in every handler.
    """
    backend_lease = await backend_manager.acquire_slot(model)
    try:
        key_lease = await rate_limiter.acquire_key_slot(
            api_key=api_key,
            key_config=key_config,
            bucket=backend_lease.slot.backend_type or "vllm",
            endpoint=endpoint,
            model=model,
            priority=priority,
            estimated_prompt_tokens=estimated_prompt_tokens,
        )
    except BaseException:
        await backend_lease.release()
        raise
    return RequestLeases(backend_lease, key_lease)


# =============================================================================
# Rate Limiter  (enterprise pattern: immediate 429, no server-side queuing)
# =============================================================================

class RateLimiter:
    """
    Per-(api_key, bucket) concurrency + RPM + TPM enforcement.

    Built on the Slot/Lease primitive so the concurrency counter is structurally
    incapable of leaking. Each successful acquire returns a Lease bound to the
    calling asyncio.Task; the background reconciler force-releases any lease
    whose task ends without explicit release.

    Three checks, in this order:

      1. Per-key concurrency  (in-process Slot, no Redis)
      2. RPM                  (Redis fixed window, fails open on Redis error)
      3. TPM                  (Redis fixed window, fails open on Redis error)

    On 429 a structured error body + accurate Retry-After is returned.
    The handler does not need to track release: it just `async with` the
    returned Lease.

    Why no server-side queue?
      - Each waiting coroutine holds a uvicorn worker slot + Redis connection.
      - A DDoS / runaway client can exhaust all worker slots before the GPU
        is ever touched.
      - The client already has retry logic; duplicating it server-side wastes
        resources and adds latency unpredictability.
    """

    SERVICE_BUCKETS = ("vllm", "embedding", "llamacpp", "ollama")

    def __init__(self):
        # pools[(api_key, bucket)] = Slot
        # A pool is created lazily on first use and kept indefinitely. The Slot
        # itself holds no per-request memory beyond the in-flight Leases.
        self.pools: dict[tuple[str, str], Slot] = {}
        # Guards pools-dict mutations only; per-slot atomicity is on the Slot.
        self._pools_lock = asyncio.Lock()

    # ----- backend-health helpers (used by snapshot + admin display only) -----
    # IMPORTANT: these are NO LONGER used to compute per-key concurrency caps.
    # Capacity caps now derive from CONFIGURED backend count (len of VLLM_URLS,
    # number of llamacpp/embedding/ollama URLs in config), so a transient
    # health-check flap cannot halve a user's cap.

    def _healthy_gpu_count(self) -> int:
        try:
            count = sum(
                1 for key, healthy in backend_manager.backend_health.items()
                if key.startswith("vllm:") and healthy
            )
            return max(1, count)
        except Exception:
            return 1

    def _healthy_embedding_count(self) -> int:
        return self._healthy_backend_count("embedding")

    def _healthy_backend_count(self, backend_type: str) -> int:
        try:
            count = sum(
                1 for key, healthy in backend_manager.backend_health.items()
                if key.startswith(f"{backend_type}:") and healthy
            )
            return max(1, count)
        except Exception:
            return 1

    # ----- bucket / cap derivation ------------------------------------------

    def _limit_bucket(self, endpoint: str, backend_type: Optional[str] = None) -> str:
        """Map a request to an independent service limiter pool."""
        if backend_type in self.SERVICE_BUCKETS:
            return backend_type
        if endpoint == "embeddings":
            return "embedding"
        return "vllm"

    def _configured_backend_count(self, bucket: str) -> int:
        """How many backends of this type are CONFIGURED (not necessarily healthy).

        This is the right denominator for per-key cap calculations: it's stable
        across health-check blips and grows monotonically when you add capacity
        (e.g. bump VLLM StatefulSet replicas and add the new pod URL to
        VLLM_URLS in the configmap)."""
        if bucket == "vllm":
            return max(1, len(config.VLLM_URLS))
        return 1  # llamacpp / embedding / ollama are single-URL today

    def _concurrency_cap(self, key_config: dict, bucket: str = "vllm") -> int:
        """Per-key concurrency cap for a bucket.

        Priority:
          1. Explicit value in key_config (e.g. vllm_concurrency_per_key)
          2. Default: CONCURRENCY_PER_<bucket> * configured backend count
        Clamped to [1, 256]."""
        try:
            if bucket == "embedding":
                raw = key_config.get(
                    "embedding_concurrency_per_key",
                    config.CONCURRENCY_PER_EMBEDDING_REPLICA * self._configured_backend_count("embedding"),
                )
            elif bucket == "llamacpp":
                raw = key_config.get(
                    "llamacpp_concurrency_per_key",
                    config.CONCURRENCY_PER_LLAMACPP_REPLICA * self._configured_backend_count("llamacpp"),
                )
            elif bucket == "ollama":
                raw = key_config.get(
                    "ollama_concurrency_per_key",
                    config.CONCURRENCY_PER_OLLAMA_REPLICA * self._configured_backend_count("ollama"),
                )
            else:
                raw = key_config.get(
                    "vllm_concurrency_per_key",
                    key_config.get(
                        "chat_concurrency_per_key",
                        key_config.get(
                            "concurrency_per_key",
                            config.CONCURRENCY_PER_KEY_DEFAULT * self._configured_backend_count("vllm"),
                        ),
                    ),
                )
            return max(1, min(256, int(raw)))
        except (TypeError, ValueError):
            if bucket == "embedding":
                return config.CONCURRENCY_PER_EMBEDDING_REPLICA
            if bucket == "llamacpp":
                return config.CONCURRENCY_PER_LLAMACPP_REPLICA
            if bucket == "ollama":
                return config.CONCURRENCY_PER_OLLAMA_REPLICA
            return config.CONCURRENCY_PER_KEY_DEFAULT

    def _rpm_limit(self, key_config: dict, bucket: str) -> int:
        if bucket == "embedding":
            return self._safe_int(
                key_config.get(
                    "embedding_requests_per_minute",
                    config.DEFAULT_EMBEDDING_REQUESTS_PER_MINUTE
                ),
                default=config.DEFAULT_EMBEDDING_REQUESTS_PER_MINUTE,
                min_val=1,
                max_val=100_000,
            )
        if bucket == "llamacpp":
            return self._safe_int(
                key_config.get(
                    "llamacpp_requests_per_minute",
                    config.DEFAULT_LLAMACPP_REQUESTS_PER_MINUTE
                ),
                default=config.DEFAULT_LLAMACPP_REQUESTS_PER_MINUTE,
                min_val=1,
                max_val=100_000,
            )
        if bucket == "ollama":
            return self._safe_int(
                key_config.get(
                    "ollama_requests_per_minute",
                    config.DEFAULT_OLLAMA_REQUESTS_PER_MINUTE
                ),
                default=config.DEFAULT_OLLAMA_REQUESTS_PER_MINUTE,
                min_val=1,
                max_val=100_000,
            )
        return self._safe_int(
            key_config.get("requests_per_minute", config.DEFAULT_REQUESTS_PER_MINUTE),
            default=config.DEFAULT_REQUESTS_PER_MINUTE,
            min_val=1,
            max_val=100_000,
        )

    def _tpm_limit(self, key_config: dict, bucket: str) -> int:
        key_tpm = key_config.get("tokens_per_minute")
        if bucket == "embedding":
            return self._safe_int(
                key_config.get(
                    "embedding_tokens_per_minute",
                    key_tpm if key_tpm is not None else config.DEFAULT_EMBEDDING_TOKENS_PER_MINUTE
                ),
                default=config.DEFAULT_EMBEDDING_TOKENS_PER_MINUTE,
                min_val=config.MIN_TOKENS_PER_MINUTE,
                max_val=10_000_000,
            )
        if bucket == "llamacpp":
            return self._safe_int(
                key_config.get(
                    "llamacpp_tokens_per_minute",
                    key_tpm if key_tpm is not None else config.DEFAULT_LLAMACPP_TOKENS_PER_MINUTE
                ),
                default=config.DEFAULT_LLAMACPP_TOKENS_PER_MINUTE,
                min_val=config.MIN_TOKENS_PER_MINUTE,
                max_val=10_000_000,
            )
        if bucket == "ollama":
            return self._safe_int(
                key_config.get(
                    "ollama_tokens_per_minute",
                    key_tpm if key_tpm is not None else config.DEFAULT_OLLAMA_TOKENS_PER_MINUTE
                ),
                default=config.DEFAULT_OLLAMA_TOKENS_PER_MINUTE,
                min_val=config.MIN_TOKENS_PER_MINUTE,
                max_val=10_000_000,
            )
        return self._safe_int(
            key_config.get("tokens_per_minute", config.DEFAULT_TOKENS_PER_MINUTE),
            default=config.DEFAULT_TOKENS_PER_MINUTE,
            min_val=config.MIN_TOKENS_PER_MINUTE,
            max_val=10_000_000,
        )

    def _concurrency_limit_description(self, bucket: str) -> str:
        if bucket == "embedding":
            return (
                f"embedding pool: {self._configured_backend_count('embedding')} embedding replica(s) "
                f"\u00d7 {config.CONCURRENCY_PER_EMBEDDING_REPLICA} slots"
            )
        if bucket == "llamacpp":
            return (
                f"llama.cpp pool: {self._configured_backend_count('llamacpp')} replica(s) "
                f"\u00d7 {config.CONCURRENCY_PER_LLAMACPP_REPLICA} slots"
            )
        if bucket == "ollama":
            return (
                f"Ollama pool: {self._configured_backend_count('ollama')} replica(s) "
                f"\u00d7 {config.CONCURRENCY_PER_OLLAMA_REPLICA} slots"
            )
        return (
            f"vLLM pool: {self._configured_backend_count('vllm')} GPU(s) "
            f"\u00d7 {config.CONCURRENCY_PER_GPU} slots"
        )

    def _safe_int(self, value, default: int, min_val: int = 1, max_val: int = 10_000_000) -> int:
        """Coerce a value from key_config (may be str from Redis JSON) to int,
        clamped to [min_val, max_val].  Returns default on any error."""
        try:
            return max(min_val, min(max_val, int(value)))
        except (TypeError, ValueError):
            return default

    # ----- slot pool management ---------------------------------------------

    async def _get_or_create_pool(self, api_key: str, bucket: str, capacity: int) -> Slot:
        """Look up the Slot for (api_key, bucket), creating it on first use.

        If the configured cap changed since the pool was created (e.g. key was
        re-issued with a different limit), we update the Slot's capacity in
        place — already-held leases are unaffected but new acquires use the
        new ceiling."""
        pool_key = (api_key, bucket)
        existing = self.pools.get(pool_key)
        if existing is not None:
            if existing.capacity != capacity:
                existing.update_capacity(capacity)
            return existing
        async with self._pools_lock:
            existing = self.pools.get(pool_key)
            if existing is not None:
                if existing.capacity != capacity:
                    existing.update_capacity(capacity)
                return existing
            slot = Slot(
                name=f"key:{api_key[:16]}:{bucket}",
                capacity=capacity,
                backend_type=bucket,
                api_key=api_key,
                bucket=bucket,
            )
            self.pools[pool_key] = slot
            return slot

    async def acquire_key_slot(
        self,
        api_key: str,
        key_config: dict,
        bucket: str,
        endpoint: str,
        model: str,
        priority: str,
        estimated_prompt_tokens: int,
    ) -> Lease:
        """Acquire a per-key concurrency lease + run RPM and TPM checks.

        Returns a Lease that the caller must use as an async-context-manager
        (or explicit release()). Raises HTTPException(429) on any check failure
        with a structured body and accurate Retry-After header.

        Concurrency check goes FIRST because it's free (no network). If it
        fails we return immediately without touching Redis.
        """
        if bucket not in self.SERVICE_BUCKETS:
            bucket = self._limit_bucket(endpoint)

        rpm_limit = self._rpm_limit(key_config, bucket)
        tpm_limit = self._tpm_limit(key_config, bucket)
        estimated_prompt_tokens = max(0, int(estimated_prompt_tokens))
        concurrency_cap = self._concurrency_cap(key_config, bucket)

        # ---- 1. Per-key concurrency ----
        pool = await self._get_or_create_pool(api_key, bucket, concurrency_cap)
        lease = await pool.try_acquire()
        if lease is None:
            CONCURRENCY_REJECTED.labels(endpoint=endpoint).inc()
            REQUEST_COUNT.labels(
                model=model, priority=priority, status="concurrency_exceeded", endpoint=endpoint,
            ).inc()
            raise HTTPException(
                status_code=429,
                detail={
                    "error": {
                        "type": "concurrency_limit_exceeded",
                        "message": (
                            f"You have {pool.inflight} {bucket} request(s) in-flight. "
                            f"Limit is {concurrency_cap} "
                            f"({self._concurrency_limit_description(bucket)}). "
                            f"Retry in ~5s when an in-flight request completes."
                        ),
                        "limit_bucket": bucket,
                        "current_inflight": pool.inflight,
                        "limit": concurrency_cap,
                        "retry_after": 5,
                    },
                },
                headers={"Retry-After": "5"},
            )

        try:
            # ---- 2. RPM ----
            try:
                rpm_ok, retry_after_rpm = await redis_client.check_rate_limit_with_info(
                    api_key, rpm_limit, bucket=bucket,
                )
            except Exception as e:
                logger.warning(f"RPM check failed for {api_key[:16]}…:{bucket} (fail-open): {e}")
                rpm_ok, retry_after_rpm = True, 0
            if not rpm_ok:
                REQUEST_COUNT.labels(
                    model=model, priority=priority, status="rate_limited", endpoint=endpoint,
                ).inc()
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": {
                            "type": "rate_limit_exceeded",
                            "message": (
                                f"{bucket} rate limit exceeded: {rpm_limit} requests/minute. "
                                f"Retry in {retry_after_rpm}s."
                            ),
                            "limit_bucket": bucket,
                            "limit": rpm_limit,
                            "retry_after": retry_after_rpm,
                        },
                    },
                    headers={"Retry-After": str(retry_after_rpm)},
                )

            # ---- 3. TPM ----
            try:
                tpm_ok, retry_after_tpm = await redis_client.check_tpm_limit(
                    api_key, estimated_prompt_tokens, tpm_limit, bucket=bucket,
                )
            except Exception as e:
                logger.warning(f"TPM check failed for {api_key[:16]}…:{bucket} (fail-open): {e}")
                tpm_ok, retry_after_tpm = True, 0
            if not tpm_ok:
                TPM_REJECTED.labels(endpoint=endpoint).inc()
                REQUEST_COUNT.labels(
                    model=model, priority=priority, status="tpm_exceeded", endpoint=endpoint,
                ).inc()
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": {
                            "type": "tokens_per_minute_exceeded",
                            "message": (
                                f"{bucket} token rate limit exceeded: {tpm_limit} tokens/minute. "
                                f"Retry in {retry_after_tpm}s."
                            ),
                            "limit_bucket": bucket,
                            "limit": tpm_limit,
                            "estimated_prompt_tokens": estimated_prompt_tokens,
                            "retry_after": retry_after_tpm,
                        },
                    },
                    headers={"Retry-After": str(retry_after_tpm)},
                )
        except BaseException:
            await lease.release()
            raise

        return lease

    # ----- diagnostics + admin -----------------------------------------------

    def get_inflight(self) -> dict[str, dict[str, int]]:
        """Return current per-key in-flight counts (zero-value pools excluded)."""
        counts: dict[str, dict[str, int]] = {}
        for (api_key, bucket), slot in self.pools.items():
            n = slot.inflight
            if n > 0:
                counts.setdefault(api_key, {})[bucket] = n
        return counts

    async def reconcile(self) -> int:
        """Periodic reaper called by the maintenance loop."""
        total = 0
        for slot in list(self.pools.values()):
            total += await slot.reconcile()
        return total

    async def snapshot(self) -> dict:
        """Return live limiter state for diagnostics."""
        now = time.time()
        per_key_inflight: dict[str, dict[str, int]] = {}
        oldest_age: dict[str, dict[str, int]] = {}
        for (api_key, bucket), slot in self.pools.items():
            n = slot.inflight
            if n <= 0:
                continue
            # This reaches metrics-scope callers: a shortened id, never the key.
            key_label = api_key[:len(API_KEY_ID_PREFIX) + 16]
            per_key_inflight.setdefault(key_label, {})[bucket] = n
            age = slot.oldest_lease_age(now)
            if age is not None:
                oldest_age.setdefault(key_label, {})[bucket] = int(age)
        return {
            "per_key_inflight": per_key_inflight,
            "oldest_lease_age_seconds": oldest_age,
            # Retained for backward compat with old dashboards; the new scheme
            # has no TTL — leases are reaped by asyncio.Task liveness instead.
            "lease_ttl_seconds": None,
            "last_snapshot_pruned": 0,
            "healthy_gpus": self._healthy_gpu_count(),
            "healthy_embedding_replicas": self._healthy_embedding_count(),
            "healthy_backend_instances": {
                bucket: self._healthy_backend_count(bucket)
                for bucket in self.SERVICE_BUCKETS
            },
            "configured_backend_instances": {
                bucket: self._configured_backend_count(bucket)
                for bucket in self.SERVICE_BUCKETS
            },
            "concurrency_cap_per_key": self._concurrency_cap({}, "vllm"),
            "concurrency_caps_per_key": {
                bucket: self._concurrency_cap({}, bucket)
                for bucket in self.SERVICE_BUCKETS
            },
            "reconcile_interval_seconds": max(1, int(config.SLOT_RECONCILE_INTERVAL_SECONDS)),
        }

    async def reset(self, api_key: Optional[str] = None, bucket: Optional[str] = None) -> dict:
        """Clear leases for one (api_key, bucket), one api_key, or the whole pod."""
        before = self.get_inflight()
        cleared = 0
        if api_key and bucket:
            slot = self.pools.get((api_key, bucket))
            if slot is not None:
                cleared = await slot.force_clear()
        elif api_key:
            for (k, b), slot in list(self.pools.items()):
                if k == api_key:
                    cleared += await slot.force_clear()
        else:
            for slot in list(self.pools.values()):
                cleared += await slot.force_clear()
        return {
            "cleared": cleared,
            "before": before,
            "after": self.get_inflight(),
        }


rate_limiter = RateLimiter()

# =============================================================================
# Backend Manager
# =============================================================================

# How long a changed embedding model may take to appear before the cache comes back on
# regardless. It covers a slow download. Past it, the id read from the backend is used.
EMBEDDING_MODEL_CHANGE_HOLD_SECONDS = 1800


class BackendStatusError(Exception):
    """A backend answered a streaming request with an error status."""

    def __init__(self, status_code: int, body: str):
        super().__init__(f"Backend answered {status_code}")
        self.status_code = status_code
        self.body = body


class BackendStream:
    """A backend's open streaming response. aclose() may be called more than once,
    and without having read anything."""

    def __init__(self, response: httpx.Response, backend_type: str):
        self._response = response
        self._backend_type = backend_type

    async def __aiter__(self):
        async for chunk in self._response.aiter_bytes():
            chunk_str = chunk.decode("utf-8", errors="ignore")
            if chunk_str.startswith("data: ") and not chunk_str.startswith("data: [DONE]"):
                try:
                    json_str = chunk_str[6:].strip()
                    if json_str:
                        event_data = json.loads(json_str)
                        event_data["system_fingerprint"] = f"{self._backend_type}"
                        chunk = f"data: {json.dumps(event_data)}\n\n".encode()
                except Exception:
                    pass
            yield chunk

    async def aclose(self) -> None:
        await self._response.aclose()


class BackendManager:
    """Routing + capacity tracking for vLLM / llama.cpp / embedding / Ollama.

    Public contract (preserved for handlers, admin, lifespan):
      - start() / stop()
      - health_check()  - 30s loop populates self.backend_health
      - backend_health: dict[str, bool]      ("vllm:<url>" -> True/False)
      - acquire_slot(model) -> Lease         NEW primary entry point
      - forward(method, endpoint, model, data, lease, stream=False)  NEW
      - snapshot()                           same shape as before
      - reset(backend_type=None, backend_key=None)
      - load_ollama_model(name), pull_ollama_model(name)
      - discover_models()
      - get_backend_url(model)               kept for any external caller

    The lease-list-with-TTL bookkeeping has been replaced with one Slot per
    (backend_type, url). Counter cannot drift: acquire returns a Lease bound
    to asyncio.current_task() and either the async-with exit or the background
    reconciler releases it.
    """

    def __init__(self):
        self.http_client: Optional[httpx.AsyncClient] = None
        self.backend_health: dict[str, bool] = {}
        # Per-backend Slot keyed by "<backend_type>:<url>"
        self.slots: dict[str, Slot] = {}
        self._reconcile_task: Optional[asyncio.Task] = None
        self._metrics_audit_task: Optional[asyncio.Task] = None
        # Set while an admin's embedding model change is rolling out.
        self._embedding_change: Optional[dict] = None

    # ------------------------------------------------------------------ setup

    async def start(self):
        self.http_client = httpx.AsyncClient(timeout=config.BACKEND_HTTP_TIMEOUT_SECONDS)
        for url in config.VLLM_URLS:
            self._register_slot("vllm", url, config.MAX_INFLIGHT_PER_VLLM_BACKEND)
        self._register_slot("llamacpp", config.LLAMACPP_URL, config.MAX_INFLIGHT_PER_LLAMACPP_BACKEND)
        self._register_slot("embedding", config.EMBEDDING_URL, config.MAX_INFLIGHT_PER_EMBEDDING_BACKEND)
        self._register_slot("ollama", config.OLLAMA_URL, config.MAX_INFLIGHT_PER_OLLAMA_BACKEND)

        # Spawn the reconciler BEFORE the first health check. The reaper is
        # the gateway's safety net; if startup health_check raises (network
        # blip during pod start) we still want the reaper running so that any
        # lease acquired during the partial-startup window is eventually freed.
        self._reconcile_task = asyncio.create_task(self._reconcile_loop())
        if config.RECONCILE_VLLM_METRICS:
            self._metrics_audit_task = asyncio.create_task(self._metrics_audit_loop())

        try:
            await self.health_check()
        except Exception as e:
            # Don't fail pod startup on a transient health-check error; the
            # background health_check_loop will retry every 30s.
            logger.error(f"Initial health_check failed (will retry): {e}")

    def _register_slot(self, backend_type: str, url: str, capacity: int) -> None:
        key = f"{backend_type}:{url}"
        self.slots[key] = Slot(name=key, capacity=capacity, backend_type=backend_type, url=url)
        self.backend_health[key] = False

    async def stop(self):
        for task in (self._reconcile_task, self._metrics_audit_task):
            if task is not None and not task.done():
                task.cancel()
                try:
                    await task
                except (asyncio.CancelledError, Exception):
                    pass
        if self.http_client:
            await self.http_client.aclose()

    # ----------------------------------------------------------- reconciliation

    async def _reconcile_loop(self):
        """Periodically reap leases whose owning Task is dead."""
        interval = max(1, int(config.SLOT_RECONCILE_INTERVAL_SECONDS))
        while True:
            try:
                await asyncio.sleep(interval)
            except asyncio.CancelledError:
                return
            try:
                for slot in self.slots.values():
                    await slot.reconcile()
                # Per-key (rate_limiter) reconciliation runs here too so the
                # whole gateway has a single heartbeat rather than two.
                try:
                    await rate_limiter.reconcile()
                except Exception as e:
                    logger.debug(f"rate-limiter reconcile failed: {e}")
                self._sync_metrics()
            except Exception as e:
                logger.error(f"backend reconcile loop failed: {e}")

    async def _metrics_audit_loop(self):
        """Optional: audit gateway counter against vLLM's own /metrics.

        Log-only. Never auto-corrects. Disabled by RECONCILE_VLLM_METRICS=false."""
        interval = max(5, int(config.RECONCILE_VLLM_METRICS_INTERVAL_SECONDS))
        while True:
            try:
                await asyncio.sleep(interval)
            except asyncio.CancelledError:
                return
            for key, slot in self.slots.items():
                if slot.backend_type != "vllm":
                    continue
                if not self.backend_health.get(key, False):
                    continue
                try:
                    resp = await self.http_client.get(f"{slot.meta['url']}/metrics", timeout=3.0)
                    if resp.status_code != 200:
                        continue
                    running = self._parse_vllm_running(resp.text)
                    if running is None:
                        continue
                    if running != slot.inflight:
                        logger.warning(
                            "vLLM drift on %s: gateway=%s, vllm=%s "
                            "(audit only — gateway is source of truth)",
                            key, slot.inflight, running,
                        )
                except Exception as e:
                    logger.debug(f"vllm metrics audit failed for {key}: {e}")

    @staticmethod
    def _parse_vllm_running(metrics_text: str) -> Optional[int]:
        """Parse `vllm:num_requests_running` value from a Prometheus exposition.

        Format: `vllm:num_requests_running{model="..."} 1.0`"""
        for line in metrics_text.splitlines():
            if line.startswith("vllm:num_requests_running") and not line.startswith("#"):
                try:
                    return int(float(line.rsplit(" ", 1)[1]))
                except (ValueError, IndexError):
                    return None
        return None

    def _sync_metrics(self) -> None:
        totals = {"vllm": 0, "llamacpp": 0, "embedding": 0, "ollama": 0}
        for slot in self.slots.values():
            totals[slot.backend_type] = totals.get(slot.backend_type, 0) + slot.inflight
        for backend_type, total in totals.items():
            BACKEND_INFLIGHT.labels(backend=backend_type).set(total)

    # ------------------------------------------------------------- diagnostics

    @property
    def backend_inflight(self) -> dict[str, int]:
        """Per-backend current inflight count. Snapshot is taken by reading
        each slot's atomic ``inflight`` counter, no lock needed because we
        just read an integer."""
        return {key: slot.inflight for key, slot in self.slots.items()}

    def snapshot(self) -> dict:
        now = time.time()
        return {
            "inflight": {key: slot.inflight for key, slot in self.slots.items()},
            "capacity": {key: slot.capacity for key, slot in self.slots.items()},
            "available": {key: slot.available for key, slot in self.slots.items()},
            "oldest_lease_age_seconds": {
                key: int(age)
                for key, slot in self.slots.items()
                for age in [slot.oldest_lease_age(now)] if age is not None
            },
            # The new design has no TTL; key kept for dashboard compatibility.
            "lease_ttl_seconds": None,
            "last_snapshot_pruned": 0,
            "reconcile_interval_seconds": max(1, int(config.SLOT_RECONCILE_INTERVAL_SECONDS)),
            "vllm_metrics_audit": config.RECONCILE_VLLM_METRICS,
        }

    async def reset(
        self,
        backend_type: Optional[str] = None,
        backend_key: Optional[str] = None,
    ) -> dict:
        """Admin: force-clear leases. Returns a before/after summary."""
        before = {key: slot.inflight for key, slot in self.slots.items()}

        if backend_key:
            keys = [backend_key] if backend_key in self.slots else []
        elif backend_type:
            keys = [k for k, s in self.slots.items() if s.backend_type == backend_type]
        else:
            keys = list(self.slots.keys())

        cleared = 0
        for key in keys:
            slot = self.slots.get(key)
            if slot is not None:
                cleared += await slot.force_clear()

        self._sync_metrics()
        return {
            "cleared": cleared,
            "before": before,
            "after": {key: slot.inflight for key, slot in self.slots.items()},
        }

    # --- legacy shim: some code paths may still want this synchronous variant
    def reset_sync(self, *args, **kwargs):  # pragma: no cover
        """Legacy compat: synchronous reset() is no longer supported."""
        raise RuntimeError("BackendManager.reset is now async; await it.")

    # --------------------------------------------------------------- routing

    def _candidates_for(self, model: str) -> list[Slot]:
        """Return the ordered list of slots eligible to serve ``model``.

        Multi-backend routing
        ---------------------
        The list is built from the ModelRegistry's view of which backend types
        actually serve the requested model, so we never route to a backend
        that would 404. Order is:

          1. Backends serving the model, in routing-priority order
             (``vllm`` → ``llamacpp`` → ``ollama``).
          2. Within a backend type, slots are sorted by current ``inflight``
             ascending — so a 2-GPU cluster naturally spreads load, and after
             GPU 1 fills up GPU 2 picks up the next request.

        ``acquire_slot`` walks this list and takes the first slot whose
        ``try_acquire`` succeeds, giving us the "GPU first, spill to CPU when
        GPUs are full" overflow behaviour for any model loaded on both.

        Concrete examples
        -----------------
        Assume 2 healthy vLLM pods + 1 healthy llama.cpp + 1 healthy ollama,
        all with ``MAX_INFLIGHT_PER_*_BACKEND=1``:

          * Model ``qwen2.5:7b`` loaded on vllm AND llamacpp:
              ``[vllm-0(0), vllm-1(0), llamacpp(0)]``
              → 1st request hits vllm-0, 2nd hits vllm-1, 3rd spills to
              llama.cpp, 4th raises 429 (cluster at capacity).
          * Model ``qwen2.5:7b`` loaded only on vllm:
              ``[vllm-0(0), vllm-1(0)]``
              → 3rd request raises 429 — does NOT spill to llamacpp, because
              llama.cpp doesn't have this model.
          * Embedding model:
              ``[embedding(0)]``
              → only ever routed to the embedding backend; can never consume
              vllm or llamacpp slots.
          * Unknown model under HORIZONTAL_SCALING:
              ``[vllm…, llamacpp, ollama]`` (best-effort fallback)
          * Unknown model with HORIZONTAL_SCALING=false:
              ``[]`` (caller raises 404-grade 503)
        """
        served_by = model_registry.get_model_backends(model)

        if not served_by:
            # Model not in registry. Under horizontal scaling we still try the
            # chat backends in priority order — useful while a freshly-added
            # model is mid-discovery and the registry hasn't caught up yet.
            if config.HORIZONTAL_SCALING:
                served_by = ["vllm", "llamacpp", "ollama"]
            else:
                return []

        result: list[Slot] = []
        for bt in served_by:
            if not bt:
                continue
            healthy = [
                s for s in self.slots.values()
                if s.backend_type == bt and self.backend_health.get(s.name, False)
            ]
            if not healthy:
                continue
            # Within a backend type, sort by least-loaded first so a 2-GPU
            # cluster spreads load (GPU 1 if both empty; GPU 2 once GPU 1 is
            # busy). Ties broken by URL for deterministic routing.
            healthy.sort(key=lambda s: (s.inflight, s.meta.get("url", "")))
            result.extend(healthy)
        return result

    async def acquire_slot(self, model: str) -> Lease:
        """Acquire a slot on the best available backend for ``model``.

        Selection algorithm
        -------------------
        1. Ask the registry: "which backend types serve this model?"
        2. Iterate those backend types in routing priority (vllm → llamacpp →
           ollama), and within a type iterate the healthy slots ordered by
           least-loaded first.
        3. Call ``try_acquire`` on each slot until one succeeds. ``try_acquire``
           is itself atomic under the slot's own lock, so two concurrent
           requests racing for the last slot on the same backend cannot both
           win.
        4. If no slot accepts (every eligible backend is at capacity), raise
           429 with the first candidate's inflight/capacity in the body.
        5. If the model has no eligible backends at all (none of vllm,
           llamacpp, ollama serves this model AND it's not lazy-loadable),
           raise 503.

        Multi-backend behaviour
        -----------------------
        When the same model is loaded on both vLLM and llama.cpp, this method
        prefers GPU (vLLM) and spills to CPU (llama.cpp) only when all GPU
        slots are full. When the model is only on vLLM, the method NEVER
        spills to llama.cpp — instead it raises 429, because routing to a
        backend that doesn't have the model would just produce an upstream
        404 the client can't easily distinguish from "no capacity".

        Error contracts (unchanged from old code)
        -----------------------------------------
        * 503  ``{"error": "No healthy backend available", "hint": ...}``
        * 429  ``{"error": {"type": "backend_concurrency_limit_exceeded",
                           "message": "...", "limit_bucket": "...",
                           "current_inflight": N, "limit": M, "retry_after": 5}}``
        """
        candidates = self._candidates_for(model)
        if not candidates:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": "No healthy backend available",
                    "hint": "All inference backends are currently unhealthy. "
                            "Check /health/backends for status.",
                },
            )

        for slot in candidates:
            lease = await slot.try_acquire()
            if lease is not None:
                self._sync_metrics()
                return lease

        # Everyone is full — return the most-meaningful 429 (first candidate
        # was the least-loaded one, so its number is the cluster's best case).
        snapshot = candidates[0]
        raise HTTPException(
            status_code=429,
            detail={
                "error": {
                    "type": "backend_concurrency_limit_exceeded",
                    "message": (
                        f"{snapshot.backend_type} backend is at capacity: "
                        f"{snapshot.inflight}/{snapshot.capacity} in-flight."
                    ),
                    "limit_bucket": snapshot.backend_type,
                    "current_inflight": snapshot.inflight,
                    "limit": snapshot.capacity,
                    "retry_after": 5,
                },
            },
            headers={"Retry-After": "5"},
        )

    def get_backend_url(self, model: str) -> tuple[Optional[str], Optional[str]]:
        """Legacy: pick (backend_type, url) for `model`. Not used by the new
        acquire_slot path; kept for any external caller and for diagnostics."""
        candidates = self._candidates_for(model)
        if not candidates:
            return None, None
        chosen = candidates[0]
        return chosen.backend_type, chosen.meta.get("url")

    async def discover_models(self):
        """Query backends to discover loaded models."""
        # Discover vLLM models
        vllm_discovery_succeeded = False
        vllm_models: set[str] = set()
        for url in config.VLLM_URLS:
            try:
                resp = await self.http_client.get(f"{url}/v1/models", timeout=10.0)
                if resp.status_code == 200:
                    vllm_discovery_succeeded = True
                    data = resp.json()
                    for model in data.get("data", []):
                        model_id = model.get("id")
                        if model_id:
                            vllm_models.add(model_id)
                            model_registry.register_model(model_id, "vllm", "ready", model)
                            logger.info(f"Discovered vLLM model: {model_id}")
            except Exception as e:
                logger.debug(f"Could not discover vLLM models from {url}: {e}")
        if vllm_discovery_succeeded:
            model_registry.reconcile_backend_models("vllm", vllm_models)

        # Discover llama.cpp model (it serves one model)
        try:
            resp = await self.http_client.get(f"{config.LLAMACPP_URL}/health", timeout=5.0)
            if resp.status_code == 200:
                # llama.cpp doesn't have a models endpoint, use configured name or default
                model_name = os.getenv("LLAMACPP_MODEL_NAME", "llama-cpu")
                model_registry.register_model(model_name, "llamacpp", "ready")
                model_registry.reconcile_backend_models("llamacpp", {model_name})
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
                backend_model_id = self._settled_embedding_model_id(await self._embedding_backend_model_id())
                model_registry.register_model(
                    model_name, "embedding", "ready", {"backend_model_id": backend_model_id},
                )
                model_registry.reconcile_backend_models("embedding", {model_name})
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
                loaded_ollama_models: set[str] = set()
                for model in ps_data.get("models", []):
                    model_name = model.get("name", "")
                    # Only strip :latest suffix, keep other tags
                    if model_name.endswith(":latest"):
                        model_name = model_name[:-7]
                    if model_name:
                        loaded_ollama_models.add(model_name)
                        model_registry.register_model(model_name, "ollama", "ready", model)
                        logger.info(f"Discovered loaded Ollama model: {model_name}")
                model_registry.reconcile_backend_models("ollama", loaded_ollama_models)
        except Exception as e:
            logger.debug(f"Could not discover Ollama models: {e}")

    async def _embedding_backend_model_id(self) -> Optional[str]:
        """What the embedding backend says it is serving, None if it doesn't say.

        The gateway's model name comes from its own environment, which an admin
        model change doesn't touch, so it can't tell two models apart. llama.cpp
        reports the model file as the id, plus metadata that also separates two
        files with the same name.
        """
        try:
            resp = await self.http_client.get(f"{config.EMBEDDING_URL}/v1/models", timeout=5.0)
            if resp.status_code != 200:
                return None
            model = resp.json()["data"][0]
            return json.dumps({"id": model["id"], "meta": model.get("meta")}, sort_keys=True)
        except Exception as e:
            logger.debug(f"Could not read the embedding backend's model: {type(e).__name__}")
            return None

    def note_embedding_model_change(self) -> None:
        """An admin is replacing the embedding model: stop using the cache right away.

        A request's vector must only be cached under the model that computed it, and
        discovery runs every 30s. Until it has seen the new model, the id stays None,
        which is how the embeddings handler knows to skip the cache.

        Each gateway pod only knows about changes made through itself. Any other pod
        catches up at its next discovery, so up to 30s later.
        """
        previous = None
        for entry in model_registry.loaded_models.values():
            info = entry["backends"].get("embedding")
            if info:
                previous = info.get("backend_model_id") or previous
                info["backend_model_id"] = None
        self._embedding_change = {
            "previous": previous,
            "candidate": None,
            "deadline": time.monotonic() + EMBEDDING_MODEL_CHANGE_HOLD_SECONDS,
        }

    def _settled_embedding_model_id(self, read_id: Optional[str]) -> Optional[str]:
        """The id discovery may publish, given what it just read from the backend.

        During a model change the old pod keeps serving until the new one is Ready, so
        the old id proves nothing. A new id has to be read twice in a row, as for a
        moment both pods are behind the Service. Choosing the model already running
        never shows a new id, so the hold also has a time limit, after which the cache
        is merely back on.
        """
        change = self._embedding_change
        if change is None:
            return read_id
        if time.monotonic() >= change["deadline"]:
            self._embedding_change = None
            return read_id
        if read_id is None or read_id == change["previous"]:
            change["candidate"] = None
            return None
        if read_id != change["candidate"]:
            change["candidate"] = read_id
            return None
        self._embedding_change = None
        return read_id

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

    # ---------------------------------------------------------------- forward

    @staticmethod
    def lease_backend_info(lease: Lease) -> dict:
        """Helper for handlers building response headers and SSE fingerprints."""
        slot = lease.slot
        return {
            "backend": slot.backend_type,
            "backend_url": slot.meta.get("url"),
        }

    async def forward(
        self,
        lease: Lease,
        method: str,
        endpoint: str,
        data: dict,
    ) -> httpx.Response:
        """Non-streaming forward. Lease lifecycle is owned by the caller —
        we never release here. The caller's `async with lease:` block does that.
        """
        slot = lease.slot
        url = slot.meta.get("url")
        return await self.http_client.request(
            method,
            f"{url}{endpoint}",
            json=data,
            timeout=config.BACKEND_HTTP_TIMEOUT_SECONDS,
        )

    async def open_stream(self, lease: Lease, endpoint: str, data: dict) -> BackendStream:
        """Connect to the backend for a streaming request and check its answer.

        Handlers call this before starting their response, so a backend's error can
        still become that response's status. Raises BackendStatusError for anything
        but a 200, and httpx errors if the backend can't be reached. Same ownership
        contract as `forward`: the caller releases the lease.
        """
        slot = lease.slot
        request = self.http_client.build_request(
            "POST",
            f"{slot.meta.get('url')}{endpoint}",
            json=data,
            timeout=config.BACKEND_HTTP_TIMEOUT_SECONDS,
        )
        response = await self.http_client.send(request, stream=True)
        if response.status_code != 200:
            try:
                body = await response.aread()
            finally:
                await response.aclose()
            raise BackendStatusError(response.status_code, body.decode("utf-8", errors="replace"))
        return BackendStream(response, slot.backend_type)

    async def stream(
        self,
        lease: Lease,
        endpoint: str,
        data: dict,
    ) -> AsyncGenerator[bytes, None]:
        """Streaming forward as a generator, for forward_request. Raises what
        open_stream raises at the first iteration."""
        upstream = await self.open_stream(lease, endpoint, data)
        try:
            async for chunk in upstream:
                yield chunk
        finally:
            await upstream.aclose()

    # ----------------------------------------------------------- legacy shim
    #
    # `forward_request` was the old combined route+acquire+forward+release.
    # External callers may still reference it; we keep it working by mapping
    # to the new acquire_slot + forward + Lease pattern. New code should
    # prefer the explicit lease lifecycle.

    async def forward_request(
        self,
        method: str,
        endpoint: str,
        model: str,
        data: dict,
        stream: bool = False,
        backend_override: Optional[tuple[str, str]] = None,
        pre_acquired_backend: Optional[dict] = None,
    ) -> tuple:
        """Legacy entry point preserved for any external caller.

        IMPORTANT: this acquires a Lease internally and is responsible for
        releasing it. For non-streaming responses we release before returning;
        for streaming we attach a finally to the returned generator. The
        `pre_acquired_backend` and `backend_override` parameters are accepted
        for signature compatibility but ignored — the new acquire_slot path
        re-derives the right backend from the model."""
        lease = await self.acquire_slot(model)
        backend_info = self.lease_backend_info(lease)

        if not stream:
            try:
                response = await self.forward(lease, method, endpoint, data)
                return response, backend_info
            finally:
                await lease.release()

        async def _gen():
            try:
                async for chunk in self.stream(lease, endpoint, data):
                    yield chunk
            finally:
                await lease.release()

        return _gen(), backend_info


backend_manager = BackendManager()

# =============================================================================
# Authentication
# =============================================================================

# HTTPBearer security scheme for proper OpenAPI/Swagger integration
security = HTTPBearer()

async def get_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    """Authenticate the bearer token and return its key id, never the raw key.

    Auth path: Redis cache first (fast) → Postgres fallback (authoritative).
    On a Redis cache miss the key is written back so subsequent requests are fast.
    This means auth survives a Postgres pod restart (Redis serves the cached copy)
    and also survives a Redis pod restart (Postgres re-warms the cache on next hit).

    Fails closed: only a key found in one of the stores is authorized. A key in
    neither gets a 401 if Postgres answered, and otherwise the postgres_client
    calls raise StoreUnavailable, which is a 503.
    """
    raw_key = credentials.credentials
    key_id = hash_api_key(raw_key)

    # 1. Try Redis cache first
    key_config = await redis_client.get_api_key_config(key_id)
    if key_config:
        return key_id

    # 2. Cache miss - check Postgres (authoritative source), including a plaintext
    # row inserted since the last migration (see _migrate_plaintext_rows).
    key_config = (
        await postgres_client.get_api_key_config(key_id)
        or await postgres_client.migrate_plaintext_key(raw_key)
    )
    if not key_config:
        raise HTTPException(status_code=401, detail="Invalid API key")

    # 3. Write back to Redis cache for future requests
    await redis_client.set_api_key_config(key_id, key_config)
    return key_id



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

    It also removes revoked keys from the cache, including keys revoked while
    Redis or the revoking CLI could not reach each other.
    """
    await postgres_client.migrate_plaintext_keys()
    try:
        keys = await postgres_client.list_api_keys()
    except Exception as e:
        logger.error(f"warm_redis_from_postgres: Postgres query failed: {e}")
        return

    if not keys:
        logger.warning("warm_redis_from_postgres: no keys found in Postgres")

    success_count = 0
    for k in keys:
        try:
            config_data = {
                "key_prefix": k["key_prefix"],
                "name": k["name"],
                "scopes": k["scopes"],
                "requests_per_minute": k["requests_per_minute"],
                "tokens_per_day": k["tokens_per_day"],
                "tokens_per_minute": k["tokens_per_minute"],
                "created_at": k["created_at"],
            }
            await redis_client.set_api_key_config(k["key_id"], config_data)
            success_count += 1
        except Exception as e:
            # Redis failures are expected when Redis is down; fail-open behavior
            logger.debug(f"warm_redis_from_postgres: Redis unavailable for key {k.get('name', 'unknown')}: {e}")

    if success_count > 0:
        logger.info(f"warm_redis_from_postgres: cached {success_count}/{len(keys)} key(s) in Redis")
    elif keys:
        logger.warning(f"warm_redis_from_postgres: Redis unavailable, could not cache {len(keys)} key(s)")

    await _evict_stale_cached_keys()


async def _evict_stale_cached_keys() -> None:
    """Drop cached keys that Postgres says are revoked or no longer exist.

    Runs after the warm writes and reads Postgres afresh, so a key revoked while
    the warm loop was writing is removed in this same pass. If Postgres is down
    nothing is evicted, and an empty key table (a restored or replaced database)
    only evicts revoked keys, so an outage can't lock everyone out.
    """
    try:
        states = await postgres_client.get_key_revocation_states()
    except Exception as e:
        logger.warning(f"Skipping revoked key eviction, Postgres unavailable: {type(e).__name__}")
        return

    cached = await redis_client.list_cached_key_ids()
    if cached is None:
        return
    have_active_keys = any(not revoked for revoked in states.values())
    evicted = 0
    for key_id in cached:
        if states.get(key_id, have_active_keys):
            await redis_client.delete_api_key_config(key_id)
            evicted += 1
    if evicted:
        logger.info(f"Removed {evicted} revoked or unknown key(s) from the Redis cache")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup — Redis first (fast path for auth cache)
    await redis_client.connect()
    await redis_client.migrate_legacy_keys(delete_plaintext=False)
    await backend_manager.start()

    # Postgres — don't crash the gateway if Postgres is unavailable at startup.
    # All Postgres calls already use _execute_with_retry which reconnects on demand,
    # so the gateway starts in degraded mode and self-heals once Postgres recovers.
    try:
        await postgres_client.connect()
        await warm_redis_from_postgres()
    except Exception as e:
        logger.error(
            f"Postgres unavailable at startup ({e}). "
            "Starting in degraded mode — usage tracking will retry automatically."
        )

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
            try:
                await redis_client.migrate_legacy_keys(delete_plaintext=True)
                await warm_redis_from_postgres()
            except Exception as e:
                logger.error(f"Postgres to Redis sync failed: {type(e).__name__}")

    # Periodic snapshot — refreshes per-backend Prometheus gauges and surfaces
    # any drift the reconciler hasn't observed yet. Note: the BackendManager
    # now spawns its OWN 5-second reconciler task in start(), so this loop is
    # no longer responsible for reaping leases — only for metric refresh.
    async def limiter_maintenance_loop():
        while True:
            try:
                await rate_limiter.snapshot()
                backend_manager.snapshot()
                backend_manager._sync_metrics()
            except Exception as e:
                logger.error(f"Limiter maintenance failed: {e}")
            await asyncio.sleep(30)

    health_task = asyncio.create_task(health_check_loop())
    sync_task = asyncio.create_task(postgres_redis_sync_loop())
    limiter_task = asyncio.create_task(limiter_maintenance_loop())

    yield

    # Shutdown
    health_task.cancel()
    sync_task.cancel()
    limiter_task.cancel()
    await postgres_client.close()
    await redis_client.close()
    await backend_manager.stop()


# The Swagger and ReDoc pages load scripts from a third-party CDN into the origin
# that holds the admin key, so they are off. /openapi.json stays available.
app = FastAPI(
    title="LLM API Gateway",
    description="OpenAI-compatible LLM API with rate limiting and load balancing",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
)


@app.exception_handler(StoreUnavailable)
async def store_unavailable_handler(request: Request, exc: StoreUnavailable) -> JSONResponse:
    return JSONResponse(
        {"detail": "The gateway's data store is temporarily unavailable. Try again shortly."},
        status_code=503,
        headers={"Retry-After": "5"},
    )


def _body_too_large_message(limit: int) -> str:
    return f"Request body exceeds the {limit} byte limit"


class BodySizeLimitMiddleware:
    """Reject request bodies over MAX_REQUEST_BODY_BYTES with a 413.

    A declared Content-Length is refused before any of the body is read. Bodies
    that lie about their length or arrive chunked are counted as they are read,
    so the limit also holds for handlers that read request.json() themselves.
    Pure ASGI, so streaming responses and is_disconnected() are unaffected.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        limit = config.MAX_REQUEST_BODY_BYTES
        declared = dict(scope["headers"]).get(b"content-length")
        if declared is not None:
            try:
                too_large = int(declared) > limit
            except ValueError:
                response = JSONResponse({"detail": "Invalid Content-Length"}, status_code=400)
                await response(scope, receive, send)
                return
            if too_large:
                response = JSONResponse({"detail": _body_too_large_message(limit)}, status_code=413)
                await response(scope, receive, send)
                return

        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > limit:
                    raise HTTPException(status_code=413, detail=_body_too_large_message(limit))
            return message

        await self.app(scope, limited_receive, send)


# Applied to every response. API responses get the locked-down CSP below; the
# admin pages set their own in _admin_page().
SECURITY_HEADERS = {
    b"x-content-type-options": b"nosniff",
    b"x-frame-options": b"DENY",
    b"referrer-policy": b"no-referrer",
    b"strict-transport-security": b"max-age=31536000",
    b"content-security-policy": b"default-src 'none'; base-uri 'none'; frame-ancestors 'none'",
}


class SecurityHeadersMiddleware:
    """Add SECURITY_HEADERS, keeping any value the response set itself."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                present = {name.lower() for name, _ in headers}
                headers.extend(
                    (name, value) for name, value in SECURITY_HEADERS.items() if name not in present
                )
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, send_with_headers)


# Last added runs first: headers wrap everything, including a 413.
app.add_middleware(BodySizeLimitMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_middleware(SecurityHeadersMiddleware)

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
    limiter_snapshot = await rate_limiter.snapshot()
    backend_snapshot = backend_manager.snapshot()
    return {
        "backends": backend_manager.backend_health,
        "inflight": backend_snapshot["inflight"],
        "backend_inflight": backend_snapshot,
        "rate_limiter": limiter_snapshot,
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


async def _load_key_config(api_key: str) -> dict:
    """Resolve key_config via Redis-first / Postgres-fallback with safe defaults."""
    return (
        await redis_client.get_api_key_config(api_key)
        or await postgres_client.get_api_key_config(api_key)
        or {
            "requests_per_minute": config.DEFAULT_REQUESTS_PER_MINUTE,
            "tokens_per_day": config.DEFAULT_TOKENS_PER_DAY,
            "tokens_per_minute": config.DEFAULT_TOKENS_PER_MINUTE,
        }
    )


async def _parse_json_body(http_request: Request, model_cls: type[BaseModel]) -> BaseModel:
    """Read and validate the body of an inference request.

    Handlers call this after authenticating. Declaring the pydantic model as a
    handler parameter would make FastAPI read the whole body before running any
    dependency, including auth. Errors keep FastAPI's usual 422 shape.
    """
    body = await http_request.body()
    try:
        payload = json.loads(body)
    except (ValueError, RecursionError):
        raise RequestValidationError(
            [{"type": "json_invalid", "loc": ("body",), "msg": "JSON decode error", "input": None}]
        )
    try:
        return model_cls.model_validate(payload)
    except ValidationError as e:
        raise RequestValidationError(
            [{**error, "loc": ("body", *error["loc"])} for error in e.errors(include_url=False)]
        )


def _openapi_json_body(model_cls: type[BaseModel]) -> dict:
    """Keep a handler's request schema in /openapi.json now that it parses its own body."""
    schema = model_cls.model_json_schema()
    definitions = schema.pop("$defs", {})

    def inline(node):
        if isinstance(node, dict):
            ref = node.get("$ref", "")
            if ref.startswith("#/$defs/"):
                return inline(definitions[ref.removeprefix("#/$defs/")])
            return {key: inline(value) for key, value in node.items()}
        if isinstance(node, list):
            return [inline(item) for item in node]
        return node

    return {
        "requestBody": {
            "required": True,
            "content": {"application/json": {"schema": inline(schema)}},
        }
    }


async def _resolve_inference_model(requested_model: str) -> str:
    """Resolve a client-supplied model name, loading a cached model if needed.

    Unknown names get a 404 here, so only real model names reach the labels of
    the Prometheus metrics.
    """
    model_info = model_registry.get_model(requested_model)
    if not model_info:
        available = [m["id"] for m in model_registry.get_available_models()]
        raise HTTPException(
            status_code=404,
            detail={
                "error": f"Model '{requested_model}' is not currently loaded or cached",
                "available_models": available,
                "hint": "Call GET /v1/models to see available models, or POST /admin/models/download to download new ones",
            },
        )
    if model_info.get("lazy_load") and model_info.get("status") == "cached":
        logger.info(f"Lazy-loading cached model: {requested_model}")
        success = await backend_manager.load_ollama_model(requested_model)
        if not success:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": f"Failed to load model '{requested_model}'",
                    "hint": "The model may be too large or Ollama may be unavailable",
                },
            )
        model_info = model_registry.get_model(requested_model)
    return model_info.get("name", requested_model)


async def _relay_stream(
    http_request: Request,
    leases: RequestLeases,
    upstream: BackendStream,
    *,
    api_key: str,
    model: str,
    bucket: str,
    input_tokens: int,
    output_marker: bytes,
) -> AsyncGenerator[bytes, None]:
    """Relay a backend stream to the client. Owns the leases after detach().

    Usage is charged for whatever was sent, including when the client leaves
    early, so disconnecting can't dodge the daily quota. On disconnect the task
    group running this generator is usually already cancelled, so the cleanup
    runs in a shielded scope; otherwise its awaits would raise immediately.
    """
    leases.rebind_to_current_task()
    chunks_relayed = 0
    output_tokens = 0
    try:
        async for chunk in upstream:
            # Client gone: stop reading so the backend stops generating.
            if await http_request.is_disconnected():
                logger.warning("Client disconnected during streaming, releasing lease early")
                break
            yield chunk
            chunks_relayed += 1
            output_tokens += chunk.count(output_marker)
    finally:
        with anyio.CancelScope(shield=True):
            try:
                await upstream.aclose()
            except Exception as e:
                logger.warning(f"Closing backend stream failed: {type(e).__name__}")
            finally:
                await leases.release()
            if chunks_relayed:
                await postgres_client.add_token_usage(api_key, input_tokens, output_tokens)
                await redis_client.add_tpm_usage(api_key, output_tokens, bucket=bucket)
                TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
                TOKENS_COUNT.labels(model=model, direction="output").inc(output_tokens)


class LeaseStreamingResponse(StreamingResponse):
    """Streams a _relay_stream and makes sure its leases and backend connection can't
    outlive the response.

    While a client isn't reading, send() blocks once uvicorn's write buffer is
    full, and the generator stays suspended at its yield: it can't notice, its
    Task is alive so the reconciler leaves its leases alone, and no disconnect
    arrives as the connection is still open. So the limit is applied here, around
    send(). Ending the stream closes the connection without the final chunk, so
    the client can tell the response was cut short.
    """

    def __init__(self, content, *, leases: RequestLeases, upstream: BackendStream, **kwargs):
        super().__init__(content, **kwargs)
        self._leases = leases
        self._upstream = upstream

    async def __call__(self, scope, receive, send) -> None:
        stall_limit = config.STREAM_CLIENT_STALL_TIMEOUT_SECONDS
        max_duration = config.STREAM_MAX_DURATION_SECONDS
        stalled = False

        try:
            deadline = anyio.current_time() + max_duration if max_duration > 0 else math.inf
            with anyio.CancelScope(deadline=deadline) as stream_scope:
                async def guarded_send(message):
                    nonlocal stalled
                    with anyio.move_on_after(stall_limit if stall_limit > 0 else None) as send_scope:
                        await send(message)
                    if send_scope.cancelled_caught:
                        stalled = True
                        stream_scope.cancel()
                        await anyio.lowlevel.checkpoint()

                await super().__call__(scope, receive, guarded_send)

            if stalled:
                logger.warning(f"Ending stream: client read nothing for {stall_limit:g}s")
            elif stream_scope.cancelled_caught:
                logger.warning(f"Ending stream: reached the {max_duration:g}s limit")
        finally:
            # Starlette leaves a generator suspended at its yield when send() fails
            # or is cancelled, and then its cleanup would wait for garbage collection.
            # A generator that never started has no cleanup to run, hence the closing
            # and the release here.
            with anyio.CancelScope(shield=True):
                try:
                    await self.body_iterator.aclose()
                finally:
                    try:
                        await self._upstream.aclose()
                    finally:
                        await self._leases.release()


def _estimate_message_tokens(messages) -> int:
    """Cheap word-count×1.3 estimate. Tolerant of None content (tool calls)."""
    total = 0.0
    for m in messages:
        content = getattr(m, "content", None)
        if content:
            total += len(content.split()) * 1.3
    return int(total)


async def _open_backend_stream(
    leases: RequestLeases, path: str, data: dict, *, model: str, priority: str, endpoint: str,
) -> BackendStream:
    """Connect to the backend before the response starts. A backend error then reaches
    the client as a status, exactly as on the non-streaming path, and nothing is charged.

    The status line has to wait for the backend's, so a client that leaves meanwhile
    isn't noticed until then, also as on the non-streaming path.
    """
    try:
        return await backend_manager.open_stream(leases.backend, path, data)
    except BackendStatusError as e:
        REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint=endpoint).inc()
        raise HTTPException(status_code=e.status_code, detail=e.body)
    except httpx.HTTPError as e:
        REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint=endpoint).inc()
        logger.error(f"Backend error: {type(e).__name__}")
        raise HTTPException(status_code=503, detail="Backend service unavailable")


async def _enforce_daily_quota(api_key: str, key_config: dict, model: str, priority: str, endpoint: str) -> None:
    """Refuse a request over its daily quota. Handlers call this before taking any
    lease, so a slow Postgres can't keep slots busy."""
    if not await postgres_client.check_token_quota(api_key, key_config["tokens_per_day"]):
        REQUEST_COUNT.labels(model=model, priority=priority, status="quota_exceeded", endpoint=endpoint).inc()
        raise HTTPException(status_code=429, detail="Daily token quota exceeded")


@app.post("/v1/chat/completions", openapi_extra=_openapi_json_body(ChatCompletionRequest))
async def chat_completions(
    http_request: Request,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible chat completions endpoint - requires 'inference' scope.

    Concurrency contract:
      * ``acquire_request_leases`` returns a ``RequestLeases`` whose ``__aexit__``
        releases both the backend slot and the per-key slot.
      * For streaming responses, ``leases.detach()`` hands ownership to the
        generator's ``finally`` block.
      * There is no manual flag to keep in sync — the type system enforces
        the contract.
    """
    await require_scope("inference", api_key)
    request = await _parse_json_body(http_request, ChatCompletionRequest)
    start_time = time.time()

    model = await _resolve_inference_model(request.model)
    key_config = await _load_key_config(api_key)
    estimated_prompt_tokens = _estimate_message_tokens(request.messages)

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

    await _enforce_daily_quota(api_key, key_config, model, priority, "chat")

    async with await acquire_request_leases(
        model=model,
        api_key=api_key,
        key_config=key_config,
        endpoint="chat",
        priority=priority,
        estimated_prompt_tokens=estimated_prompt_tokens,
    ) as leases:
        if request.stream:
            backend_info = leases.backend_info
            upstream = await _open_backend_stream(
                leases, "/v1/chat/completions", data, model=model, priority=priority, endpoint="chat",
            )
            # Ownership transfers to the generator — its finally is now the
            # single release point.
            leases.detach()

            input_tokens = sum(
                len(m.content.split()) for m in request.messages if m.content
            ) * 2
            REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="chat").inc()
            return LeaseStreamingResponse(
                _relay_stream(
                    http_request, leases, upstream,
                    api_key=api_key, model=model, bucket=leases.bucket,
                    input_tokens=input_tokens, output_marker=b'"content":',
                ),
                leases=leases,
                upstream=upstream,
                media_type="text/event-stream",
                headers={
                    "X-Priority": priority,
                    "X-Backend": backend_info.get("backend", "unknown"),
                },
            )

        # Non-streaming path — RequestLeases.__aexit__ releases on every exit.
        try:
            response = await backend_manager.forward(
                leases.backend, "POST", "/v1/chat/completions", data,
            )
        except httpx.HTTPError as e:
            REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="chat").inc()
            logger.error(f"Backend error: {e}")
            raise HTTPException(status_code=503, detail="Backend service unavailable")

        if response.status_code != 200:
            REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="chat").inc()
            raise HTTPException(status_code=response.status_code, detail=response.text)

        result = response.json()
        result["system_fingerprint"] = leases.bucket

        usage = result.get("usage", {})
        input_tokens = usage.get("prompt_tokens", 0)
        output_tokens = usage.get("completion_tokens", 0)
        # The backend is done, so free its slots before waiting on the stores.
        await leases.release()
        await postgres_client.add_token_usage(api_key, input_tokens, output_tokens)
        await redis_client.add_tpm_usage(api_key, output_tokens, bucket=leases.bucket)
        TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
        TOKENS_COUNT.labels(model=model, direction="output").inc(output_tokens)

        duration = time.time() - start_time
        REQUEST_DURATION.labels(model=model, priority=priority, endpoint="chat").observe(duration)
        REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="chat").inc()
        return result


@app.post("/v1/completions", openapi_extra=_openapi_json_body(CompletionRequest))
async def completions(
    http_request: Request,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible completions endpoint - requires 'inference' scope."""
    await require_scope("inference", api_key)
    request = await _parse_json_body(http_request, CompletionRequest)
    start_time = time.time()
    model = await _resolve_inference_model(request.model)
    key_config = await _load_key_config(api_key)
    estimated_prompt_tokens = int(len(request.prompt.split()) * 1.3)

    data = {
        "model": model,
        "prompt": request.prompt,
        "temperature": request.temperature,
        "max_tokens": request.max_tokens,
        "stream": request.stream,
    }

    await _enforce_daily_quota(api_key, key_config, model, priority, "completions")

    async with await acquire_request_leases(
        model=model,
        api_key=api_key,
        key_config=key_config,
        endpoint="completions",
        priority=priority,
        estimated_prompt_tokens=estimated_prompt_tokens,
    ) as leases:
        if request.stream:
            backend_info = leases.backend_info
            upstream = await _open_backend_stream(
                leases, "/v1/completions", data, model=model, priority=priority, endpoint="completions",
            )
            leases.detach()

            REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="completions").inc()
            return LeaseStreamingResponse(
                _relay_stream(
                    http_request, leases, upstream,
                    api_key=api_key, model=model, bucket=leases.bucket,
                    input_tokens=len(request.prompt.split()) * 2, output_marker=b'"text":',
                ),
                leases=leases,
                upstream=upstream,
                media_type="text/event-stream",
                headers={"X-Backend": backend_info.get("backend", "unknown")},
            )

        try:
            response = await backend_manager.forward(
                leases.backend, "POST", "/v1/completions", data,
            )
        except httpx.HTTPError:
            REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="completions").inc()
            raise HTTPException(status_code=503, detail="Backend service unavailable")

        if response.status_code != 200:
            REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="completions").inc()
            raise HTTPException(status_code=response.status_code, detail=response.text)

        result = response.json()
        result["system_fingerprint"] = leases.bucket

        usage = result.get("usage", {})
        input_tokens = usage.get("prompt_tokens", 0)
        output_tokens = usage.get("completion_tokens", 0)
        # The backend is done, so free its slots before waiting on the stores.
        await leases.release()
        await postgres_client.add_token_usage(api_key, input_tokens, output_tokens)
        await redis_client.add_tpm_usage(api_key, output_tokens, bucket=leases.bucket)
        TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
        TOKENS_COUNT.labels(model=model, direction="output").inc(output_tokens)

        duration = time.time() - start_time
        REQUEST_DURATION.labels(model=model, priority=priority, endpoint="completions").observe(duration)
        REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="completions").inc()
        return result


def _current_embedding_model_id(model: str) -> Optional[str]:
    return ((model_registry.get_model(model) or {}).get("info") or {}).get("backend_model_id")


def _embedding_cache_key(backend_model_id: str, text: str) -> str:
    """Cache key for one input. It uses what the backend reports it is serving, not
    the gateway's model name, which stays the same when the model behind it changes."""
    return hashlib.sha256(f"{backend_model_id}\0{text}".encode()).hexdigest()


@app.post("/v1/embeddings", openapi_extra=_openapi_json_body(EmbeddingRequest))
async def embeddings(
    http_request: Request,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible embeddings endpoint - requires 'inference' scope.

    Embeddings live in their own bucket, so concurrency cannot consume vLLM
    slots. We acquire the per-key (embedding) slot first; the backend slot
    is only acquired if there are cache misses that need a real forward."""
    await require_scope("inference", api_key)
    request = await _parse_json_body(http_request, EmbeddingRequest)
    start_time = time.time()

    model_info = model_registry.get_model(request.model)
    if not model_info:
        available = [m["id"] for m in model_registry.get_available_models() if m.get("backend") == "embedding"]
        raise HTTPException(
            status_code=404,
            detail={
                "error": f"Embedding model '{request.model}' is not currently loaded",
                "available_models": available,
                "hint": "Call GET /v1/models first to see available models",
            },
        )
    if model_info.get("backend") != "embedding":
        available = [m["id"] for m in model_registry.get_available_models() if m.get("backend") == "embedding"]
        raise HTTPException(
            status_code=400,
            detail={
                "error": f"Model '{request.model}' is not an embedding model",
                "available_embedding_models": available,
            },
        )

    model = model_info.get("name", request.model)
    bucket = "embedding"
    key_config = await _load_key_config(api_key)

    input_list = request.input if isinstance(request.input, list) else [request.input]
    estimated_prompt_tokens = int(sum(len(t.split()) * 1.3 for t in input_list))

    await _enforce_daily_quota(api_key, key_config, model, priority, "embeddings")

    # None if the backend hasn't said what it is running. Skip the cache then,
    # since a vector from a previous model would be silently wrong.
    backend_model_id = _current_embedding_model_id(model)

    async with await rate_limiter.acquire_key_slot(
        api_key, key_config, bucket, "embeddings", model, priority, estimated_prompt_tokens,
    ) as key_lease:
        cache_hits = []
        cache_misses = []
        for i, text in enumerate(input_list):
            cached = None
            if backend_model_id:
                cached = await redis_client.get_cached_response(_embedding_cache_key(backend_model_id, text))
            if cached:
                cache_hits.append((i, json.loads(cached)))
            else:
                cache_misses.append((i, text))

        if cache_misses:
            data = {"model": model, "input": [text for _, text in cache_misses]}
            async with await backend_manager.acquire_slot(model) as backend_lease:
                try:
                    response = await backend_manager.forward(backend_lease, "POST", "/v1/embeddings", data)
                except httpx.HTTPError:
                    REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="embeddings").inc()
                    raise HTTPException(status_code=503, detail="Backend service unavailable")

                if response.status_code != 200:
                    REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="embeddings").inc()
                    raise HTTPException(status_code=response.status_code, detail=response.text)

                result = response.json()
                backend_items = result.get("data", [])
                if len(backend_items) != len(cache_misses):
                    # Pairing these with the inputs would attach vectors to the wrong text.
                    REQUEST_COUNT.labels(model=model, priority=priority, status="error", endpoint="embeddings").inc()
                    raise HTTPException(status_code=502, detail="Embedding backend returned the wrong number of results")
                # An admin may have changed the model while this was at the backend.
                still_current = _current_embedding_model_id(model) == backend_model_id
                for (orig_idx, text), emb_data in zip(cache_misses, backend_items):
                    if backend_model_id and still_current:
                        await redis_client.cache_response(
                            _embedding_cache_key(backend_model_id, text), json.dumps(emb_data), ttl=86400,
                        )
                    cache_hits.append((orig_idx, emb_data))

        cache_hits.sort(key=lambda x: x[0])
        # A cached item holds its position in the request that first computed it,
        # and a backend's holds its position among this request's cache misses.
        embeddings_data = [{**emb, "index": position} for position, emb in cache_hits]

        total_tokens = sum(len(text.split()) * 2 for text in input_list)
        await key_lease.release()
        await postgres_client.add_token_usage(api_key, total_tokens, 0)
        await redis_client.add_tpm_usage(api_key, total_tokens, bucket=bucket)
        TOKENS_COUNT.labels(model=model, direction="input").inc(total_tokens)

        duration = time.time() - start_time
        REQUEST_DURATION.labels(model=model, priority=priority, endpoint="embeddings").observe(duration)
        REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="embeddings").inc()

        return {
            "object": "list",
            "data": embeddings_data,
            "model": model,
            "usage": {"prompt_tokens": total_tokens, "total_tokens": total_tokens},
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
    bucket_rpms = {}
    for bucket in rate_limiter.SERVICE_BUCKETS:
        bucket_rpms[bucket], _ = await redis_client.get_rate_limit_info(api_key, bucket=bucket)
    current_rpm = sum(bucket_rpms.values())

    # Calculate reset time
    tomorrow = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)

    return UsageResponse(
        tokens_used_today=input_tokens + output_tokens,
        tokens_limit_daily=key_config["tokens_per_day"],
        requests_used_minute=current_rpm,
        requests_limit_minute=sum(
            rate_limiter._rpm_limit(key_config, bucket)
            for bucket in rate_limiter.SERVICE_BUCKETS
        ),
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
    <link rel="stylesheet" href="/admin/assets/admin.css">
    <script src="/admin/assets/icons.js"></script>
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

            <form id="login-form" class="space-y-4">
                <div>
                    <label for="api-key" class="block text-sm font-medium text-gray-300 mb-2">
                        Admin API Key
                    </label>
                    <input
                        type="password"
                        id="api-key"
                        name="llmapi-admin-api-key"
                        autocomplete="off"
                        autocapitalize="off"
                        autocorrect="off"
                        spellcheck="false"
                        data-1p-ignore="true"
                        data-lpignore="true"
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
            </div>
        </div>

        <p class="text-center text-gray-500 text-xs mt-6">
            Your API key is stored locally in your browser and never transmitted to any third party.
        </p>
    </div>

    <script>
        lucide.createIcons();

        document.getElementById('login-form').addEventListener('submit', handleLogin);

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
    <link rel="stylesheet" href="/admin/assets/admin.css">
    <script src="/admin/assets/icons.js"></script>
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
            <button data-action="logout" class="bg-gray-700 hover:bg-gray-600 text-gray-300 px-4 py-2 rounded-lg flex items-center gap-2 transition">
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
                    <input type="text" id="model-name" placeholder="Model name (e.g., qwen3:14b, llama3.2:3b, mistral)"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500 col-span-2">
                    <button data-action="downloadModel"
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
                    Popular: <code class="bg-gray-600 px-1 rounded">qwen3:14b</code>
                    <code class="bg-gray-600 px-1 rounded">llama3.2:3b</code>
                    <code class="bg-gray-600 px-1 rounded">mistral</code>
                    <code class="bg-gray-600 px-1 rounded">gemma3:4b</code>
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
                    <input type="text" id="vllm-model" placeholder="HuggingFace model (e.g., Qwen/Qwen3-14B-AWQ)"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-green-500 col-span-2">
                    <button data-action="changeVllmModel"
                            class="bg-green-700 hover:bg-green-600 rounded px-4 py-2 text-sm font-medium transition flex items-center justify-center gap-2">
                        <i data-lucide="refresh-cw" class="w-4 h-4"></i>
                        Change Model
                    </button>
                </div>
                <p id="vllm-current" class="text-xs text-gray-500 mt-2">Current: Loading...</p>
                <p class="text-xs text-gray-500 mt-1">
                    Recommended for 24GB VRAM:
                    <code class="bg-gray-600 px-1 rounded">Qwen/Qwen3-14B-AWQ</code>
                    <code class="bg-gray-600 px-1 rounded">meta-llama/Llama-3.2-3B-Instruct</code>
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
                        <button data-action="toggleLlamacpp" id="llamacpp-toggle"
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
                    <button data-action="changeLlamacppModel"
                            class="bg-blue-700 hover:bg-blue-600 rounded px-4 py-2 text-sm font-medium transition flex items-center justify-center gap-2">
                        <i data-lucide="refresh-cw" class="w-4 h-4"></i>
                        Change Model
                    </button>
                </div>
                <p id="llamacpp-current" class="text-xs text-gray-500 mt-2">Current: Loading...</p>
                <p class="text-xs text-gray-500 mt-1">
                    Recommended for 256GB RAM:
                    <code class="bg-gray-600 px-1 rounded text-xs">Llama-3.3-70B-Q4_K_M.gguf</code>
                    <code class="bg-gray-600 px-1 rounded text-xs">Qwen3-14B-Q4_K_M.gguf</code>
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
                    <button data-action="changeEmbeddingModel"
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
                    Required for gated models such as Llama. Token is stored securely.
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="password" id="hf-token" name="llmapi-hf-token" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" data-1p-ignore="true" data-lpignore="true" placeholder="hf_xxxxx..."
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-500 col-span-2">
                    <button data-action="setHfToken"
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
                                <input type="number" id="vllm-ctx" value="32768"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">Qwen3 native max</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">GPU Memory %</label>
                                <input type="number" id="vllm-gpu-mem" value="90" min="50" max="99" step="5"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">90=safe, 95=aggressive</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Max Sequences</label>
                                <input type="number" id="vllm-batch" value="1"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">1 for 32K on 3090</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Quantization</label>
                                <select id="vllm-quant" class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                    <option value="awq">AWQ</option>
                                    <option value="gptq">GPTQ</option>
                                    <option value="none">None (FP16)</option>
                                </select>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Batched Tokens</label>
                                <input type="number" id="vllm-batched-tokens" value="32768"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                <p class="text-xs text-gray-500 mt-1">Prefill token cap</p>
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">Reasoning</label>
                                <select id="vllm-reasoning" class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                                    <option value="true">Enabled</option>
                                    <option value="false">Disabled</option>
                                </select>
                                <p class="text-xs text-gray-500 mt-1">Qwen3 parser</p>
                            </div>
                        </div>
                        <button data-action="updateVllmConfig"
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
                        <button data-action="updateLlamacppConfig"
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
                                <input type="number" id="embedding-batch" value="8192"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                            <div>
                                <label class="text-xs text-gray-400">CPU Threads</label>
                                <input type="number" id="embedding-threads" value="4"
                                       class="w-full bg-gray-600 rounded px-2 py-1 text-sm">
                            </div>
                        </div>
                        <button data-action="updateEmbeddingConfig"
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
                    <button data-action="refreshGpuStatus" class="text-xs text-cyan-400 hover:text-cyan-300 flex items-center gap-1">
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
                        <button data-action="scaleVllm" data-arg="0" class="px-4 py-2 rounded text-sm font-medium transition bg-gray-600 hover:bg-gray-500">
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
                        <button data-action="toggleLlamacppNew" id="llamacpp-toggle-btn"
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
                    <button data-action="quickAction" data-arg="max-gpu"
                            class="bg-green-700 hover:bg-green-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="zap" class="w-4 h-4"></i>
                        Max GPU Mode (Use All GPUs)
                    </button>
                    <button data-action="quickAction" data-arg="save-ram"
                            class="bg-blue-700 hover:bg-blue-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="save" class="w-4 h-4"></i>
                        Save RAM (Stop llamacpp)
                    </button>
                    <button data-action="quickAction" data-arg="balanced"
                            class="bg-purple-700 hover:bg-purple-600 rounded px-4 py-2 text-sm transition flex items-center justify-center gap-2">
                        <i data-lucide="scale" class="w-4 h-4"></i>
                        Balanced Mode (1 GPU + CPU)
                    </button>
                    <button data-action="quickAction" data-arg="stop-all"
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
            </div>

            <!-- Create Key Form -->
            <div class="bg-gray-700 rounded-lg p-4 mb-4">
                <h3 class="font-medium mb-3">Create New Key</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mb-3">
                    <input type="text" id="key-name" placeholder="Key name"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500">
                    <input type="number" id="key-tokens" placeholder="Tokens/day" value="100000"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500">
                    <input type="number" id="key-rpm" placeholder="Requests/min (RPM)" value="60"
                           class="bg-gray-600 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-purple-500">
                    <input type="number" id="key-tpm" placeholder="Tokens/min (TPM) - optional (auto: 40k, admin: 200k)"
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
                <button data-action="createKey"
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

            <div class="flex flex-col md:flex-row md:items-end md:justify-between gap-4 mb-6">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <div>
                        <label class="text-sm text-gray-400 block mb-2">Rolling Window</label>
                        <select id="stats-window-hours" class="bg-gray-700 border border-gray-600 rounded px-3 py-2 text-sm">
                            <option value="24">Last 24 hours</option>
                            <option value="96" selected>Last 96 hours</option>
                            <option value="168">Last 168 hours</option>
                        </select>
                    </div>
                    <div>
                        <label class="text-sm text-gray-400 block mb-2">Chart Filter</label>
                        <select id="stats-key-filter" class="bg-gray-700 border border-gray-600 rounded px-3 py-2 text-sm">
                            <option value="">All API keys</option>
                        </select>
                    </div>
                </div>
                <div class="text-xs text-gray-500" id="stats-timezone">
                    Loading timezone info...
                </div>
            </div>

            <!-- Summary Cards -->
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
                <div class="bg-gray-700 rounded-lg p-4">
                    <p class="text-sm text-gray-400">Requests in Window</p>
                    <p id="stats-total-requests" class="text-2xl font-bold text-green-400">-</p>
                </div>
                <div class="bg-gray-700 rounded-lg p-4">
                    <p class="text-sm text-gray-400">Tokens in Window</p>
                    <p id="stats-total-tokens" class="text-2xl font-bold text-purple-400">-</p>
                </div>
                <div class="bg-gray-700 rounded-lg p-4">
                    <p class="text-sm text-gray-400">Active API Keys</p>
                    <p id="stats-active-keys" class="text-2xl font-bold text-blue-400">-</p>
                </div>
            </div>

            <!-- Usage by API Key -->
            <div class="mb-6">
                <h3 class="font-medium mb-3">Usage by API Key (Selected Window)</h3>
                <div id="stats-by-key" class="space-y-2">
                    <p class="text-gray-400 text-sm">Loading...</p>
                </div>
            </div>

            <!-- Hourly Chart (simple bar representation) -->
            <div>
                <h3 id="stats-chart-title" class="font-medium mb-3">Requests (Rolling Window)</h3>
                <div id="stats-hourly" class="flex items-end gap-1 h-24 bg-gray-700 rounded-lg p-2">
                    <p class="text-gray-400 text-sm">Loading...</p>
                </div>
                <div class="flex justify-between text-xs text-gray-500 mt-1 px-2">
                    <span id="stats-range-start">Start</span>
                    <span id="stats-range-end">Now</span>
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

        let statsCache = null;

        // Everything placed in innerHTML below that a key creator, model name or
        // backend can influence goes through this, for text and attributes alike.
        function escapeHtml(value) {
            const entities = {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'};
            return String(value ?? '').replace(/[&<>"']/g, ch => entities[ch]);
        }

        function getLocalTimezone() {
            return Intl.DateTimeFormat().resolvedOptions().timeZone || 'local time';
        }

        function formatLocalHour(timestampUtc) {
            const date = new Date(timestampUtc);
            return date.toLocaleString([], {
                month: 'short',
                day: 'numeric',
                hour: 'numeric',
                hour12: true
            });
        }

        function updateStatsKeyFilter(keys) {
            const filterEl = document.getElementById('stats-key-filter');
            if (!filterEl) return;

            const currentValue = filterEl.value;
            const options = ['<option value="">All API keys</option>'].concat(
                (keys || []).map(k =>
                    `<option value="${escapeHtml(k.api_key)}">${escapeHtml(k.name)} (${escapeHtml(k.api_key_preview)})</option>`
                )
            );
            filterEl.innerHTML = options.join('');

            const stillExists = (keys || []).some(k => k.api_key === currentValue);
            filterEl.value = stillExists ? currentValue : '';
        }

        function renderHourlyChart() {
            const hourlyEl = document.getElementById('stats-hourly');
            const chartTitleEl = document.getElementById('stats-chart-title');
            const rangeStartEl = document.getElementById('stats-range-start');
            const rangeEndEl = document.getElementById('stats-range-end');
            const keyFilterEl = document.getElementById('stats-key-filter');

            if (!statsCache) {
                hourlyEl.innerHTML = '<div class="text-gray-400 text-center py-4">No data yet</div>';
                return;
            }

            const selectedKey = keyFilterEl?.value || '';
            const baseSeries = (statsCache.by_hour || []).map(item => ({
                timestamp_utc: item.timestamp_utc,
                hour_label_utc: item.hour_label_utc,
                tokens: item.tokens || 0,
                requests: item.requests || 0,
            }));

            let chartData = baseSeries;
            let selectedKeyMeta = null;

            if (selectedKey) {
                selectedKeyMeta = (statsCache.by_key || []).find(k => k.api_key === selectedKey) || null;
                const seriesMap = {};
                baseSeries.forEach(item => {
                    seriesMap[item.timestamp_utc] = {
                        timestamp_utc: item.timestamp_utc,
                        hour_label_utc: item.hour_label_utc,
                        tokens: 0,
                        requests: 0,
                    };
                });

                (statsCache.by_key_hour || [])
                    .filter(item => item.api_key === selectedKey)
                    .forEach(item => {
                        if (seriesMap[item.timestamp_utc]) {
                            seriesMap[item.timestamp_utc].tokens += item.tokens || 0;
                            seriesMap[item.timestamp_utc].requests += item.requests || 0;
                        }
                    });

                chartData = baseSeries.map(item => seriesMap[item.timestamp_utc]);
            }

            if (!chartData.length) {
                hourlyEl.innerHTML = '<div class="text-gray-400 text-center py-4">No data yet</div>';
                return;
            }

            const maxReq = Math.max(...chartData.map(h => h.requests || 0), 1);
            const localTz = getLocalTimezone();
            const titleSuffix = selectedKeyMeta ? `${selectedKeyMeta.name}` : 'All API keys';
            chartTitleEl.textContent = `Requests (${statsCache.window_hours}h rolling, ${titleSuffix})`;

            rangeStartEl.textContent = formatLocalHour(chartData[0].timestamp_utc);
            rangeEndEl.textContent = formatLocalHour(chartData[chartData.length - 1].timestamp_utc);

            hourlyEl.innerHTML = chartData.map(h => {
                const height = Math.max(4, ((h.requests || 0) / maxReq) * 100);
                const localHour = formatLocalHour(h.timestamp_utc);
                const title = `${localHour} (${localTz}) • ${h.requests || 0} requests • ${(h.tokens || 0).toLocaleString()} tokens`;
                return `<div class="flex-1 bg-green-500 rounded-t opacity-70 hover:opacity-100 transition cursor-pointer"
                             style="height: ${height}%"
                             title="${title}"></div>`;
            }).join('');
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
                                    <span class="text-blue-300 font-medium">Downloading: ${escapeHtml(ds.model)}</span>
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
                                        <span class="text-red-300 font-medium block">Download Failed: ${escapeHtml(ds.model)}</span>
                                        <p class="text-sm text-red-400 mt-1">${escapeHtml(ds.error)}</p>
                                        <p class="text-xs text-red-500 mt-2">Check the model name and the HuggingFace token. The vLLM pod keeps retrying until the download works.</p>
                                    </div>
                                </div>
                            </div>
                        `;
                    } else if (ds.status === 'unavailable') {
                        html += `
                            <div class="bg-gray-700 rounded p-3 mb-3">
                                <p class="text-sm text-gray-300">vLLM download status unavailable: the gateway could not read its pods.</p>
                            </div>
                        `;
                    }
                }

                // Show loaded models
                if (data.models && data.models.length > 0) {
                    html += data.models.map(m => `
                        <div class="flex items-center justify-between bg-gray-700 rounded p-3">
                            <div>
                                <span class="font-medium">${escapeHtml(m.id)}</span>
                                <span class="text-xs text-gray-400 ml-2">${escapeHtml(m.backend)}</span>
                                ${m.size ? `<span class="text-xs text-gray-500 ml-2">${formatSize(m.size)}</span>` : ''}
                            </div>
                            <div class="flex items-center gap-2">
                                <span class="text-xs px-2 py-1 rounded ${m.status === 'loaded' ? 'bg-green-900 text-green-300' : 'bg-yellow-900 text-yellow-300'}">
                                    ${escapeHtml(m.status)}
                                </span>
                                ${m.backend === 'ollama' ? `
                                    <button data-action="deleteModel" data-arg="${escapeHtml(m.id)}"
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
                <button data-action="scaleVllm" data-arg="0" id="vllm-btn-0"
                        class="px-4 py-2 rounded text-sm font-medium transition bg-gray-600 hover:bg-gray-500">
                    0 (Off)
                </button>
            `;

            // Buttons 1 to maxButtons
            for (let i = 1; i <= maxButtons; i++) {
                buttonsHtml += `
                    <button data-action="scaleVllm" data-arg="${i}" id="vllm-btn-${i}"
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
                    const error = await resp.json().catch(() => ({}));
                    alert(typeof error.detail === 'string' ? error.detail : 'Token NOT saved: HTTP ' + resp.status);
                }
            } catch (e) {
                alert('Failed to save token: ' + e.message);
            }
        }

        async function updateVllmConfig() {
            const ctx = document.getElementById('vllm-ctx').value;
            const gpuMem = document.getElementById('vllm-gpu-mem').value;
            const batch = document.getElementById('vllm-batch').value;
            const batchedTokens = document.getElementById('vllm-batched-tokens').value;
            const quant = document.getElementById('vllm-quant').value;
            const reasoning = document.getElementById('vllm-reasoning').value === 'true';

            const msg = `This will restart vLLM with:
• Context: ${ctx} tokens
• GPU Memory: ${gpuMem}%
• Max Sequences: ${batch}
• Batched Tokens: ${batchedTokens}
• Quantization: ${quant}
• Reasoning Parser: ${reasoning ? 'qwen3 enabled' : 'disabled'}

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
                        max_num_batched_tokens: parseInt(batchedTokens),
                        quantization: quant,
                        enable_reasoning: reasoning,
                        reasoning_parser: 'qwen3'
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
                                <div class="font-medium">${escapeHtml(k.name)}</div>
                                <code class="text-xs text-gray-400 break-all" title="${escapeHtml(k.key_id)}">${escapeHtml(k.key_prefix || k.key_id.slice(0, 16))}...</code>
                            </div>
                            <div class="flex items-center gap-4 text-sm text-gray-400">
                                <span>${k.requests_per_minute} RPM</span>
                                <span>${(k.tokens_per_minute || 200000).toLocaleString()} TPM</span>
                                <span>${k.tokens_per_day.toLocaleString()} tokens/day</span>
                                <button data-action="revokeKey" data-arg="${escapeHtml(k.key_id)}"
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
                const hours = parseInt(document.getElementById('stats-window-hours')?.value || '96', 10);
                const resp = await adminFetch(`${API_BASE}/admin/stats?hours=${hours}`);
                if (!resp) return; // Auth failure, already redirected
                if (!resp.ok) {
                    // Keep what's on screen. Zeros here would read as "no usage".
                    document.getElementById('stats-timezone').textContent =
                        `Usage statistics are unavailable right now (HTTP ${resp.status}). What's shown may be out of date.`;
                    return;
                }
                const data = await resp.json();
                statsCache = data;

                // Update stats cards with null checks
                document.getElementById('stats-total-requests').textContent = (data.summary?.total_requests_window || 0).toLocaleString();
                document.getElementById('stats-total-tokens').textContent = (data.summary?.total_tokens_window || 0).toLocaleString();
                document.getElementById('stats-active-keys').textContent = data.summary?.active_keys || 0;

                const timezoneEl = document.getElementById('stats-timezone');
                timezoneEl.textContent = `Rolling ${data.window_hours || hours}h window. Stored in ${data.timezone || 'UTC'}, displayed in ${getLocalTimezone()}. Generated ${new Date(data.generated_at).toLocaleString()}.`;

                // Update usage by API key
                const byKeyEl = document.getElementById('stats-by-key');
                if (data.by_key && data.by_key.length > 0) {
                    updateStatsKeyFilter(data.by_key);
                    byKeyEl.innerHTML = data.by_key.map(k => `
                        <div class="flex items-center justify-between bg-gray-700 rounded p-3">
                            <div class="flex-1">
                                <div class="font-medium text-sm">${escapeHtml(k.name)}</div>
                                <code class="text-xs text-gray-500">${escapeHtml(k.api_key_preview)}</code>
                            </div>
                            <div class="flex items-center gap-4 text-sm text-gray-400">
                                <span>${k.requests_window || 0} requests</span>
                                <span>${(k.tokens_window || 0).toLocaleString()} tokens</span>
                                <span>${k.rpm_limit || 0} RPM</span>
                                <span>${(k.tpm_limit || 0).toLocaleString()} TPM</span>
                            </div>
                        </div>
                    `).join('');
                } else {
                    updateStatsKeyFilter([]);
                    byKeyEl.innerHTML = '<p class="text-gray-400 text-sm">No usage data yet</p>';
                }

                renderHourlyChart();
            } catch (e) {
                console.error('Failed to load stats:', e);
            }
        }

        // API Key Management Functions
        async function createKey() {
            const name = document.getElementById('key-name').value.trim();
            const rpm = parseInt(document.getElementById('key-rpm').value) || 60;
            const tokens = parseInt(document.getElementById('key-tokens').value) || 100000;
            const rawTpm = document.getElementById('key-tpm').value.trim();

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
                const payload = {
                    name: name,
                    requests_per_minute: rpm,
                    tokens_per_day: tokens,
                    scopes: scopes
                };
                if (rawTpm !== '') {
                    payload.tokens_per_minute = parseInt(rawTpm);
                }

                const resp = await adminFetch(`${API_BASE}/admin/keys`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(payload)
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
                    document.getElementById('key-tpm').value = '';
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

        // The CSP forbids inline handlers, so clicks are routed from data-action.
        const CLICK_ACTIONS = {
            logout, downloadModel, changeVllmModel, toggleLlamacpp, changeLlamacppModel,
            changeEmbeddingModel, setHfToken, updateVllmConfig, updateLlamacppConfig,
            updateEmbeddingConfig, refreshGpuStatus, toggleLlamacppNew, createKey,
            quickAction, deleteModel, revokeKey,
            scaleVllm: arg => scaleVllm(Number(arg)),
        };
        document.addEventListener('click', event => {
            const el = event.target.closest('[data-action]');
            if (!el) return;
            const action = CLICK_ACTIONS[el.dataset.action];
            if (action) action(el.dataset.arg);
        });

        document.getElementById('stats-window-hours')?.addEventListener('change', () => {
            loadStats();
        });

        document.getElementById('stats-key-filter')?.addEventListener('change', () => {
            renderHourlyChart();
        });

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


def _admin_page_csp(html: str) -> str:
    """Page CSP: same-origin assets plus exactly the inline scripts of this page."""
    script_hashes = " ".join(
        "'sha256-" + base64.b64encode(hashlib.sha256(script.encode("utf-8")).digest()).decode("ascii") + "'"
        for script in re.findall(r"<script>(.*?)</script>", html, re.DOTALL)
    )
    return "; ".join([
        "default-src 'none'",
        f"script-src 'self' {script_hashes}",
        # Inline styles: the hourly chart sets bar heights through style attributes.
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self'",
        "connect-src 'self'",
        "form-action 'self'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
    ])


_ADMIN_LOGIN_CSP = _admin_page_csp(ADMIN_LOGIN_HTML)
_ADMIN_DASHBOARD_CSP = _admin_page_csp(ADMIN_HTML)

# Stylesheet for the admin pages, replacing the Tailwind CDN runtime. main.py ships
# alone in the gateway-code ConfigMap, so assets have to live in this file.
# Generated by Tailwind CSS 3.4.19 from the two HTML constants above. After using a
# class not already here, write those constants to admin.html and regenerate:
#   npx tailwindcss@3.4.19 --content admin.html --minify
# tests/test_admin_ui.py fails if a class in the HTML is missing from this.
_ADMIN_CSS = r"""*,::backdrop,:after,:before{--tw-border-spacing-x:0;--tw-border-spacing-y:0;--tw-translate-x:0;--tw-translate-y:0;--tw-rotate:0;--tw-skew-x:0;--tw-skew-y:0;--tw-scale-x:1;--tw-scale-y:1;--tw-pan-x: ;--tw-pan-y: ;--tw-pinch-zoom: ;--tw-scroll-snap-strictness:proximity;--tw-gradient-from-position: ;--tw-gradient-via-position: ;--tw-gradient-to-position: ;--tw-ordinal: ;--tw-slashed-zero: ;--tw-numeric-figure: ;--tw-numeric-spacing: ;--tw-numeric-fraction: ;--tw-ring-inset: ;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-color:#3b82f680;--tw-ring-offset-shadow:0 0 #0000;--tw-ring-shadow:0 0 #0000;--tw-shadow:0 0 #0000;--tw-shadow-colored:0 0 #0000;--tw-blur: ;--tw-brightness: ;--tw-contrast: ;--tw-grayscale: ;--tw-hue-rotate: ;--tw-invert: ;--tw-saturate: ;--tw-sepia: ;--tw-drop-shadow: ;--tw-backdrop-blur: ;--tw-backdrop-brightness: ;--tw-backdrop-contrast: ;--tw-backdrop-grayscale: ;--tw-backdrop-hue-rotate: ;--tw-backdrop-invert: ;--tw-backdrop-opacity: ;--tw-backdrop-saturate: ;--tw-backdrop-sepia: ;--tw-contain-size: ;--tw-contain-layout: ;--tw-contain-paint: ;--tw-contain-style: }
/*! tailwindcss v3.4.19 | MIT License | https://tailwindcss.com*/*,:after,:before{box-sizing:border-box;border:0 solid #e5e7eb}
:after,:before{--tw-content:""}
:host,html{line-height:1.5;-webkit-text-size-adjust:100%;-moz-tab-size:4;-o-tab-size:4;tab-size:4;font-family:ui-sans-serif,system-ui,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol,Noto Color Emoji;font-feature-settings:normal;font-variation-settings:normal;-webkit-tap-highlight-color:transparent}
body{margin:0;line-height:inherit}
hr{height:0;color:inherit;border-top-width:1px}
abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}
h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}
a{color:inherit;text-decoration:inherit}
b,strong{font-weight:bolder}
code,kbd,pre,samp{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-feature-settings:normal;font-variation-settings:normal;font-size:1em}
small{font-size:80%}
sub,sup{font-size:75%;line-height:0;position:relative;vertical-align:initial}
sub{bottom:-.25em}
sup{top:-.5em}
table{text-indent:0;border-color:inherit;border-collapse:collapse}
button,input,optgroup,select,textarea{font-family:inherit;font-feature-settings:inherit;font-variation-settings:inherit;font-size:100%;font-weight:inherit;line-height:inherit;letter-spacing:inherit;color:inherit;margin:0;padding:0}
button,select{text-transform:none}
button,input:where([type=button]),input:where([type=reset]),input:where([type=submit]){-webkit-appearance:button;background-color:initial;background-image:none}
:-moz-focusring{outline:auto}
:-moz-ui-invalid{box-shadow:none}
progress{vertical-align:initial}
::-webkit-inner-spin-button,::-webkit-outer-spin-button{height:auto}
[type=search]{-webkit-appearance:textfield;outline-offset:-2px}
::-webkit-search-decoration{-webkit-appearance:none}
::-webkit-file-upload-button{-webkit-appearance:button;font:inherit}
summary{display:list-item}
blockquote,dd,dl,figure,h1,h2,h3,h4,h5,h6,hr,p,pre{margin:0}
fieldset{margin:0}
fieldset,legend{padding:0}
menu,ol,ul{list-style:none;margin:0;padding:0}
dialog{padding:0}
textarea{resize:vertical}
input::-moz-placeholder,textarea::-moz-placeholder{opacity:1;color:#9ca3af}
input::placeholder,textarea::placeholder{opacity:1;color:#9ca3af}
[role=button],button{cursor:pointer}
:disabled{cursor:default}
audio,canvas,embed,iframe,img,object,svg,video{display:block;vertical-align:middle}
img,video{max-width:100%;height:auto}
[hidden]:where(:not([hidden=until-found])){display:none}
.\!container{width:100%!important}
.container{width:100%}
@media (min-width:640px){.\!container{max-width:640px!important}
.container{max-width:640px}
}
@media (min-width:768px){.\!container{max-width:768px!important}
.container{max-width:768px}
}
@media (min-width:1024px){.\!container{max-width:1024px!important}
.container{max-width:1024px}
}
@media (min-width:1280px){.\!container{max-width:1280px!important}
.container{max-width:1280px}
}
@media (min-width:1536px){.\!container{max-width:1536px!important}
.container{max-width:1536px}
}
.col-span-2{grid-column:span 2/span 2}
.mx-4{margin-left:1rem;margin-right:1rem}
.mx-auto{margin-left:auto;margin-right:auto}
.mb-2{margin-bottom:.5rem}
.mb-3{margin-bottom:.75rem}
.mb-4{margin-bottom:1rem}
.mb-6{margin-bottom:1.5rem}
.mb-8{margin-bottom:2rem}
.ml-2{margin-left:.5rem}
.mt-0\.5{margin-top:.125rem}
.mt-1{margin-top:.25rem}
.mt-2{margin-top:.5rem}
.mt-3{margin-top:.75rem}
.mt-4{margin-top:1rem}
.mt-6{margin-top:1.5rem}
.block{display:block}
.inline{display:inline}
.flex{display:flex}
.grid{display:grid}
.hidden{display:none}
.h-16{height:4rem}
.h-2{height:.5rem}
.h-24{height:6rem}
.h-3{height:.75rem}
.h-4{height:1rem}
.h-5{height:1.25rem}
.h-8{height:2rem}
.h-full{height:100%}
.min-h-screen{min-height:100vh}
.w-16{width:4rem}
.w-3{width:.75rem}
.w-4{width:1rem}
.w-5{width:1.25rem}
.w-8{width:2rem}
.w-full{width:100%}
.min-w-0{min-width:0}
.max-w-6xl{max-width:72rem}
.max-w-md{max-width:28rem}
.flex-1{flex:1 1 0%}
@keyframes spin{to{transform:rotate(1turn)}
}
.animate-spin{animation:spin 1s linear infinite}
.cursor-pointer{cursor:pointer}
.list-inside{list-style-position:inside}
.list-disc{list-style-type:disc}
.grid-cols-1{grid-template-columns:repeat(1,minmax(0,1fr))}
.grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}
.flex-col{flex-direction:column}
.flex-wrap{flex-wrap:wrap}
.items-start{align-items:flex-start}
.items-end{align-items:flex-end}
.items-center{align-items:center}
.justify-center{justify-content:center}
.justify-between{justify-content:space-between}
.gap-1{gap:.25rem}
.gap-2{gap:.5rem}
.gap-3{gap:.75rem}
.gap-4{gap:1rem}
.space-y-1>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.25rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.25rem*var(--tw-space-y-reverse))}
.space-y-2>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(.5rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(.5rem*var(--tw-space-y-reverse))}
.space-y-4>:not([hidden])~:not([hidden]){--tw-space-y-reverse:0;margin-top:calc(1rem*(1 - var(--tw-space-y-reverse)));margin-bottom:calc(1rem*var(--tw-space-y-reverse))}
.overflow-hidden{overflow:hidden}
.break-all{word-break:break-all}
.rounded{border-radius:.25rem}
.rounded-full{border-radius:9999px}
.rounded-lg{border-radius:.5rem}
.rounded-t{border-top-left-radius:.25rem;border-top-right-radius:.25rem}
.border{border-width:1px}
.border-2{border-width:2px}
.border-l-2{border-left-width:2px}
.border-l-4{border-left-width:4px}
.border-blue-400{--tw-border-opacity:1;border-color:rgb(96 165 250/var(--tw-border-opacity,1))}
.border-blue-500{--tw-border-opacity:1;border-color:rgb(59 130 246/var(--tw-border-opacity,1))}
.border-blue-700{--tw-border-opacity:1;border-color:rgb(29 78 216/var(--tw-border-opacity,1))}
.border-gray-500{--tw-border-opacity:1;border-color:rgb(107 114 128/var(--tw-border-opacity,1))}
.border-gray-600{--tw-border-opacity:1;border-color:rgb(75 85 99/var(--tw-border-opacity,1))}
.border-gray-700{--tw-border-opacity:1;border-color:rgb(55 65 81/var(--tw-border-opacity,1))}
.border-green-500{--tw-border-opacity:1;border-color:rgb(34 197 94/var(--tw-border-opacity,1))}
.border-purple-500{--tw-border-opacity:1;border-color:rgb(168 85 247/var(--tw-border-opacity,1))}
.border-red-700{--tw-border-opacity:1;border-color:rgb(185 28 28/var(--tw-border-opacity,1))}
.border-yellow-500{--tw-border-opacity:1;border-color:rgb(234 179 8/var(--tw-border-opacity,1))}
.border-yellow-600{--tw-border-opacity:1;border-color:rgb(202 138 4/var(--tw-border-opacity,1))}
.border-t-transparent{border-top-color:#0000}
.bg-blue-700{--tw-bg-opacity:1;background-color:rgb(29 78 216/var(--tw-bg-opacity,1))}
.bg-blue-900\/30{background-color:#1e3a8a4d}
.bg-gray-600{--tw-bg-opacity:1;background-color:rgb(75 85 99/var(--tw-bg-opacity,1))}
.bg-gray-700{--tw-bg-opacity:1;background-color:rgb(55 65 81/var(--tw-bg-opacity,1))}
.bg-gray-800{--tw-bg-opacity:1;background-color:rgb(31 41 55/var(--tw-bg-opacity,1))}
.bg-gray-900{--tw-bg-opacity:1;background-color:rgb(17 24 39/var(--tw-bg-opacity,1))}
.bg-green-500{--tw-bg-opacity:1;background-color:rgb(34 197 94/var(--tw-bg-opacity,1))}
.bg-green-700{--tw-bg-opacity:1;background-color:rgb(21 128 61/var(--tw-bg-opacity,1))}
.bg-green-900{--tw-bg-opacity:1;background-color:rgb(20 83 45/var(--tw-bg-opacity,1))}
.bg-purple-500{--tw-bg-opacity:1;background-color:rgb(168 85 247/var(--tw-bg-opacity,1))}
.bg-purple-600{--tw-bg-opacity:1;background-color:rgb(147 51 234/var(--tw-bg-opacity,1))}
.bg-purple-700{--tw-bg-opacity:1;background-color:rgb(126 34 206/var(--tw-bg-opacity,1))}
.bg-red-700{--tw-bg-opacity:1;background-color:rgb(185 28 28/var(--tw-bg-opacity,1))}
.bg-red-900{--tw-bg-opacity:1;background-color:rgb(127 29 29/var(--tw-bg-opacity,1))}
.bg-red-900\/30{background-color:#7f1d1d4d}
.bg-yellow-700{--tw-bg-opacity:1;background-color:rgb(161 98 7/var(--tw-bg-opacity,1))}
.bg-yellow-900{--tw-bg-opacity:1;background-color:rgb(113 63 18/var(--tw-bg-opacity,1))}
.bg-opacity-30{--tw-bg-opacity:0.3}
.p-1{padding:.25rem}
.p-2{padding:.5rem}
.p-3{padding:.75rem}
.p-4{padding:1rem}
.p-6{padding:1.5rem}
.p-8{padding:2rem}
.px-1{padding-left:.25rem;padding-right:.25rem}
.px-2{padding-left:.5rem;padding-right:.5rem}
.px-3{padding-left:.75rem;padding-right:.75rem}
.px-4{padding-left:1rem;padding-right:1rem}
.py-0\.5{padding-top:.125rem;padding-bottom:.125rem}
.py-1{padding-top:.25rem;padding-bottom:.25rem}
.py-1\.5{padding-top:.375rem;padding-bottom:.375rem}
.py-2{padding-top:.5rem;padding-bottom:.5rem}
.py-3{padding-top:.75rem;padding-bottom:.75rem}
.py-4{padding-top:1rem;padding-bottom:1rem}
.py-8{padding-top:2rem;padding-bottom:2rem}
.pl-4{padding-left:1rem}
.text-center{text-align:center}
.font-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace}
.text-2xl{font-size:1.5rem;line-height:2rem}
.text-3xl{font-size:1.875rem;line-height:2.25rem}
.text-sm{font-size:.875rem;line-height:1.25rem}
.text-xl{font-size:1.25rem;line-height:1.75rem}
.text-xs{font-size:.75rem;line-height:1rem}
.font-bold{font-weight:700}
.font-medium{font-weight:500}
.font-semibold{font-weight:600}
.text-blue-300{--tw-text-opacity:1;color:rgb(147 197 253/var(--tw-text-opacity,1))}
.text-blue-400{--tw-text-opacity:1;color:rgb(96 165 250/var(--tw-text-opacity,1))}
.text-cyan-300{--tw-text-opacity:1;color:rgb(103 232 249/var(--tw-text-opacity,1))}
.text-cyan-400{--tw-text-opacity:1;color:rgb(34 211 238/var(--tw-text-opacity,1))}
.text-gray-100{--tw-text-opacity:1;color:rgb(243 244 246/var(--tw-text-opacity,1))}
.text-gray-300{--tw-text-opacity:1;color:rgb(209 213 219/var(--tw-text-opacity,1))}
.text-gray-400{--tw-text-opacity:1;color:rgb(156 163 175/var(--tw-text-opacity,1))}
.text-gray-500{--tw-text-opacity:1;color:rgb(107 114 128/var(--tw-text-opacity,1))}
.text-green-300{--tw-text-opacity:1;color:rgb(134 239 172/var(--tw-text-opacity,1))}
.text-green-400{--tw-text-opacity:1;color:rgb(74 222 128/var(--tw-text-opacity,1))}
.text-orange-400{--tw-text-opacity:1;color:rgb(251 146 60/var(--tw-text-opacity,1))}
.text-purple-400{--tw-text-opacity:1;color:rgb(192 132 252/var(--tw-text-opacity,1))}
.text-red-200{--tw-text-opacity:1;color:rgb(254 202 202/var(--tw-text-opacity,1))}
.text-red-300{--tw-text-opacity:1;color:rgb(252 165 165/var(--tw-text-opacity,1))}
.text-red-400{--tw-text-opacity:1;color:rgb(248 113 113/var(--tw-text-opacity,1))}
.text-red-500{--tw-text-opacity:1;color:rgb(239 68 68/var(--tw-text-opacity,1))}
.text-white{--tw-text-opacity:1;color:rgb(255 255 255/var(--tw-text-opacity,1))}
.text-yellow-200{--tw-text-opacity:1;color:rgb(254 240 138/var(--tw-text-opacity,1))}
.text-yellow-300{--tw-text-opacity:1;color:rgb(253 224 71/var(--tw-text-opacity,1))}
.text-yellow-400{--tw-text-opacity:1;color:rgb(250 204 21/var(--tw-text-opacity,1))}
.placeholder-gray-500::-moz-placeholder{--tw-placeholder-opacity:1;color:rgb(107 114 128/var(--tw-placeholder-opacity,1))}
.placeholder-gray-500::placeholder{--tw-placeholder-opacity:1;color:rgb(107 114 128/var(--tw-placeholder-opacity,1))}
.opacity-70{opacity:.7}
.shadow-2xl{--tw-shadow:0 25px 50px -12px #00000040;--tw-shadow-colored:0 25px 50px -12px var(--tw-shadow-color);box-shadow:var(--tw-ring-offset-shadow,0 0 #0000),var(--tw-ring-shadow,0 0 #0000),var(--tw-shadow)}
.filter{filter:var(--tw-blur) var(--tw-brightness) var(--tw-contrast) var(--tw-grayscale) var(--tw-hue-rotate) var(--tw-invert) var(--tw-saturate) var(--tw-sepia) var(--tw-drop-shadow)}
.transition{transition-property:color,background-color,border-color,text-decoration-color,fill,stroke,opacity,box-shadow,transform,filter,-webkit-backdrop-filter;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke,opacity,box-shadow,transform,filter,backdrop-filter;transition-property:color,background-color,border-color,text-decoration-color,fill,stroke,opacity,box-shadow,transform,filter,backdrop-filter,-webkit-backdrop-filter;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}
.transition-all{transition-property:all;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:.15s}
.duration-200{transition-duration:.2s}
.hover\:bg-blue-600:hover{--tw-bg-opacity:1;background-color:rgb(37 99 235/var(--tw-bg-opacity,1))}
.hover\:bg-gray-500:hover{--tw-bg-opacity:1;background-color:rgb(107 114 128/var(--tw-bg-opacity,1))}
.hover\:bg-gray-600:hover{--tw-bg-opacity:1;background-color:rgb(75 85 99/var(--tw-bg-opacity,1))}
.hover\:bg-green-600:hover{--tw-bg-opacity:1;background-color:rgb(22 163 74/var(--tw-bg-opacity,1))}
.hover\:bg-purple-600:hover{--tw-bg-opacity:1;background-color:rgb(147 51 234/var(--tw-bg-opacity,1))}
.hover\:bg-purple-700:hover{--tw-bg-opacity:1;background-color:rgb(126 34 206/var(--tw-bg-opacity,1))}
.hover\:bg-red-600:hover{--tw-bg-opacity:1;background-color:rgb(220 38 38/var(--tw-bg-opacity,1))}
.hover\:bg-yellow-600:hover{--tw-bg-opacity:1;background-color:rgb(202 138 4/var(--tw-bg-opacity,1))}
.hover\:text-blue-300:hover{--tw-text-opacity:1;color:rgb(147 197 253/var(--tw-text-opacity,1))}
.hover\:text-cyan-300:hover{--tw-text-opacity:1;color:rgb(103 232 249/var(--tw-text-opacity,1))}
.hover\:text-gray-300:hover{--tw-text-opacity:1;color:rgb(209 213 219/var(--tw-text-opacity,1))}
.hover\:text-green-300:hover{--tw-text-opacity:1;color:rgb(134 239 172/var(--tw-text-opacity,1))}
.hover\:text-purple-300:hover{--tw-text-opacity:1;color:rgb(216 180 254/var(--tw-text-opacity,1))}
.hover\:text-red-300:hover{--tw-text-opacity:1;color:rgb(252 165 165/var(--tw-text-opacity,1))}
.hover\:text-yellow-300:hover{--tw-text-opacity:1;color:rgb(253 224 71/var(--tw-text-opacity,1))}
.hover\:opacity-100:hover{opacity:1}
.focus\:border-transparent:focus{border-color:#0000}
.focus\:outline-none:focus{outline:2px solid #0000;outline-offset:2px}
.focus\:ring-2:focus{--tw-ring-offset-shadow:var(--tw-ring-inset) 0 0 0 var(--tw-ring-offset-width) var(--tw-ring-offset-color);--tw-ring-shadow:var(--tw-ring-inset) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color);box-shadow:var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow,0 0 #0000)}
.focus\:ring-blue-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(59 130 246/var(--tw-ring-opacity,1))}
.focus\:ring-gray-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(107 114 128/var(--tw-ring-opacity,1))}
.focus\:ring-green-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(34 197 94/var(--tw-ring-opacity,1))}
.focus\:ring-purple-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(168 85 247/var(--tw-ring-opacity,1))}
.focus\:ring-yellow-500:focus{--tw-ring-opacity:1;--tw-ring-color:rgb(234 179 8/var(--tw-ring-opacity,1))}
@media (min-width:768px){.md\:grid-cols-2{grid-template-columns:repeat(2,minmax(0,1fr))}
.md\:grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}
.md\:grid-cols-4{grid-template-columns:repeat(4,minmax(0,1fr))}
.md\:flex-row{flex-direction:row}
.md\:items-end{align-items:flex-end}
.md\:justify-between{justify-content:space-between}
}
"""

# Replaces unpkg.com/lucide@latest with only the icons the pages use, built with DOM
# calls. Icon data is from lucide-static 1.66.0, under the licenses below.
# tests/test_admin_ui.py fails if the HTML uses an icon missing from this.
#
# ISC License. Copyright (c) 2026 Lucide Icons and Contributors
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# alert-circle, download, external-link, key, log-in, log-out, power, server and
# trash-2 derive from the Feather project:
#
# The MIT License (MIT). Copyright (c) 2013-present Cole Bemis
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
_ADMIN_ICONS_JS = r"""(function () {
  'use strict';
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var BASE = {
    xmlns: SVG_NS, width: '24', height: '24', viewBox: '0 0 24 24', fill: 'none',
    stroke: 'currentColor', 'stroke-width': '2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round'
  };
  var ICONS = {
  "alert-circle": [["circle",{"cx":"12","cy":"12","r":"10"}],["line",{"x1":"12","x2":"12","y1":"8","y2":"12"}],["line",{"x1":"12","x2":"12.01","y1":"16","y2":"16"}]],
  "bar-chart-3": [["path",{"d":"M3 3v16a2 2 0 0 0 2 2h16"}],["path",{"d":"M18 17V9"}],["path",{"d":"M13 17V5"}],["path",{"d":"M8 17v-3"}]],
  "binary": [["rect",{"x":"14","y":"14","width":"4","height":"6","rx":"2"}],["rect",{"x":"6","y":"4","width":"4","height":"6","rx":"2"}],["path",{"d":"M6 20h4"}],["path",{"d":"M14 10h4"}],["path",{"d":"M6 14h2v6"}],["path",{"d":"M14 4h2v6"}]],
  "boxes": [["path",{"d":"M2.97 12.92A2 2 0 0 0 2 14.63v3.24a2 2 0 0 0 .97 1.71l3 1.8a2 2 0 0 0 2.06 0L12 19v-5.5l-5-3-4.03 2.42Z"}],["path",{"d":"m7 16.5-4.74-2.85"}],["path",{"d":"m7 16.5 5-3"}],["path",{"d":"M7 16.5v5.17"}],["path",{"d":"M12 13.5V19l3.97 2.38a2 2 0 0 0 2.06 0l3-1.8a2 2 0 0 0 .97-1.71v-3.24a2 2 0 0 0-.97-1.71L17 10.5l-5 3Z"}],["path",{"d":"m17 16.5-5-3"}],["path",{"d":"m17 16.5 4.74-2.85"}],["path",{"d":"M17 16.5v5.17"}],["path",{"d":"M7.97 4.42A2 2 0 0 0 7 6.13v4.37l5 3 5-3V6.13a2 2 0 0 0-.97-1.71l-3-1.8a2 2 0 0 0-2.06 0l-3 1.8Z"}],["path",{"d":"M12 8 7.26 5.15"}],["path",{"d":"m12 8 4.74-2.85"}],["path",{"d":"M12 13.5V8"}]],
  "brain": [["path",{"d":"M12 18V5"}],["path",{"d":"M15 13a4.17 4.17 0 01-3-4 4.17 4.17 0 01-3 4"}],["path",{"d":"M17.707 6.294A3 3 0 1012 5a3 3 0 10-5.707 1.294"}],["path",{"d":"M17.996 5.125a4 4 0 012.526 5.77"}],["path",{"d":"M18 18a4 4 0 002-7.465"}],["path",{"d":"M19.967 17.482a4 4 0 11-7.967.517 4 4 0 11-7.967-.517"}],["path",{"d":"M6 18a4 4 0 01-2-7.465"}],["path",{"d":"M6.004 5.125a4 4 0 00-2.526 5.77"}]],
  "cpu": [["path",{"d":"M12 20v2"}],["path",{"d":"M12 2v2"}],["path",{"d":"M17 20v2"}],["path",{"d":"M17 2v2"}],["path",{"d":"M2 12h2"}],["path",{"d":"M2 17h2"}],["path",{"d":"M2 7h2"}],["path",{"d":"M20 12h2"}],["path",{"d":"M20 17h2"}],["path",{"d":"M20 7h2"}],["path",{"d":"M7 20v2"}],["path",{"d":"M7 2v2"}],["rect",{"x":"4","y":"4","width":"16","height":"16","rx":"2"}],["rect",{"x":"8","y":"8","width":"8","height":"8","rx":"1"}]],
  "download": [["path",{"d":"M12 15V3"}],["path",{"d":"M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"}],["path",{"d":"m7 10 5 5 5-5"}]],
  "external-link": [["path",{"d":"M15 3h6v6"}],["path",{"d":"M10 14 21 3"}],["path",{"d":"M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"}]],
  "hard-drive": [["path",{"d":"M10 16h.01"}],["path",{"d":"M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"}],["path",{"d":"M21.946 12.013H2.054"}],["path",{"d":"M6 16h.01"}]],
  "key": [["path",{"d":"m2 21 9.6-9.6"}],["path",{"d":"m7.5 15.5 2.3 2.3a1 1 0 0 1 0 1.4l-2.1 2.1a1 1 0 0 1-1.4 0L4 19"}],["circle",{"cx":"15.5","cy":"7.5","r":"5.5"}]],
  "key-round": [["path",{"d":"M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"}],["circle",{"cx":"16.5","cy":"7.5","r":".5","fill":"currentColor"}]],
  "log-in": [["path",{"d":"m10 17 5-5-5-5"}],["path",{"d":"M15 12H3"}],["path",{"d":"M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"}]],
  "log-out": [["path",{"d":"m16 17 5-5-5-5"}],["path",{"d":"M21 12H9"}],["path",{"d":"M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"}]],
  "play-circle": [["path",{"d":"M9 9.003a1 1 0 0 1 1.517-.859l4.997 2.997a1 1 0 0 1 0 1.718l-4.997 2.997A1 1 0 0 1 9 14.996z"}],["circle",{"cx":"12","cy":"12","r":"10"}]],
  "power": [["path",{"d":"M12 2v10"}],["path",{"d":"M18.4 6.6a9 9 0 1 1-12.77.04"}]],
  "refresh-cw": [["path",{"d":"M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"}],["path",{"d":"M21 3v5h-5"}],["path",{"d":"M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"}],["path",{"d":"M8 16H3v5"}]],
  "save": [["path",{"d":"M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"}],["path",{"d":"M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7"}],["path",{"d":"M7 3v4a1 1 0 0 0 1 1h7"}]],
  "scale": [["path",{"d":"M12 3v18"}],["path",{"d":"m19 8 3 8a5 5 0 0 1-6 0zV7"}],["path",{"d":"M3 7h1a17 17 0 0 0 8-2 17 17 0 0 0 8 2h1"}],["path",{"d":"m5 8 3 8a5 5 0 0 1-6 0zV7"}],["path",{"d":"M7 21h10"}]],
  "server": [["rect",{"width":"20","height":"8","x":"2","y":"2","rx":"2","ry":"2"}],["rect",{"width":"20","height":"8","x":"2","y":"14","rx":"2","ry":"2"}],["line",{"x1":"6","x2":"6.01","y1":"6","y2":"6"}],["line",{"x1":"6","x2":"6.01","y1":"18","y2":"18"}]],
  "settings": [["path",{"d":"M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915"}],["circle",{"cx":"12","cy":"12","r":"3"}]],
  "sparkles": [["path",{"d":"M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"}],["path",{"d":"M20 2v4"}],["path",{"d":"M22 4h-4"}],["circle",{"cx":"4","cy":"20","r":"2"}]],
  "trash-2": [["path",{"d":"M10 11v6"}],["path",{"d":"M14 11v6"}],["path",{"d":"M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"}],["path",{"d":"M3 6h18"}],["path",{"d":"M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"}]],
  "zap": [["path",{"d":"M15.914 4a1.5 1.5 0 00-2.474-1.561l-9 9A1.5 1.5 0 005.5 14h4.002a.5.5 0 01.471.666L8.086 20a1.5 1.5 0 002.475 1.56l9-9A1.5 1.5 0 0018.5 10h-3.997a.5.5 0 01-.472-.667z"}]]
  };

  function create(tag, attrs) {
    var el = document.createElementNS(SVG_NS, tag);
    Object.keys(attrs).forEach(function (name) { el.setAttribute(name, attrs[name]); });
    return el;
  }

  window.lucide = {
    createIcons: function () {
      document.querySelectorAll('[data-lucide]').forEach(function (el) {
        var name = el.getAttribute('data-lucide');
        if (!ICONS[name]) return;
        var svg = create('svg', BASE);
        Array.prototype.forEach.call(el.attributes, function (attr) {
          svg.setAttribute(attr.name, attr.value);
        });
        svg.classList.add('lucide', 'lucide-' + name);
        ICONS[name].forEach(function (node) { svg.appendChild(create(node[0], node[1])); });
        el.replaceWith(svg);
      });
    }
  };
})();
"""


@app.get("/admin/assets/admin.css", include_in_schema=False)
async def admin_css():
    return Response(_ADMIN_CSS, media_type="text/css", headers={"Cache-Control": "no-cache"})


@app.get("/admin/assets/icons.js", include_in_schema=False)
async def admin_icons_js():
    return Response(_ADMIN_ICONS_JS, media_type="text/javascript", headers={"Cache-Control": "no-cache"})


@app.get("/admin", response_class=HTMLResponse)
async def admin_ui():
    """Admin UI for managing the LLM API - requires 'admin' scope."""
    return HTMLResponse(ADMIN_LOGIN_HTML, headers={"Content-Security-Policy": _ADMIN_LOGIN_CSP})


@app.get("/admin/dashboard", response_class=HTMLResponse)
async def admin_dashboard():
    """Admin dashboard - authentication handled by JavaScript with localStorage API key."""
    return HTMLResponse(ADMIN_HTML, headers={"Content-Security-Policy": _ADMIN_DASHBOARD_CSP})


# Short, because the page loads this list on every visit to the models tab.
VLLM_DOWNLOAD_STATUS_TIMEOUT_SECONDS = 5


def _downloader_state(pod) -> Optional[str]:
    """'downloading', 'failed' or None for a vLLM pod's model-downloader init container."""
    for status in pod.status.init_container_statuses or []:
        if status.name != "model-downloader":
            continue
        state = status.state
        if state and state.running:
            return "downloading"
        if state and state.terminated:
            return "failed" if state.terminated.exit_code else None
        # Waiting between restarts: the last run says why. Before a first run there is none.
        last = status.last_state.terminated if status.last_state else None
        return "failed" if last and last.exit_code else None
    return None


async def _read_vllm_download_status(namespace: str) -> Optional[dict]:
    core_v1, _ = await _k8s_clients()
    pods = await _k8s_call(core_v1.list_namespaced_pod, namespace, label_selector="app=vllm")

    by_state = {}
    for pod in pods.items:
        state = _downloader_state(pod)
        if state:
            by_state.setdefault(state, pod.metadata.name)
    state = "failed" if "failed" in by_state else "downloading" if "downloading" in by_state else None
    if not state:
        return None

    try:
        configmap = await _k8s_call(core_v1.read_namespaced_config_map, "vllm-config", namespace)
        model = (configmap.data or {}).get("MODEL_NAME") or "unknown"
    except (ApiException, HTTPException):
        model = "unknown"
    error = None
    if state == "failed":
        error = f"See the logs: kubectl logs -n {namespace} {by_state[state]} -c model-downloader"
    return {"status": state, "model": model, "error": error}


async def _vllm_download_status() -> Optional[dict]:
    """What vLLM's model-downloader init containers are doing, read from their pods.

    They have no Redis access, so the pods are the only source. Returns None if no download
    is running or failing, and status "unavailable" if the pods can't be read, so the
    Admin UI doesn't show "don't know" as "nothing is happening".
    """
    namespace = os.getenv("NAMESPACE", "llmapi")
    try:
        return await asyncio.wait_for(
            _read_vllm_download_status(namespace), VLLM_DOWNLOAD_STATUS_TIMEOUT_SECONDS
        )
    except Exception as e:
        logger.warning(f"Could not read vLLM download status: {type(e).__name__}")
        return {"status": "unavailable", "model": "unknown", "error": None}


@app.get("/admin/models")
async def admin_list_models(api_key: str = Depends(get_api_key)):
    """List all models (admin endpoint)."""
    await require_scope("admin", api_key)

    return {
        "models": model_registry.get_available_models(),
        "backends": model_registry.backends,
        "download_status": await _vllm_download_status(),
    }


@app.get("/admin/keys")
async def admin_list_keys(api_key: str = Depends(get_api_key)):
    """List all API keys (admin endpoint)."""
    await require_scope("admin", api_key)
    keys = await postgres_client.list_api_keys()
    return {"keys": keys}


# The limit columns in api_keys are INTEGER.
MAX_KEY_LIMIT = 2_147_483_647


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

    try:
        requests_per_minute = int(body.get("requests_per_minute", 60))
        tokens_per_day = int(body.get("tokens_per_day", 100000))

        default_tpm = (
            config.ADMIN_DEFAULT_TOKENS_PER_MINUTE
            if "admin" in scopes
            else config.DEFAULT_TOKENS_PER_MINUTE
        )
        raw_tpm = body.get("tokens_per_minute", None)
        tokens_per_minute = int(raw_tpm) if raw_tpm is not None else default_tpm
        tokens_per_minute = max(config.MIN_TOKENS_PER_MINUTE, tokens_per_minute)
    except (TypeError, ValueError, OverflowError):
        raise HTTPException(
            status_code=400,
            detail="requests_per_minute, tokens_per_day, and tokens_per_minute must be integers",
        )

    if requests_per_minute <= 0 or tokens_per_day <= 0 or tokens_per_minute <= 0:
        raise HTTPException(
            status_code=400,
            detail="requests_per_minute, tokens_per_day, and tokens_per_minute must be > 0",
        )
    if max(requests_per_minute, tokens_per_day, tokens_per_minute) > MAX_KEY_LIMIT:
        raise HTTPException(
            status_code=400,
            detail=f"requests_per_minute, tokens_per_day, and tokens_per_minute must be at most {MAX_KEY_LIMIT}",
        )

    new_key = f"sk-mynodeone-{secrets.token_hex(16)}"
    key_id = hash_api_key(new_key)

    key_config = {
        "key_prefix": api_key_display_prefix(new_key),
        "name": name,
        "scopes": scopes,
        "requests_per_minute": requests_per_minute,
        "tokens_per_day": tokens_per_day,
        "tokens_per_minute": tokens_per_minute,
        "created_at": datetime.utcnow().isoformat(),
    }

    await postgres_client.set_api_key_config(key_id, key_config)
    await redis_client.set_api_key_config(key_id, key_config)

    # The only time the raw key is available.
    return {"key": new_key, "key_id": key_id, "config": key_config}


@app.delete("/admin/keys/{api_key}")
async def admin_revoke_key(api_key: str, admin_key: str = Depends(get_api_key)):
    """Revoke an API key by key id or raw key (admin endpoint)."""
    await require_scope("admin", admin_key)
    key_id = key_ref_to_id(api_key)
    if key_id != api_key:
        await postgres_client.migrate_plaintext_key(api_key)
        await redis_client.delete_api_key_config(api_key)
    await postgres_client.delete_api_key(key_id)
    # Remove from Redis cache immediately so the key stops working right away
    await redis_client.delete_api_key_config(key_id)
    return {"status": "revoked", "key_id": key_id}


@app.get("/admin/usage/{api_key}")
async def admin_get_usage(api_key: str, admin_key: str = Depends(get_api_key)):
    """Get usage for a specific API key, by key id or raw key."""
    await require_scope("admin", admin_key)
    api_key = key_ref_to_id(api_key)
    key_config = await postgres_client.get_api_key_config(api_key)
    if not key_config:
        raise HTTPException(status_code=404, detail="API key not found")

    input_tokens, output_tokens = await postgres_client.get_token_usage(api_key)
    bucket_rpms = {}
    for bucket in rate_limiter.SERVICE_BUCKETS:
        bucket_rpms[bucket], _ = await redis_client.get_rate_limit_info(api_key, bucket=bucket)
    bucket_limits = {
        bucket: {
            "requests_this_minute": bucket_rpms[bucket],
            "requests_limit_rpm": rate_limiter._rpm_limit(key_config, bucket),
            "tokens_limit_tpm": rate_limiter._tpm_limit(key_config, bucket),
        }
        for bucket in rate_limiter.SERVICE_BUCKETS
    }

    return {
        "api_key": (key_config.get("key_prefix") or api_key[:16]) + "...",
        "key_id": api_key,
        "name": key_config.get("name"),
        "tokens_used_today": input_tokens + output_tokens,
        "tokens_limit_daily": key_config.get("tokens_per_day"),
        "requests_this_minute": sum(bucket_rpms.values()),
        "requests_limit_rpm": sum(
            bucket["requests_limit_rpm"] for bucket in bucket_limits.values()
        ),
        "tokens_limit_tpm": sum(
            bucket["tokens_limit_tpm"] for bucket in bucket_limits.values()
        ),
        "rate_limit_buckets": bucket_limits,
    }


@app.get("/admin/stats")
async def admin_get_stats(hours: int = 96, api_key: str = Depends(get_api_key)):
    """Get comprehensive usage statistics for all API keys."""
    await require_scope("admin", api_key)
    return await postgres_client.get_all_keys_stats(hours=hours)


@app.post("/admin/rate-limiter/reset")
async def admin_reset_rate_limiter(request: Request, admin_key: str = Depends(get_api_key)):
    """Clear in-process concurrency limiter leases for this gateway pod."""
    await require_scope("admin", admin_key)
    try:
        body = await request.json()
    except HTTPException:
        raise  # Over the size limit. An empty body here would mean "reset everything".
    except Exception:
        body = {}

    target_api_key = body.get("api_key") if isinstance(body, dict) else None
    if target_api_key:
        target_api_key = key_ref_to_id(str(target_api_key))
    target_bucket = body.get("limit_bucket") if isinstance(body, dict) else None
    valid_buckets = set(rate_limiter.SERVICE_BUCKETS)
    if target_bucket is not None and target_bucket not in valid_buckets:
        raise HTTPException(
            status_code=400,
            detail=f"limit_bucket must be one of: {', '.join(rate_limiter.SERVICE_BUCKETS)}",
        )

    target_backend = body.get("backend") if isinstance(body, dict) else None
    target_backend_key = body.get("backend_key") if isinstance(body, dict) else None
    if target_backend is not None and target_backend not in valid_buckets:
        raise HTTPException(
            status_code=400,
            detail=f"backend must be one of: {', '.join(rate_limiter.SERVICE_BUCKETS)}",
        )

    result = await rate_limiter.reset(target_api_key, target_bucket)
    backend_result = None
    if not target_api_key:
        backend_result = await backend_manager.reset(target_backend, target_backend_key)
    return {
        "status": "reset",
        "scope": "api_key" if target_api_key else "gateway_process",
        "limit_bucket": target_bucket or "all",
        "backend": target_backend or target_backend_key or ("skipped" if target_api_key else "all"),
        "note": "This resets only the gateway process that handled the request. Roll the deployment to reset all replicas immediately.",
        "rate_limiter": result,
        "backend_limiter": backend_result,
    }


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
    """Delete a cached model from Ollama.

    Only the Ollama mapping is removed from the registry — if the same model
    name is also served by vLLM or llama.cpp, those mappings survive so the
    model remains routable on its other backends."""
    await require_scope("admin", api_key)
    try:
        resp = await backend_manager.http_client.delete(
            f"{config.OLLAMA_URL}/api/delete",
            json={"name": model_name}
        )
        if resp.status_code == 200:
            model_registry.unregister_model(model_name, backend="ollama")
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


async def _save_hf_token(hf_token) -> dict:
    """Write the HuggingFace token to Secret hf-token, or say why it wasn't saved.

    The Secret is the only copy. Redis just records that a token was saved, so a
    failed save can't leave the token there, and a working one leaves no plaintext.
    """
    if not isinstance(hf_token, str) or not hf_token.strip():
        raise HTTPException(status_code=400, detail="hf_token must be a non-empty string")

    namespace = os.getenv("NAMESPACE", "llmapi")
    patch = {"data": {"token": base64.b64encode(hf_token.strip().encode()).decode()}}
    try:
        core_v1, _ = await _k8s_clients()
        await _k8s_call(core_v1.patch_namespaced_secret, "hf-token", namespace, patch)
    except ApiException as e:
        # Only the status: the error's text is the API server's whole response.
        logger.error(f"Failed to save HF token: Kubernetes API status {e.status}")
        if e.status == 403:
            raise HTTPException(
                status_code=503,
                detail=(
                    "Token NOT saved: the gateway has no permission to write Secret hf-token. "
                    "Grant it in the gateway Role, or run scripts/apps/llmapi/lib/hf-token.sh set on the control node."
                ),
            )
        if e.status == 404:
            raise HTTPException(
                status_code=409,
                detail=(
                    "Token NOT saved: Secret hf-token does not exist, and the gateway only updates it. "
                    "Create it with scripts/apps/llmapi/lib/hf-token.sh set on the control node."
                ),
            )
        raise HTTPException(status_code=502, detail=f"Token NOT saved: Kubernetes API returned status {e.status}.")
    except HTTPException as e:
        if e.status_code == 504:
            raise HTTPException(
                status_code=504,
                detail="Token may not be saved: the Kubernetes API did not respond. Save it again to be sure.",
            )
        raise
    except ImportError as e:
        # Kubernetes client required for proper token storage
        logger.error(f"Kubernetes client not available: {e}")
        raise HTTPException(
            status_code=503,
            detail="Kubernetes client required for token storage. Cannot save token."
        )
    except Exception as e:
        # Such as no in-cluster config. Only the type: nothing that might quote the request.
        logger.error(f"Failed to save HF token: {type(e).__name__}")
        raise HTTPException(status_code=502, detail="Token NOT saved: could not use the Kubernetes API.")

    await redis_client.set_value("config:hf_token_saved", "1")
    # Older versions kept the token itself here.
    await redis_client.delete_value("config:hf_token")
    logger.info("HuggingFace token updated successfully")
    return {"status": "saved", "message": "HuggingFace token updated. Restart vLLM pods to use new token."}


@app.post("/admin/config")
async def admin_update_config(request: Request, api_key: str = Depends(get_api_key)):
    """Update configuration (e.g., HF token)."""
    await require_scope("admin", api_key)
    body = await request.json()

    # Update HF token in Kubernetes secret
    if "hf_token" in body:
        return await _save_hf_token(body["hf_token"])

    return {"status": "no changes"}


@app.get("/admin/config")
async def admin_get_config(api_key: str = Depends(get_api_key)):
    """Get current configuration including current models."""
    await require_scope("admin", api_key)
    hf_token_set = bool(
        await redis_client.get_value("config:hf_token_saved")
        or await redis_client.get_value("config:hf_token")
    )
    vllm_model = await redis_client.get_value("config:vllm_model")
    llamacpp_model_url = await redis_client.get_value("config:llamacpp_model_url")
    llamacpp_replicas = 0

    # Try to get from Kubernetes ConfigMaps if not in Redis
    try:
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get vLLM model from ConfigMap
        if not vllm_model:
            try:
                vllm_config = await _k8s_call(core_v1.read_namespaced_config_map, "vllm-config", namespace)
                vllm_model = vllm_config.data.get("MODEL_NAME", "Not configured")
            except HTTPException:
                raise  # The API server isn't answering, so don't wait on it again.
            except Exception as e:
                logger.debug(f"Could not read vllm-config: {e}")

        # Get llamacpp model URL from ConfigMap
        if not llamacpp_model_url:
            try:
                llamacpp_config = await _k8s_call(core_v1.read_namespaced_config_map, "llamacpp-config", namespace)
                llamacpp_model_url = llamacpp_config.data.get("MODEL_URL", "Not configured")
            except HTTPException:
                raise  # The API server isn't answering, so don't wait on it again.
            except Exception as e:
                logger.debug(f"Could not read llamacpp-config: {e}")

        # Get llama.cpp replica count
        try:
            deploy = await _k8s_call(apps_v1.read_namespaced_deployment, "llamacpp", namespace)
            llamacpp_replicas = deploy.spec.replicas or 0
        except HTTPException:
            raise  # The API server isn't answering, so don't wait on it again.
        except Exception as e:
            logger.debug(f"Could not get llama.cpp replicas: {e}")

        # Get embedding model URL from ConfigMap
        embedding_model_url = None
        try:
            embedding_config = await _k8s_call(core_v1.read_namespaced_config_map, "embedding-config", namespace)
            embedding_model_url = embedding_config.data.get("MODEL_URL", "Not configured")
        except HTTPException:
            raise  # The API server isn't answering, so don't wait on it again.
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

_GGUF_URL_RE = re.compile(r"https://[A-Za-z0-9.-]+(:443)?/[A-Za-z0-9._~/-]+\.gguf(\?[A-Za-z0-9=&._-]*)?")


def _validate_gguf_model_url(model_url) -> tuple[str, str]:
    """Validate an admin-supplied GGUF URL. Returns (url, model_file).

    The model download sends the HuggingFace token to this URL and fetches it
    from inside the cluster, so it must be HTTPS on an allowlisted host. The
    character set also rules out userinfo tricks and shell metacharacters, and
    the file name is used as a path on the model volume.
    """
    if not isinstance(model_url, str) or not _GGUF_URL_RE.fullmatch(model_url):
        raise HTTPException(status_code=400, detail="model_url must be an https:// URL of a .gguf file")

    parts = urlsplit(model_url)
    if (parts.hostname or "").lower() not in config.GGUF_MODEL_ALLOWED_HOSTS:
        raise HTTPException(
            status_code=400,
            detail=f"model_url host must be one of: {', '.join(sorted(config.GGUF_MODEL_ALLOWED_HOSTS))}",
        )
    if ".." in parts.path.split("/"):
        raise HTTPException(status_code=400, detail="model_url must not contain '..' path segments")
    return model_url, parts.path.rsplit("/", 1)[-1]


def _validate_hf_model_id(model_id: str) -> str:
    model_id = model_id.strip()
    if not model_id:
        raise HTTPException(status_code=400, detail="model_id is required")
    if len(model_id) > 200 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", model_id):
        raise HTTPException(status_code=400, detail="model_id contains unsupported characters")
    if ".." in model_id or "//" in model_id or model_id.endswith("/"):
        raise HTTPException(status_code=400, detail="model_id is not a valid HuggingFace model ID")
    return model_id


def _validate_served_model_name(name: str) -> str:
    name = name.strip().lower()
    if not name or len(name) > 100 or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name):
        raise HTTPException(status_code=400, detail="served_model_name contains unsupported characters")
    return name


def _derive_served_model_name(model_id: str) -> str:
    model_lower = model_id.lower()
    known_names = {
        "qwen/qwen3-14b-awq": "qwen3-14b",
        "qwen/qwen3-8b": "qwen3-8b",
        "cyankiwi/ministral-3-14b-instruct-2512-awq-4bit": "ministral3-14b",
        "meta-llama/llama-3.2-3b-instruct": "llama3.2-3b",
    }
    if model_lower in known_names:
        return known_names[model_lower]

    name = model_id.split("/")[-1].lower()
    for suffix in ("-instruct", "-awq", "-gptq", "-4bit"):
        name = name.replace(suffix, "")
    name = re.sub(r"[^a-z0-9._-]+", "-", name).strip("-")
    return _validate_served_model_name(name)


def _infer_vllm_family_config(model_id: str) -> dict[str, str]:
    model_lower = model_id.lower()
    family_config = {
        "QUANTIZATION": "none",
        "ENABLE_REASONING": "false",
        "REASONING_PARSER": "qwen3",
        "TOKENIZER_MODE": "auto",
        "CONFIG_FORMAT": "auto",
        "LOAD_FORMAT": "auto",
        "TOOL_CALL_PARSER": "none",
        "ENABLE_AUTO_TOOL_CHOICE": "false",
    }
    if "qwen3" in model_lower:
        family_config["ENABLE_REASONING"] = "true"
        if "awq" in model_lower:
            family_config["QUANTIZATION"] = "awq"
    elif "ministral" in model_lower or "mistral" in model_lower:
        family_config.update({
            "QUANTIZATION": "awq" if "awq" in model_lower else "none",
            "TOKENIZER_MODE": "mistral",
            "CONFIG_FORMAT": "mistral",
            "LOAD_FORMAT": "mistral",
            "TOOL_CALL_PARSER": "mistral",
            "ENABLE_AUTO_TOOL_CHOICE": "true",
        })
    elif "llama" in model_lower:
        family_config.update({
            "TOOL_CALL_PARSER": "llama3_json",
            "ENABLE_AUTO_TOOL_CHOICE": "true",
        })
    return family_config


def _validated_int_field(body: dict, field: str, minimum: int, maximum: int) -> Optional[int]:
    if field not in body:
        return None
    try:
        value = int(body[field])
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail=f"{field} must be an integer")
    if not minimum <= value <= maximum:
        raise HTTPException(status_code=400, detail=f"{field} must be between {minimum} and {maximum}")
    return value


def _validated_float_field(body: dict, field: str, minimum: float, maximum: float) -> Optional[float]:
    if field not in body:
        return None
    try:
        value = float(body[field])
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail=f"{field} must be a number")
    if not minimum <= value <= maximum:
        raise HTTPException(status_code=400, detail=f"{field} must be between {minimum} and {maximum}")
    return value


@app.post("/admin/backend/vllm")
async def admin_change_vllm_model(request: Request, api_key: str = Depends(get_api_key)):
    """Change the vLLM model. This triggers a pod restart with new model."""
    await require_scope("admin", api_key)
    body = await request.json()
    model_id = _validate_hf_model_id(str(body.get("model_id", "")))
    served_model_name = body.get("served_model_name")
    if served_model_name:
        served_model_name = _validate_served_model_name(str(served_model_name))
    else:
        served_model_name = _derive_served_model_name(model_id)
    family_config = _infer_vllm_family_config(model_id)

    try:
        # Try to use Kubernetes API
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Update vllm-config ConfigMap with new MODEL_NAME and SERVED_MODEL_NAME
        # This is what the init container reads to download the model
        try:
            configmap = await _k8s_call(core_v1.read_namespaced_config_map, "vllm-config", namespace)
            if configmap.data is None:
                configmap.data = {}
            configmap.data["MODEL_NAME"] = model_id
            configmap.data["SERVED_MODEL_NAME"] = served_model_name
            for key, value in family_config.items():
                configmap.data[key] = value
            await _k8s_call(core_v1.replace_namespaced_config_map, "vllm-config", namespace, configmap)
            logger.info(f"Updated vllm-config ConfigMap: MODEL_NAME={model_id}, SERVED_MODEL_NAME={served_model_name}")
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Failed to update ConfigMap: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to update ConfigMap: {str(e)}")

        # Trigger rollout restart by updating pod template annotation
        # This will cause StatefulSet to recreate pods with new ConfigMap values
        sts = await _k8s_call(apps_v1.read_namespaced_stateful_set, "vllm", namespace)
        if sts.spec.template.metadata.annotations is None:
            sts.spec.template.metadata.annotations = {}
        sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        await _k8s_call(apps_v1.patch_namespaced_stateful_set, "vllm", namespace, sts)

        # Store in Redis for UI
        await redis_client.set_value("config:vllm_model", model_id)

        logger.info(f"vLLM model change initiated: {model_id} (served as {served_model_name})")
        return {"status": "initiated", "model_id": model_id, "served_model_name": served_model_name, "message": "vLLM pod is restarting with new model"}

    except HTTPException:
        raise
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

    model_url, model_file = _validate_gguf_model_url(model_url)

    try:
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Update llamacpp-config ConfigMap with new MODEL_URL and MODEL_FILE
        # This is what the init container reads to download the model
        try:
            configmap = await _k8s_call(core_v1.read_namespaced_config_map, "llamacpp-config", namespace)
            configmap.data["MODEL_URL"] = model_url
            configmap.data["MODEL_FILE"] = model_file
            await _k8s_call(core_v1.replace_namespaced_config_map, "llamacpp-config", namespace, configmap)
            logger.info(f"Updated llamacpp-config ConfigMap: MODEL_URL={model_url}, MODEL_FILE={model_file}")
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Failed to update ConfigMap: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to update ConfigMap: {str(e)}")

        # Trigger rollout restart by updating pod template annotation
        # This will cause Deployment to recreate pods with new ConfigMap values
        deploy = await _k8s_call(apps_v1.read_namespaced_deployment, "llamacpp", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        await _k8s_call(apps_v1.patch_namespaced_deployment, "llamacpp", namespace, deploy)

        # Store in Redis for UI
        await redis_client.set_value("config:llamacpp_model_url", model_url)

        logger.info(f"llama.cpp model change initiated: {model_url} (file: {model_file})")
        return {"status": "initiated", "model_url": model_url, "model_file": model_file, "message": "llama.cpp pod is restarting with new model"}

    except HTTPException:
        raise
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
    config_updates = {}

    max_model_len = _validated_int_field(body, "max_model_len", 1024, 131072)
    if max_model_len is not None:
        config_updates["MAX_MODEL_LEN"] = str(max_model_len)
    gpu_memory_utilization = _validated_float_field(body, "gpu_memory_utilization", 0.10, 0.99)
    if gpu_memory_utilization is not None:
        config_updates["GPU_MEMORY_UTILIZATION"] = str(gpu_memory_utilization)
    max_num_seqs = _validated_int_field(body, "max_num_seqs", 1, 256)
    if max_num_seqs is not None:
        config_updates["MAX_NUM_SEQS"] = str(max_num_seqs)
    max_num_batched_tokens = _validated_int_field(body, "max_num_batched_tokens", 1024, 262144)
    if max_num_batched_tokens is not None:
        config_updates["MAX_NUM_BATCHED_TOKENS"] = str(max_num_batched_tokens)

    if "quantization" in body:
        quantization = str(body["quantization"]).strip().lower()
        if quantization not in {"none", "awq", "gptq"}:
            raise HTTPException(status_code=400, detail="quantization must be one of: none, awq, gptq")
        config_updates["QUANTIZATION"] = quantization
    if "enable_reasoning" in body:
        if not isinstance(body["enable_reasoning"], bool):
            raise HTTPException(status_code=400, detail="enable_reasoning must be a boolean")
        config_updates["ENABLE_REASONING"] = "true" if body["enable_reasoning"] else "false"
    if "reasoning_parser" in body:
        reasoning_parser = str(body["reasoning_parser"]).strip().lower()
        if reasoning_parser not in {"qwen3", "deepseek_r1"}:
            raise HTTPException(status_code=400, detail="reasoning_parser must be one of: qwen3, deepseek_r1")
        config_updates["REASONING_PARSER"] = reasoning_parser

    if not config_updates:
        raise HTTPException(status_code=400, detail="No supported vLLM config fields provided")

    try:
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get current ConfigMap
        cm = await _k8s_call(core_v1.read_namespaced_config_map, "vllm-config", namespace)
        if cm.data is None:
            cm.data = {}

        # Update values
        cm.data.update(config_updates)

        # Apply ConfigMap update
        await _k8s_call(core_v1.patch_namespaced_config_map, "vllm-config", namespace, cm)

        # Trigger rollout restart
        sts = await _k8s_call(apps_v1.read_namespaced_stateful_set, "vllm", namespace)
        if sts.spec.template.metadata.annotations is None:
            sts.spec.template.metadata.annotations = {}
        sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        await _k8s_call(apps_v1.patch_namespaced_stateful_set, "vllm", namespace, sts)

        logger.info(f"vLLM config updated: {config_updates}")
        return {"status": "updated", "config": config_updates, "message": "vLLM pod is restarting with new config"}

    except HTTPException:
        raise
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
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get current ConfigMap
        cm = await _k8s_call(core_v1.read_namespaced_config_map, "llamacpp-config", namespace)

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
        await _k8s_call(core_v1.patch_namespaced_config_map, "llamacpp-config", namespace, cm)

        # Trigger rollout restart
        deploy = await _k8s_call(apps_v1.read_namespaced_deployment, "llamacpp", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        await _k8s_call(apps_v1.patch_namespaced_deployment, "llamacpp", namespace, deploy)

        logger.info(f"llama.cpp config updated: {body}")
        return {"status": "updated", "config": body, "message": "llama.cpp pod is restarting with new config"}

    except HTTPException:
        raise
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
        core_v1, _ = await _k8s_clients()

        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get all nodes and subtract GPU requests from active pods in this namespace.
        nodes = await _k8s_call(core_v1.list_node)
        pods = await _k8s_call(core_v1.list_namespaced_pod, namespace)
        allocated_by_node: dict[str, int] = {}

        for pod in pods.items:
            if pod.status.phase in {"Succeeded", "Failed"} or not pod.spec.node_name:
                continue
            pod_gpu_request = 0
            for container in pod.spec.containers or []:
                resources = container.resources
                requests = resources.requests if resources and resources.requests else {}
                limits = resources.limits if resources and resources.limits else {}
                requested = int(requests.get("nvidia.com/gpu", 0))
                limited = int(limits.get("nvidia.com/gpu", 0))
                pod_gpu_request += max(requested, limited)
            if pod_gpu_request:
                allocated_by_node[pod.spec.node_name] = (
                    allocated_by_node.get(pod.spec.node_name, 0) + pod_gpu_request
                )

        gpu_info = []
        for node in nodes.items:
            node_name = node.metadata.name
            allocatable = node.status.allocatable or {}
            capacity = node.status.capacity or {}

            # Check for NVIDIA GPUs
            gpu_allocatable = int(allocatable.get("nvidia.com/gpu", 0))
            gpu_capacity = int(capacity.get("nvidia.com/gpu", 0))

            if gpu_capacity > 0:
                allocated = allocated_by_node.get(node_name, 0)
                gpu_info.append({
                    "node": node_name,
                    "total": gpu_capacity,
                    "available": max(0, gpu_allocatable - allocated),
                    "allocated": allocated
                })

        return {
            "gpus": gpu_info,
            "total_gpus": sum(g["total"] for g in gpu_info),
            "available_gpus": sum(g["available"] for g in gpu_info)
        }

    except HTTPException:
        raise
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
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get StatefulSet
        sts = await _k8s_call(apps_v1.read_namespaced_stateful_set, "vllm", namespace)
        desired = sts.spec.replicas or 0
        ready = sts.status.ready_replicas or 0

        # Get pod statuses
        pods = await _k8s_call(
            core_v1.list_namespaced_pod,
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

    except HTTPException:
        raise
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
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Check GPU availability
        nodes = await _k8s_call(core_v1.list_node)
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
        await _k8s_call(
            apps_v1.patch_namespaced_stateful_set_scale,
            "vllm",
            namespace,
            {"spec": {"replicas": replicas}}
        )

        # Update gateway config with new vLLM URLs
        if replicas > 0:
            vllm_urls = ",".join([f"http://vllm-{i}.vllm:8000" for i in range(replicas)])
            try:
                cm = await _k8s_call(core_v1.read_namespaced_config_map, "gateway-config", namespace)
                cm.data["VLLM_URLS"] = vllm_urls
                await _k8s_call(core_v1.patch_namespaced_config_map, "gateway-config", namespace, cm)

                # Restart gateway to pick up new URLs
                deploy = await _k8s_call(apps_v1.read_namespaced_deployment, "gateway", namespace)
                if deploy.spec.template.metadata.annotations is None:
                    deploy.spec.template.metadata.annotations = {}
                deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
                await _k8s_call(apps_v1.patch_namespaced_deployment, "gateway", namespace, deploy)
            except Exception as e:
                logger.warning(f"Gateway config update failed (non-critical): {e}")
                # Don't fail the scale operation, but log it

        logger.info(f"vLLM scaled to {replicas} replicas")
        return {
            "status": "scaled",
            "replicas": replicas,
            "message": f"vLLM {'scaling up - pods will initialize in 5-10 minutes' if replicas > 0 else 'scaling down - GPUs will be freed'}"
        }

    except HTTPException:
        raise
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
        _, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Scale the deployment
        await _k8s_call(
            apps_v1.patch_namespaced_deployment_scale,
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

    except HTTPException:
        raise
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

    model_url, model_file = _validate_gguf_model_url(model_url)

    try:
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Update ConfigMap with new model URL
        cm = await _k8s_call(core_v1.read_namespaced_config_map, "embedding-config", namespace)
        cm.data["MODEL_URL"] = model_url
        cm.data["MODEL_FILE"] = model_file
        await _k8s_call(core_v1.patch_namespaced_config_map, "embedding-config", namespace, cm)

        # Trigger rollout restart
        backend_manager.note_embedding_model_change()
        deploy = await _k8s_call(apps_v1.read_namespaced_deployment, "embedding", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        await _k8s_call(apps_v1.patch_namespaced_deployment, "embedding", namespace, deploy)

        # Store in Redis for UI
        await redis_client.set_value("config:embedding_model_url", model_url)

        logger.info(f"Embedding model change initiated: {model_url}")
        return {"status": "initiated", "model_url": model_url, "message": "Embedding pod is restarting with new model"}

    except HTTPException:
        raise
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
        core_v1, apps_v1 = await _k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get current ConfigMap
        cm = await _k8s_call(core_v1.read_namespaced_config_map, "embedding-config", namespace)

        # Update values
        if "context_size" in body:
            cm.data["CONTEXT_SIZE"] = str(body["context_size"])
        if "batch_size" in body:
            cm.data["BATCH_SIZE"] = str(body["batch_size"])
        if "threads" in body:
            cm.data["THREADS"] = str(body["threads"])

        # Apply ConfigMap update
        await _k8s_call(core_v1.patch_namespaced_config_map, "embedding-config", namespace, cm)

        # Trigger rollout restart
        deploy = await _k8s_call(apps_v1.read_namespaced_deployment, "embedding", namespace)
        if deploy.spec.template.metadata.annotations is None:
            deploy.spec.template.metadata.annotations = {}
        deploy.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        await _k8s_call(apps_v1.patch_namespaced_deployment, "embedding", namespace, deploy)

        logger.info(f"Embedding config updated: {body}")
        return {"status": "updated", "config": body, "message": "Embedding pod is restarting with new config"}

    except HTTPException:
        raise
    except ImportError:
        raise HTTPException(status_code=501, detail="Kubernetes client not available")
    except Exception as e:
        logger.error(f"Failed to update embedding config: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
