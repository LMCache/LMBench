#!/bin/bash
set -e

# Deploy Dynamo following official documentation pattern

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if configuration file argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <config-file-name>"
    echo "Example: $0 debug-baseline.yaml"
    echo "Available configurations:"
    ls -1 dynamo_configurations/ 2>/dev/null || echo "  No configurations found in dynamo_configurations/"
    exit 1
fi

CONFIG_FILE="$1"

echo "=== Dynamo Deployment (Following Official Documentation) ==="
echo "Configuration: $CONFIG_FILE"
echo "Timestamp: $(date)"

# Step 1: Run comprehensive cleanup
echo "Step 1: Running comprehensive cleanup..."
COMMON_CLEANUP_SCRIPT="$SCRIPT_DIR/../common/cleanup-all-baselines.sh"
if [ -f "$COMMON_CLEANUP_SCRIPT" ]; then
    bash "$COMMON_CLEANUP_SCRIPT"
else
    echo "Error: Common cleanup script not found"
    exit 1
fi

# Step 2: Validate HF_TOKEN
echo "Step 2: Validating HF_TOKEN..."
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# Step 3: Install system packages (following official docs)
echo "Step 3: Installing system packages..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq python3-dev python3-pip python3-venv libucx0 jq curl

# Step 4: Set up Python environment (following official docs)
echo "Step 4: Setting up Python environment..."
if [ ! -d "dynamo_venv" ]; then
    python3 -m venv dynamo_venv
fi
source dynamo_venv/bin/activate

# Step 5: Install Dynamo (following official docs)
echo "Step 5: Installing Dynamo..."
pip install "ai-dynamo[all]"

# Step 6: Clone repository for examples (following official docs)
echo "Step 6: Getting Dynamo examples..."
# Clean up any files created by previous Docker runs (may have root ownership)
if [ -d "dynamo" ]; then
    echo "Removing existing dynamo directory (may require sudo due to Docker file ownership)..."
    sudo rm -rf dynamo
fi
# Also clean up any temporary docker configs from previous runs
if [ -d "docker_configs" ]; then
    echo "Removing temporary docker_configs directory..."
    sudo rm -rf docker_configs
fi
git clone https://github.com/ai-dynamo/dynamo.git
DYNAMO_REPO_DIR="$SCRIPT_DIR/dynamo"
cd "$DYNAMO_REPO_DIR"
git checkout $(git describe --tags $(git rev-list --tags --max-count=1))
echo "Using Dynamo version: $(git describe --tags)"

# Step 7: Start required services (following official docs)
echo "Step 7: Starting required services (etcd and NATS)..."
sudo docker compose -f deploy/metrics/docker-compose.yml down 2>/dev/null || true
sudo docker compose -f deploy/metrics/docker-compose.yml up -d

# Wait for services
echo "Waiting for services to be ready..."
sleep 10
sudo docker compose -f deploy/metrics/docker-compose.yml ps

# Step 8: Validate configuration
echo "Step 8: Validating configuration..."
CONFIG_FILENAME=$(basename "$CONFIG_FILE")
DYNAMO_CONFIG_FILE="$SCRIPT_DIR/dynamo_configurations/$CONFIG_FILE"

