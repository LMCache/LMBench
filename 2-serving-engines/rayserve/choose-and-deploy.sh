#!/bin/bash
set -e

# Deploy RayServe baseline

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if script name and accelerator type arguments are provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <script-name> <accelerator_type>"
    echo "Example: $0 comparison-baseline.sh H100"
    echo "         $0 debug-deployment.sh A100"
    echo "Available scripts:"
    ls -1 *.sh *.py 2>/dev/null | grep -v choose-and-deploy.sh | grep -v setup.sh | grep -v wait.sh || echo "  No deployment scripts found"
    exit 1
fi

SCRIPT_NAME="$1"
ACCELERATOR_TYPE="$2"

echo "=== RayServe Baseline Deployment ==="
echo "Script: $SCRIPT_NAME"
echo "Accelerator: $ACCELERATOR_TYPE"

# Step 1: Setup - Clean GPU processes, validate HF_TOKEN
echo "Step 1: Running setup..."
bash setup.sh "$ACCELERATOR_TYPE"

# Step 2: Deployment - Run specified RayServe deployment script
echo "Step 2: Starting deployment..."

# Validate script exists
if [ ! -f "$SCRIPT_NAME" ]; then
    echo "Error: Deployment script not found: $SCRIPT_NAME"
    exit 1
fi

# Run the deployment script with accelerator type
echo "Running deployment script: $SCRIPT_NAME with accelerator: $ACCELERATOR_TYPE"
if [[ "$SCRIPT_NAME" == *.py ]]; then
    nohup python "$SCRIPT_NAME" "$ACCELERATOR_TYPE" > rayserve.log 2>&1 &
else
    nohup bash "$SCRIPT_NAME" "$ACCELERATOR_TYPE" > rayserve.log 2>&1 &
fi

echo "RayServe deployment started."

# Step 3: Wait for service readiness using common wait script
echo "Step 3: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "RayServe" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "ERROR: Common wait script not found at $COMMON_WAIT_SCRIPT"
    echo "Falling back to basic wait..."
    bash wait.sh
fi

echo "=== RayServe Deployment Complete ===" 