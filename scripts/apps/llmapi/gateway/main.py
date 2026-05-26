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
import hashlib
import json
import logging
import os
import re
import time
import weakref
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import AsyncGenerator, Optional

import asyncpg
import httpx
import redis.asyncio as redis
from redis.exceptions import ConnectionError as RedisConnectionError, TimeoutError as RedisTimeoutError
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
        """Execute an async DB function, reconnecting once if the pool is broken.

        If the pool has never been established (postgres was down at startup),
        tries to reconnect first so degraded-mode gateways self-heal.
        """
        for attempt in range(2):
            try:
                if self.pool is None:
                    await self._reconnect()
                # Pool may still be None if all reconnect attempts failed.
                if self.pool is None:
                    raise asyncpg.exceptions.ConnectionDoesNotExistError(
                        "PostgreSQL pool is not available"
                    )
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
                                         tokens_per_day, tokens_per_minute, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
                    ON CONFLICT (api_key)
                    DO UPDATE SET
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
                    SELECT api_key, name, scopes, requests_per_minute, tokens_per_day,
                           tokens_per_minute, created_at
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
                        "tokens_per_minute": row["tokens_per_minute"],
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
                    WHERE u.date >= $1 AND k.revoked = FALSE
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

                    bucket_map[iso]["tokens"] += tokens
                    bucket_map[iso]["requests"] += requests
                    total_tokens += tokens
                    total_requests += requests

                    if api_key not in key_totals:
                        key_totals[api_key] = {
                            "api_key": api_key,
                            "name": row["name"],
                            "api_key_preview": api_key[:16] + "...",
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
                        "api_key_preview": api_key[:16] + "...",
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
        try:
            return await self._execute_with_retry(_query)
        except Exception as e:
            logger.error(f"Error getting all keys stats: {e}")
            return {
                "timezone": "UTC",
                "generated_at": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
                "window_hours": window_hours,
                "summary": {
                    "total_tokens_window": 0,
                    "total_requests_window": 0,
                    "total_tokens_today": 0,
                    "total_requests_today": 0,
                    "active_keys": 0,
                },
                "by_key": [],
                "by_hour": [],
                "by_key_hour": [],
            }


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
            except (RedisConnectionError,
                    RedisTimeoutError,
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

    def _rate_key(self, api_key: str, bucket: Optional[str], metric: str) -> str:
        """Redis rate-limit key. Bucketed keys isolate chat and embeddings quotas."""
        if bucket:
            return f"ratelimit:{api_key}:{bucket}:{metric}"
        return f"ratelimit:{api_key}:{metric}"

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
        key = self._rate_key(api_key, bucket, "rpm")
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

    async def check_tpm_limit(
        self,
        api_key: str,
        estimated_tokens: int,
        tokens_per_minute: int,
        bucket: Optional[str] = None,
    ) -> tuple[bool, int]:
        """Check TPM limit using a sliding 60-second window. Returns (allowed, retry_after_seconds).

        Charges estimated_tokens against the window.  Actual output tokens are
        charged separately after completion via add_tpm_usage().
        Fails OPEN if Redis is unavailable.
        """
        key = self._rate_key(api_key, bucket, "tpm")
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

    async def add_tpm_usage(self, api_key: str, output_tokens: int, bucket: Optional[str] = None) -> None:
        """Charge output tokens to the TPM window after a request completes."""
        key = self._rate_key(api_key, bucket, "tpm")
        async def _fn():
            pipe = self.client.pipeline()
            pipe.incrby(key, output_tokens)
            pipe.expire(key, 60)
            await pipe.execute()
        await self._safe(_fn)

    async def get_rate_limit_info(self, api_key: str, bucket: Optional[str] = None) -> tuple[int, int]:
        """Get current RPM usage and TTL."""
        rpm_key = self._rate_key(api_key, bucket, "rpm")
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
      2. RPM                  (Redis sliding window, fails open on Redis error)
      3. TPM                  (Redis sliding window, fails open on Redis error)

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
            per_key_inflight.setdefault(api_key, {})[bucket] = n
            age = slot.oldest_lease_age(now)
            if age is not None:
                oldest_age.setdefault(api_key, {})[bucket] = int(age)
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
                model_registry.register_model(model_name, "embedding", "ready")
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

    async def stream(
        self,
        lease: Lease,
        endpoint: str,
        data: dict,
    ) -> AsyncGenerator[bytes, None]:
        """Streaming forward. Same ownership contract as `forward`: the caller
        releases the lease (typically in the stream-generator's finally)."""
        slot = lease.slot
        url = slot.meta.get("url")
        backend_type = slot.backend_type
        import json as json_module
        async with self.http_client.stream(
            "POST",
            f"{url}{endpoint}",
            json=data,
            timeout=config.BACKEND_HTTP_TIMEOUT_SECONDS,
        ) as response:
            async for chunk in response.aiter_bytes():
                chunk_str = chunk.decode("utf-8", errors="ignore")
                if chunk_str.startswith("data: ") and not chunk_str.startswith("data: [DONE]"):
                    try:
                        json_str = chunk_str[6:].strip()
                        if json_str:
                            event_data = json_module.loads(json_str)
                            event_data["system_fingerprint"] = f"{backend_type}"
                            chunk = f"data: {json_module.dumps(event_data)}\n\n".encode()
                    except Exception:
                        pass
                yield chunk

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
    except Exception as e:
        logger.error(f"warm_redis_from_postgres: Postgres query failed: {e}")
        return

    if not keys:
        logger.warning("warm_redis_from_postgres: no keys found in Postgres")
        return

    success_count = 0
    for k in keys:
        try:
            config_data = {
                "name": k["name"],
                "scopes": k["scopes"],
                "requests_per_minute": k["requests_per_minute"],
                "tokens_per_day": k["tokens_per_day"],
                "tokens_per_minute": k["tokens_per_minute"],
                "created_at": k["created_at"],
            }
            await redis_client.set_api_key_config(k["key"], config_data)
            success_count += 1
        except Exception as e:
            # Redis failures are expected when Redis is down; fail-open behavior
            logger.debug(f"warm_redis_from_postgres: Redis unavailable for key {k.get('name', 'unknown')}: {e}")

    if success_count > 0:
        logger.info(f"warm_redis_from_postgres: cached {success_count}/{len(keys)} key(s) in Redis")
    else:
        logger.warning(f"warm_redis_from_postgres: Redis unavailable, could not cache {len(keys)} key(s)")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup — Redis first (fast path for auth cache)
    await redis_client.connect()
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
            await warm_redis_from_postgres()

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


def _estimate_message_tokens(messages) -> int:
    """Cheap word-count×1.3 estimate. Tolerant of None content (tool calls)."""
    total = 0.0
    for m in messages:
        content = getattr(m, "content", None)
        if content:
            total += len(content.split()) * 1.3
    return int(total)


@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
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
    start_time = time.time()

    model_info = model_registry.get_model(request.model)
    if not model_info:
        available = [m["id"] for m in model_registry.get_available_models()]
        raise HTTPException(
            status_code=404,
            detail={
                "error": f"Model '{request.model}' is not currently loaded or cached",
                "available_models": available,
                "hint": "Call GET /v1/models to see available models, or POST /admin/models/download to download new ones",
            },
        )
    if model_info.get("lazy_load") and model_info.get("status") == "cached":
        logger.info(f"Lazy-loading cached model: {request.model}")
        success = await backend_manager.load_ollama_model(request.model)
        if not success:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": f"Failed to load model '{request.model}'",
                    "hint": "The model may be too large or Ollama may be unavailable",
                },
            )
        model_info = model_registry.get_model(request.model)

    model = model_info.get("name", request.model)
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

    async with await acquire_request_leases(
        model=model,
        api_key=api_key,
        key_config=key_config,
        endpoint="chat",
        priority=priority,
        estimated_prompt_tokens=estimated_prompt_tokens,
    ) as leases:
        quota_ok = await postgres_client.check_token_quota(api_key, key_config["tokens_per_day"])
        if not quota_ok:
            REQUEST_COUNT.labels(model=model, priority=priority, status="quota_exceeded", endpoint="chat").inc()
            raise HTTPException(status_code=429, detail="Daily token quota exceeded")

        if request.stream:
            bucket = leases.bucket
            backend_info = leases.backend_info
            upstream = backend_manager.stream(leases.backend, "/v1/chat/completions", data)
            # Ownership transfers to the generator — its finally is now the
            # single release point.
            leases.detach()

            async def stream_generator(_request=request, _leases=leases, _upstream=upstream):
                _leases.rebind_to_current_task()
                total_output_tokens = 0
                try:
                    async for chunk in _upstream:
                        # Check if client disconnected - release lease early to free GPU
                        if _request.is_disconnected():
                            logger.warning(f"Client disconnected during streaming, releasing lease early")
                            break
                        yield chunk
                        if b'"content":' in chunk:
                            total_output_tokens += 1
                    input_tokens = sum(
                        len(m.content.split()) for m in request.messages if m.content
                    ) * 2
                    await postgres_client.add_token_usage(api_key, input_tokens, total_output_tokens)
                    TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
                    TOKENS_COUNT.labels(model=model, direction="output").inc(total_output_tokens)
                finally:
                    await _leases.release()

            REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="chat").inc()
            return StreamingResponse(
                stream_generator(),
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
        await postgres_client.add_token_usage(api_key, input_tokens, output_tokens)
        await redis_client.add_tpm_usage(api_key, output_tokens, bucket=leases.bucket)
        TOKENS_COUNT.labels(model=model, direction="input").inc(input_tokens)
        TOKENS_COUNT.labels(model=model, direction="output").inc(output_tokens)

        duration = time.time() - start_time
        REQUEST_DURATION.labels(model=model, priority=priority, endpoint="chat").observe(duration)
        REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="chat").inc()
        return result


