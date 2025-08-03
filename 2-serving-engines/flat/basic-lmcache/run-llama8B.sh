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

