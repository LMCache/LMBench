#!/bin/bash
set -e

# Deploy SGLang baseline

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== SGLang Baseline Deployment ==="

# Step 1: Setup - Clean GPU processes, validate HF_TOKEN
echo "Step 1: Running setup..."
bash setup.sh

# Step 2: Deployment - Run SGLang deployment
echo "Step 2: Starting deployment..."

# Deploy SGLang using the existing baseline logic
echo "Deploying SGLang baseline..."
export PATH=/usr/local/cuda/bin:$PATH

# Use the existing model configuration (can be parameterized later)
nohup python -m sglang_router.launch_server \
    --model-path meta-llama/Meta-Llama-3.1-8B-Instruct \
    --dp-size 1 \
    --tp 1 \
    --host 0.0.0.0 \
    --port 30080 > sglang.log 2>&1 &

echo "SGLang deployment started."

# Step 3: Wait for service readiness
echo "Step 3: Waiting for service readiness..."
bash wait.sh

echo "=== SGLang Deployment Complete ===" 