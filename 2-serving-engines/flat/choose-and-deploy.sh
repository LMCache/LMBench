#!/bin/bash
set -e

# Deploy Flat baseline following the standard LMBench pattern

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if configuration script argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <config-script-path>"
    echo "Example: $0 basic-vllm/run-llama8B.sh"
    echo "Available configurations:"
    find . -name "*.sh" -not -name "choose-and-deploy.sh" | sed 's|^\./||' 2>/dev/null || echo "  No configurations found"
    exit 1
fi

CONFIG_SCRIPT="$1"

# Check if the configuration script exists
if [ ! -f "$CONFIG_SCRIPT" ]; then
    echo "Error: Configuration script '$CONFIG_SCRIPT' not found"
    echo "Available configurations:"
    find . -name "*.sh" -not -name "choose-and-deploy.sh" | sed 's|^\./||' 2>/dev/null || echo "  No configurations found"
    exit 1
fi

echo "=== Flat Baseline Deployment ==="
echo "Configuration: $CONFIG_SCRIPT"
echo "Timestamp: $(date)"

# Step 1: Run comprehensive cleanup
echo "Step 1: Running comprehensive cleanup..."
COMMON_CLEANUP_SCRIPT="$SCRIPT_DIR/../common/cleanup-all-baselines.sh"
if [ -f "$COMMON_CLEANUP_SCRIPT" ]; then
    bash "$COMMON_CLEANUP_SCRIPT"
else
    echo "Error: Common cleanup script not found at $COMMON_CLEANUP_SCRIPT"
    exit 1
fi

# Step 2: Validate HF_TOKEN
echo "Step 2: Validating HF_TOKEN..."
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# Step 3: Install dependencies if needed
echo "Step 3: Installing dependencies..."
# For flat baselines, we assume dependencies are already installed
# You can add specific dependency installation here if needed
echo "Dependencies check complete (assuming vllm/lmcache are already installed)"

# Step 4: Deploy the selected configuration
echo "Step 4: Deploying $CONFIG_SCRIPT configuration..."

# Use the provided script path directly
DEPLOY_SCRIPT="$SCRIPT_DIR/$CONFIG_SCRIPT"

# Make the deployment script executable
chmod +x "$DEPLOY_SCRIPT"

echo "Running deployment script: $DEPLOY_SCRIPT"

# Run the deployment script in the background and capture its PID
nohup bash "$DEPLOY_SCRIPT" > flat_serve.log 2>&1 &
SERVE_PID=$!
echo "Started flat serving with PID: $SERVE_PID"
echo $SERVE_PID > flat_serve.pid

# Step 5: Wait for service readiness using common wait script
echo "Step 5: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "Flat-$(basename $CONFIG_SCRIPT .sh)" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "WARNING: Common wait script not found at $COMMON_WAIT_SCRIPT"
    echo "Falling back to basic wait..."
    
    # Fallback: basic readiness check
    echo "Waiting for service to be ready..."
    timeout 300 bash -c 'until curl -s http://localhost:30080/v1/models > /dev/null 2>&1; do echo "Waiting for service..."; sleep 5; done'
    
    if [ $? -eq 0 ]; then
        echo "✅ Flat baseline service is ready!"
        
        # Verify the service is actually responding
        echo "🔍 Verifying service endpoints..."
        curl -s http://localhost:30080/v1/models | jq . || echo "Service running but JSON response may be malformed"
    else
        echo "❌ ERROR: Service failed to become ready within 300 seconds"
        
        # Kill the background process
        if [ -f "flat_serve.pid" ]; then
            kill $(cat flat_serve.pid) 2>/dev/null || true
            rm -f flat_serve.pid
        fi
        
        echo "Recent logs:"
        tail -20 flat_serve.log 2>/dev/null || echo "No logs available"
        exit 1
    fi
fi

echo "=== Flat Baseline Deployment Complete ==="
echo "Service available at: http://localhost:30080"
echo "OpenAI-compatible endpoint: http://localhost:30080/v1/chat/completions"
echo "Models endpoint: http://localhost:30080/v1/models"
echo "Process ID: $(cat flat_serve.pid 2>/dev/null || echo 'Unknown')"
echo "Logs: $SCRIPT_DIR/flat_serve.log" 