#!/bin/bash
#
# ⚠️  DEPRECATED - DO NOT USE
# ===========================
# This script is deprecated as of 2026-01-04.
#
# REASON: Creates flat directory structure incompatible with HuggingFace cache format.
# Models downloaded with aria2c create directories like:
#   /var/lib/llmapi/models/vllm/qwen2.5-14b-awq/
#
# But vLLM init containers expect HuggingFace cache format:
#   /var/lib/llmapi/models/vllm/models--Qwen--Qwen2.5-14B-Instruct-AWQ/
#
# REPLACEMENT:
# ------------
# Models are now downloaded automatically by init containers using huggingface_hub,
# which creates the correct directory structure.
#
# If you need to pre-download models:
#
# 1. Use Python with huggingface_hub:
#    ```python
#    from huggingface_hub import snapshot_download
#    snapshot_download(
#        repo_id='Qwen/Qwen2.5-14B-Instruct-AWQ',
#        cache_dir='/var/lib/llmapi/models/vllm'
#    )
#    ```
#
# 2. Or let the init containers download automatically:
#    - vLLM: Downloads on first pod startup (~3-5 min with hf_transfer)
#    - Models persist on node hostPath and are reused
#
# VERIFICATION:
# -------------
# Check if your models are in correct format:
#   ./scripts/apps/llmapi/verify-model-format.sh
#
# MIGRATION:
# ----------
# If you have flat structure models, delete them and let init containers re-download:
#   sudo rm -rf /var/lib/llmapi/models/vllm/qwen2.5-14b-awq
#   kubectl delete pod -n llmapi vllm-0  # Triggers re-download
#

echo "⚠️  This script is deprecated and should not be used."
echo ""
echo "Models must be in HuggingFace cache format (models--Org--ModelName)."
echo "Use huggingface_hub library or let init containers download automatically."
echo ""
echo "See: scripts/apps/llmapi/DEPRECATED-download-models.sh for details"
exit 1
