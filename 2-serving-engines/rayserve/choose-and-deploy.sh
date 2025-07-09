#!/bin/bash
set -e

# Deploy RayServe baseline

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if accelerator type argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <accelerator_type>"
    echo "Example: $0 H100"
    echo "         $0 A100"
    exit 1
fi

ACCELERATOR_TYPE="$1"

echo "=== RayServe Baseline Deployment ==="
echo "Accelerator: $ACCELERATOR_TYPE"

# Step 1: Setup - Clean GPU processes, validate HF_TOKEN
echo "Step 1: Running setup..."
bash setup.sh "$ACCELERATOR_TYPE"

# Step 2: Deployment - Run RayServe deployment
echo "Step 2: Starting deployment..."

# Deploy RayServe using the existing baseline logic
echo "Deploying RayServe baseline..."
nohup python comparison-baseline.py "$ACCELERATOR_TYPE" > rayserve.log 2>&1 &

echo "RayServe deployment started."

# Step 3: Wait for service readiness
echo "Step 3: Waiting for service readiness..."
bash wait.sh

echo "=== RayServe Deployment Complete ===" 