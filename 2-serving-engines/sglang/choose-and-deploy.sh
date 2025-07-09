#!/bin/bash
set -e

# Deploy SGLang baseline

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if script name argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <script-name>"
    echo "Example: $0 comparison-baseline.sh"
    echo "Available scripts:"
    ls -1 *.sh 2>/dev/null | grep -v choose-and-deploy.sh | grep -v setup.sh | grep -v wait.sh || echo "  No deployment scripts found"
    exit 1
fi

SCRIPT_NAME="$1"

echo "=== SGLang Baseline Deployment ==="
echo "Script: $SCRIPT_NAME"

# Step 1: Setup - Clean GPU processes, validate HF_TOKEN
echo "Step 1: Running setup..."
bash setup.sh

# Step 2: Deployment - Run specified SGLang deployment script
echo "Step 2: Starting deployment..."

# Validate script exists
if [ ! -f "$SCRIPT_NAME" ]; then
    echo "Error: Deployment script not found: $SCRIPT_NAME"
    exit 1
fi

# Run the deployment script
echo "Running deployment script: $SCRIPT_NAME"
nohup bash "$SCRIPT_NAME" > sglang.log 2>&1 &

echo "SGLang deployment started."

# Step 3: Wait for service readiness using common wait script
echo "Step 3: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "SGLang" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "ERROR: Common wait script not found at $COMMON_WAIT_SCRIPT"
    echo "Falling back to basic wait..."
    bash wait.sh
fi

echo "=== SGLang Deployment Complete ===" 