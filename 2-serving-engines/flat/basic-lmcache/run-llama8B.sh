#!/bin/bash

# Check if vllm command is available
if ! command -v vllm &> /dev/null; then
    echo "ERROR: vllm command not found in PATH" >&2
    echo "Please ensure vLLM is installed and accessible:" >&2
    echo "  pip install vllm" >&2
    echo "Or activate the appropriate virtual environment" >&2
    echo "Current PATH: $PATH" >&2
    echo "Python location: $(which python3 2>/dev/null || echo 'not found')" >&2
    exit 1
fi

echo "Starting vLLM serve with LMCache integration on port 30080..."
echo "vLLM location: $(which vllm)"

LMCACHE_CHUNK_SIZE=256 \
LMCACHE_LOCAL_CPU=True \
LMCACHE_MAX_LOCAL_CPU_SIZE=60.0 \
LMCACHE_USE_EXPERIMENTAL=True \
vllm serve \
    meta-llama/Llama-3.1-8B-Instruct \
    --max-model-len 32000 \
    --port 30080 \
    --kv-transfer-config \
    '{"kv_connector":"LMCacheConnectorV1", "kv_role":"kv_both"}'