if [ ! -f "$DYNAMO_CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $DYNAMO_CONFIG_FILE"
    echo "Available configurations:"
    ls -la "$SCRIPT_DIR/dynamo_configurations/" || echo "No configurations found"
    exit 1
fi

echo "Using configuration: $DYNAMO_CONFIG_FILE"
echo "Configuration contents:"
cat "$DYNAMO_CONFIG_FILE"

# Step 9: Copy configuration to examples directory
echo "Step 9: Setting up configuration..."
cd "$DYNAMO_REPO_DIR/examples/llm"
cp "$DYNAMO_CONFIG_FILE" "configs/$CONFIG_FILENAME"

# Step 10: Set DYNAMO_HOME and start dynamo serve (following official docs)
echo "Step 10: Starting Dynamo serve..."
export DYNAMO_HOME="$DYNAMO_REPO_DIR"
export HF_TOKEN="$HF_TOKEN"

echo "Starting dynamo serve with:"
echo "  DYNAMO_HOME=$DYNAMO_HOME"
echo "  Working directory: $(pwd)"
echo "  Command: dynamo serve graphs.agg_router:Frontend -f ./configs/$CONFIG_FILENAME"

# Start dynamo serve in background (following official docs pattern)
nohup dynamo serve graphs.agg_router:Frontend -f "./configs/$CONFIG_FILENAME" > "$SCRIPT_DIR/dynamo_serve.log" 2>&1 &
DYNAMO_PID=$!

# Store PID for cleanup
echo $DYNAMO_PID > "$SCRIPT_DIR/dynamo_serve.pid"
echo "Dynamo serve started with PID: $DYNAMO_PID"

# Step 11: Wait for service readiness
echo "Step 11: Waiting for service readiness..."
sleep 5

# Check if process is running
if ! kill -0 $DYNAMO_PID 2>/dev/null; then
    echo "ERROR: Dynamo serve process failed to start"
    echo "Recent logs:"
    tail -30 "$SCRIPT_DIR/dynamo_serve.log" 2>/dev/null || echo "No log file"
    exit 1
fi

echo "Process running, waiting for service to be ready on port 30080..."
TIMEOUT=600  # 10 minutes (model loading can take time)
SLEEP_INTERVAL=10
START_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: Timeout waiting for service after ${TIMEOUT} seconds"
        echo "Process status: $(kill -0 $DYNAMO_PID 2>/dev/null && echo "running" || echo "stopped")"
        echo "Recent logs:"
        tail -50 "$SCRIPT_DIR/dynamo_serve.log"
        exit 1
    fi
    
    # Check if service is responding and can handle requests
    # First check if models endpoint responds
    if curl -s --max-time 10 http://localhost:30080/v1/models > /dev/null 2>&1; then
        # Models endpoint responding, now test actual completion
        echo "Models endpoint responding, testing completion..."
        # Get the served model name from config or use first available model
        MODEL_NAME=$(curl -s http://localhost:30080/v1/models 2>/dev/null | jq -r '.data[0].id' 2>/dev/null || echo "")
        if [ -z "$MODEL_NAME" ]; then
            # Fallback: extract from config file
            MODEL_NAME=$(grep "served_model_name:" "$DYNAMO_CONFIG_FILE" | head -1 | sed 's/.*served_model_name: *//' | sed 's/ *$//')
        fi
        echo "Testing with model: $MODEL_NAME"
        if curl -s --max-time 30 -H "Content-Type: application/json" \
           -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"max_tokens\":1}" \
           http://localhost:30080/v1/chat/completions > /dev/null 2>&1; then
            echo "SUCCESS: Dynamo service is ready on port 30080 (completion test passed)"
            break
        else
            echo "Models endpoint ready but completion test failed, model still loading..."
        fi
    elif curl -s --max-time 10 http://localhost:30080/health > /dev/null 2>&1; then
        echo "Service responding on /health but /v1/models not ready yet..."
    elif curl -s --max-time 10 http://localhost:30080 > /dev/null 2>&1; then
        echo "Service responding on port 30080 but not ready yet..."
    else
        echo "Service not ready yet... waiting ${SLEEP_INTERVAL}s (elapsed: ${ELAPSED}s)"
        # Check if process is still running
        if ! kill -0 $DYNAMO_PID 2>/dev/null; then
            echo "ERROR: Dynamo process died during startup"
            echo "Recent logs:"
            tail -30 "$SCRIPT_DIR/dynamo_serve.log"
            exit 1
        fi
        sleep $SLEEP_INTERVAL
    fi
done

echo "=== Dynamo Deployment Complete ==="
echo "Dynamo serve is running with PID: $DYNAMO_PID"
echo "Service available at: http://localhost:30080"
echo "Logs: $SCRIPT_DIR/dynamo_serve.log"
echo "To stop: kill $DYNAMO_PID"
echo "PID stored in: $SCRIPT_DIR/dynamo_serve.pid"










