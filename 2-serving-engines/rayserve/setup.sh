#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== RayServe Baseline Setup ==="

# Check if accelerator type argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <accelerator_type>"
    echo "Example: $0 H100"
    echo "         $0 A100"
    exit 1
fi

ACCELERATOR_TYPE="$1"

# Validate accelerator type (optional - you can add more types as needed)
if [[ "$ACCELERATOR_TYPE" != "H100" && "$ACCELERATOR_TYPE" != "A100" && "$ACCELERATOR_TYPE" != "V100" && "$ACCELERATOR_TYPE" != "T4" ]]; then
    echo "Warning: Accelerator type '$ACCELERATOR_TYPE' is not in the common list (H100, A100, V100, T4)"
    echo "Proceeding anyway..."
fi

# 1. Run comprehensive cleanup of ALL baselines
echo "Running comprehensive cleanup of ALL baselines..."
COMMON_CLEANUP_SCRIPT="$SCRIPT_DIR/../common/cleanup-all-baselines.sh"
if [ -f "$COMMON_CLEANUP_SCRIPT" ]; then
    bash "$COMMON_CLEANUP_SCRIPT"
else
    echo "Error: Common cleanup script not found at $COMMON_CLEANUP_SCRIPT"
    exit 1
fi

# 4. Validate HF_TOKEN
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# 5. Install dependencies
echo "Installing RayServe dependencies..."
pip install ray[serve,llm]==2.47.1 vllm==0.9.1
pip install xgrammar==0.1.19 pynvml==12.0.0 botocore

echo "=== Setup complete. Ready for deployment. ===" 