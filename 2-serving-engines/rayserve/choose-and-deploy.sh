#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== RayServe Baseline Deployment ==="

# Check if both script name and accelerator type arguments are provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <python_script_name> <accelerator_type>"
    echo "Example: $0 comparison-baseline.py H100"
    echo "         $0 debug-deployment.py A100"
    echo "Available Python scripts:"
    ls -1 *.py 2>/dev/null || echo "  No Python scripts found"
    exit 1
fi

PYTHON_SCRIPT="$1"
ACCELERATOR_TYPE="$2"

# Validate script exists
if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo "Error: Python script not found: $PYTHON_SCRIPT"
    exit 1
fi

# Validate accelerator type (optional - you can add more types as needed)
if [[ "$ACCELERATOR_TYPE" != "H100" && "$ACCELERATOR_TYPE" != "A100" && "$ACCELERATOR_TYPE" != "V100" && "$ACCELERATOR_TYPE" != "T4" ]]; then
    echo "Warning: Accelerator type '$ACCELERATOR_TYPE' is not in the common list (H100, A100, V100, T4)"
    echo "Proceeding anyway..."
fi

# Step 1: Run comprehensive cleanup of ALL baselines
echo "Step 1: Running comprehensive cleanup of ALL baselines..."
COMMON_CLEANUP_SCRIPT="$SCRIPT_DIR/../common/cleanup-all-baselines.sh"
if [ -f "$COMMON_CLEANUP_SCRIPT" ]; then
    bash "$COMMON_CLEANUP_SCRIPT"
else
    echo "Error: Common cleanup script not found at $COMMON_CLEANUP_SCRIPT"
    exit 1
fi

# Step 2: Clean up environment variables from previous runs
echo "Step 2: Cleaning up environment variables from previous runs..."
unset DYNAMO_SERVING_ENGINE
unset DYNAMO_ENABLE_TORCH_COMPILE
unset DYNAMO_MODEL_NAME
unset DYNAMO_CACHE_SIZE
unset DYNAMO_TENSOR_PARALLEL_SIZE
unset DYNAMO_MAX_SEQ_LEN
unset DYNAMO_BLOCK_SIZE
unset DYNAMO_GPU_MEMORY_UTILIZATION
unset DYNAMO_SWAP_SPACE
unset DYNAMO_ENABLE_CHUNKED_PREFILL
unset DYNAMO_ENABLE_PREFIX_CACHING
unset DYNAMO_QUANTIZATION
unset DYNAMO_TORCH_COMPILE_BACKEND
unset DYNAMO_TORCH_COMPILE_MODE
unset DYNAMO_TORCH_COMPILE_CUSTOM_OPS
unset DYNAMO_TORCH_COMPILE_DISABLE_CUDAGRAPHS
unset DYNAMO_TORCH_COMPILE_MAX_CAPTURE_SIZE
unset DYNAMO_TORCH_COMPILE_CAPTURE_DYNAMIC_SHAPES
unset SGLANG_DISABLE_CACHE
unset SGLANG_ENABLE_FLASHINFER
unset SGLANG_ENABLE_TORCHCOMPILE
unset SGLANG_ENABLE_MIXED_PRECISION
unset SGLANG_ENABLE_FP8_E5M2
unset SGLANG_ENABLE_FP8_E4M3
unset SGLANG_ENABLE_SPECULATIVE_DECODING
unset SGLANG_ENABLE_TRITON_ATTENTION
unset SGLANG_ENABLE_TRITON_FUSED_MLP
unset SGLANG_ENABLE_TRITON_LAYERNORM
unset SGLANG_ENABLE_TRITON_QUANTIZATION
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS_FAST
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS_SAFE
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS_UNSAFE

# Step 3: Validate HF_TOKEN environment variable
echo "Step 3: Validating HF_TOKEN..."
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# Step 4: Install dependencies - use the working combination
echo "Step 4: Installing RayServe dependencies..."
python -m venv ray_venv
source ray_venv/bin/activate
echo "Activated RayServe environment"
pip install ray[serve,llm]==2.47.0 vllm==0.9.1 
pip install xgrammar==0.1.19 pynvml==12.0.0 botocore==1.39.4

# Step 6: Verify vLLM installation
echo "Step 6: Verifying vLLM installation..."
python -c "import vllm; print(f'vLLM version: {vllm.__version__}')" || {
    echo "ERROR: vLLM installation verification failed"
    exit 1
}

# Step 7: Start RayServe deployment
echo "Step 7: Starting RayServe deployment..."
echo "Working directory: $(pwd)"
echo "Python script: $PYTHON_SCRIPT"
echo "Accelerator type: $ACCELERATOR_TYPE"

# ONLY redirect the Python process output to rayserve.log
echo "Starting RayServe deployment..."
nohup python "$PYTHON_SCRIPT" "$ACCELERATOR_TYPE" > rayserve.log 2>&1 &

# Save the PID for monitoring
echo $! > rayserve.pid

# Step 8: Wait for service readiness using common wait script
echo "Step 8: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "RayServe" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "Common wait script not found, falling back to local wait.sh..."
    if [ -f wait.sh ]; then
        bash wait.sh
    else
        echo "ERROR: No wait script found"
        exit 1
    fi
fi

echo "=== RayServe Deployment Complete ===" 