@app.post("/v1/completions")
async def completions(
    request: CompletionRequest,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible completions endpoint."""
    start_time = time.time()
    model = config.MODEL_ALIASES.get(request.model, request.model)
    key_config = await _load_key_config(api_key)
    estimated_prompt_tokens = int(len(request.prompt.split()) * 1.3)

    data = {
        "model": model,
        "prompt": request.prompt,
        "temperature": request.temperature,
        "max_tokens": request.max_tokens,
        "stream": request.stream,
    }

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
            upstream = backend_manager.stream(leases.backend, "/v1/completions", data)
            leases.detach()

            async def stream_generator(_leases=leases, _upstream=upstream):
                _leases.rebind_to_current_task()
                try:
                    async for chunk in _upstream:
                        yield chunk
                finally:
                    await _leases.release()

            return StreamingResponse(
                stream_generator(),
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

        duration = time.time() - start_time
        REQUEST_DURATION.labels(model=model, priority=priority, endpoint="completions").observe(duration)
        REQUEST_COUNT.labels(model=model, priority=priority, status="success", endpoint="completions").inc()
        return result


@app.post("/v1/embeddings")
async def embeddings(
    request: EmbeddingRequest,
    api_key: str = Depends(get_api_key),
    priority: str = Depends(get_priority),
):
    """OpenAI-compatible embeddings endpoint - requires 'inference' scope.

    Embeddings live in their own bucket, so concurrency cannot consume vLLM
    slots. We acquire the per-key (embedding) slot first; the backend slot
    is only acquired if there are cache misses that need a real forward."""
    await require_scope("inference", api_key)
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

    async with await rate_limiter.acquire_key_slot(
        api_key, key_config, bucket, "embeddings", model, priority, estimated_prompt_tokens,
    ):
        cache_hits = []
        cache_misses = []
        for i, text in enumerate(input_list):
            cache_key = hashlib.md5(f"{model}:{text}".encode()).hexdigest()
            cached = await redis_client.get_cached_response(cache_key)
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
                for (orig_idx, text), emb_data in zip(cache_misses, result.get("data", [])):
                    cache_key = hashlib.md5(f"{model}:{text}".encode()).hexdigest()
                    await redis_client.cache_response(cache_key, json.dumps(emb_data), ttl=86400)
                    cache_hits.append((orig_idx, emb_data))

        cache_hits.sort(key=lambda x: x[0])
        embeddings_data = [emb for _, emb in cache_hits]

        total_tokens = sum(len(text.split()) * 2 for text in input_list)
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
                    <input type="text" id="model-name" placeholder="Model name (e.g., qwen3:14b, llama3.2:3b, mistral)"
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
                    <button onclick="changeVllmModel()"
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
                    Required for gated models such as Llama. Token is stored securely.
                </p>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                    <input type="password" id="hf-token" name="llmapi-hf-token" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" data-1p-ignore="true" data-lpignore="true" placeholder="hf_xxxxx..."
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
                                <input type="number" id="embedding-batch" value="8192"
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

        // API Key visibility state
        let keysVisible = false;
        let statsCache = null;

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
                    `<option value="${k.api_key}">${k.name} (${k.api_key_preview})</option>`
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
                                <div class="font-medium">${k.name}</div>
                                <code class="text-xs text-gray-400 break-all api-key-display" data-key="${k.key}">${maskKey(k.key)}</code>
                            </div>
                            <div class="flex items-center gap-4 text-sm text-gray-400">
                                <span>${k.requests_per_minute} RPM</span>
                                <span>${(k.tokens_per_minute || 200000).toLocaleString()} TPM</span>
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
                const hours = parseInt(document.getElementById('stats-window-hours')?.value || '96', 10);
                const resp = await adminFetch(`${API_BASE}/admin/stats?hours=${hours}`);
                if (!resp) return; // Auth failure, already redirected
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
                                <div class="font-medium text-sm">${k.name}</div>
                                <code class="text-xs text-gray-500">${k.api_key_preview}</code>
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
    except (TypeError, ValueError):
        raise HTTPException(
            status_code=400,
            detail="requests_per_minute, tokens_per_day, and tokens_per_minute must be integers",
        )

    if requests_per_minute <= 0 or tokens_per_day <= 0 or tokens_per_minute <= 0:
        raise HTTPException(
            status_code=400,
            detail="requests_per_minute, tokens_per_day, and tokens_per_minute must be > 0",
        )

    key_id = secrets.token_hex(16)
    api_key = f"sk-mynodeone-{key_id}"

    key_config = {
        "name": name,
        "scopes": scopes,
        "requests_per_minute": requests_per_minute,
        "tokens_per_day": tokens_per_day,
        "tokens_per_minute": tokens_per_minute,
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
        "api_key": api_key[:20] + "...",
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
    except Exception:
        body = {}

    target_api_key = body.get("api_key") if isinstance(body, dict) else None
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


@app.post("/admin/config")
async def admin_update_config(request: Request, api_key: str = Depends(get_api_key)):
    """Update configuration (e.g., HF token)."""
    await require_scope("admin", api_key)
    body = await request.json()

    # Update HF token in Kubernetes secret
    if "hf_token" in body:
        hf_token = body["hf_token"]

        try:
            import base64

            core_v1, _ = get_k8s_clients()
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
        core_v1, apps_v1 = get_k8s_clients()
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
        core_v1, apps_v1 = get_k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Update vllm-config ConfigMap with new MODEL_NAME and SERVED_MODEL_NAME
        # This is what the init container reads to download the model
        try:
            configmap = core_v1.read_namespaced_config_map("vllm-config", namespace)
            if configmap.data is None:
                configmap.data = {}
            configmap.data["MODEL_NAME"] = model_id
            configmap.data["SERVED_MODEL_NAME"] = served_model_name
            for key, value in family_config.items():
                configmap.data[key] = value
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
        core_v1, apps_v1 = get_k8s_clients()
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
        core_v1, apps_v1 = get_k8s_clients()
        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get current ConfigMap
        cm = core_v1.read_namespaced_config_map("vllm-config", namespace)
        if cm.data is None:
            cm.data = {}

        # Update values
        cm.data.update(config_updates)

        # Apply ConfigMap update
        core_v1.patch_namespaced_config_map("vllm-config", namespace, cm)

        # Trigger rollout restart
        sts = apps_v1.read_namespaced_stateful_set("vllm", namespace)
        if sts.spec.template.metadata.annotations is None:
            sts.spec.template.metadata.annotations = {}
        sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = datetime.utcnow().isoformat()
        apps_v1.patch_namespaced_stateful_set("vllm", namespace, sts)

        logger.info(f"vLLM config updated: {config_updates}")
        return {"status": "updated", "config": config_updates, "message": "vLLM pod is restarting with new config"}

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
        core_v1, apps_v1 = get_k8s_clients()
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
        core_v1, _ = get_k8s_clients()

        namespace = os.getenv("NAMESPACE", "llmapi")

        # Get all nodes and subtract GPU requests from active pods in this namespace.
        nodes = core_v1.list_node()
        pods = core_v1.list_namespaced_pod(namespace)
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
        core_v1, apps_v1 = get_k8s_clients()
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
        core_v1, apps_v1 = get_k8s_clients()
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
        _, apps_v1 = get_k8s_clients()
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
        core_v1, apps_v1 = get_k8s_clients()
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
        core_v1, apps_v1 = get_k8s_clients()
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
