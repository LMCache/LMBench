#! /bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# This is a raw deployment without kubernetes
# It is used to compare baselines with the following setup:
# 4x Llama 70B 2x TP 

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

# need to be in a virtual environment to even start lmbench
pip install ray[serve,llm]==2.47.1 vllm==0.9.1
pip install xgrammar==0.1.19 pynvml==12.0.0 botocore


# NOTE: rayserve automatically waits until workers are ready

nohup python basic-deployment.py "$ACCELERATOR_TYPE" &