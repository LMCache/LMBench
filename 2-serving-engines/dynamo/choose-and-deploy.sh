#!/bin/bash
set -e

# Deploy Dynamo for Local-Flat deployment

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

echo "=== Dynamo Baseline Deployment ==="
echo "Configuration: $CONFIG_FILE"
echo "Timestamp: $(date)"

# Step 1: Setup - Clean environment, validate HF_TOKEN
echo "Step 1: Running setup..."
bash setup.sh

# Step 2: Install dependencies
echo "Step 2: Installing dependencies..."

# Install system dependencies
echo "Installing system dependencies..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq python3-dev python3-pip python3-venv build-essential git

# Install dynamo directly from repository to avoid version mismatch
echo "Installing ai-dynamo directly from repository to match examples..."

# Remove conflicting packages first
echo "Removing conflicting packages..."
sudo apt-get remove -y python3-tensorflow python3-tensorflow-* python3-sklearn python3-scipy python3-numpy 2>/dev/null || echo "conflicting packages not installed"
pip uninstall -y tensorflow tensorflow-* tf-* scikit-learn scipy 2>/dev/null || echo "conflicting packages not installed via pip"

# Install compatible base dependencies
echo "Installing compatible dependencies..."
pip install 'scipy>=1.10.0'  # Compatible scipy version
pip install 'scikit-learn>=1.3.0'  # Compatible scikit-learn version
pip install tensorboardX
pip install 'torch>=2.1.0' 'torchvision>=0.16.0' 'torchaudio>=2.1.0'

# Remove any existing ai-dynamo installations
pip uninstall -y ai-dynamo ai-dynamo-runtime ai-dynamo-vllm nixl 2>/dev/null || echo "ai-dynamo not installed"

# Install other required dependencies
pip install vllm pydantic fastapi uvicorn jinja2 aiohttp prometheus-client

# Step 3: Install dynamo from PyPI and get compatible examples
echo "Step 3: Installing dynamo from PyPI..."

# Install the latest dynamo package from PyPI
echo "Installing ai-dynamo from PyPI..."
pip install "ai-dynamo[all]" --upgrade

# Clone dynamo repository and find compatible examples
echo "Cloning dynamo repository for examples..."
DYNAMO_REPO_DIR="$SCRIPT_DIR/dynamo_repo"
rm -rf "$DYNAMO_REPO_DIR"
git clone https://github.com/ai-dynamo/dynamo.git "$DYNAMO_REPO_DIR"
cd "$DYNAMO_REPO_DIR"

# Try to find a compatible version by checking recent tags
echo "Looking for compatible version..."
git tag -l | tail -10
echo "Checking out latest stable version..."
LATEST_TAG=$(git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
if [ -n "$LATEST_TAG" ]; then
    echo "Found tag: $LATEST_TAG, checking it out..."
    git checkout "$LATEST_TAG"
else
    echo "No stable version tag found, using main branch"
fi

# Return to script directory
cd "$SCRIPT_DIR"

# Set comprehensive environment to avoid tensorflow conflicts
export TRANSFORMERS_NO_TF=1
export TF_CPP_MIN_LOG_LEVEL=3
export TF_FORCE_GPU_ALLOW_GROWTH=true  
export DISABLE_TENSORFLOW=1
export USE_TENSORFLOW=0
# Temporarily rename system tensorflow to prevent import
TF_SYSTEM_PATH="/usr/lib/python3/dist-packages/tensorflow"
if [ -d "$TF_SYSTEM_PATH" ]; then
    echo "Temporarily renaming system tensorflow directory to prevent conflicts..."
    sudo mv "$TF_SYSTEM_PATH" "${TF_SYSTEM_PATH}.disabled" 2>/dev/null || echo "Could not rename tensorflow directory"
fi
echo "Set comprehensive TensorFlow avoidance environment variables"

# Verify dynamo installation
echo "Verifying dynamo installation..."
if ! command -v dynamo >/dev/null 2>&1; then
    echo "ERROR: dynamo command not found after installation"
    echo "Trying to reinstall dynamo..."
    pip install "ai-dynamo[all]" --upgrade --force-reinstall
fi

dynamo --version || echo "Could not get dynamo version"

# Set the path to the dynamo configurations directory  
DYNAMO_CONFIG_DIR="$SCRIPT_DIR/dynamo_configurations"
DYNAMO_CONFIG_FILE="$DYNAMO_CONFIG_DIR/$CONFIG_FILE"

# Validate configuration file exists
if [ ! -f "$DYNAMO_CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $DYNAMO_CONFIG_FILE"
    echo "Available configurations:"
    ls -la "$DYNAMO_CONFIG_DIR" || echo "No configurations directory found at $DYNAMO_CONFIG_DIR"
    exit 1
fi

echo "Using configuration file: $DYNAMO_CONFIG_FILE"
echo "Configuration contents:"
cat "$DYNAMO_CONFIG_FILE"

# Step 4: Start required services
echo "Step 4: Starting required services..."
cd "$DYNAMO_REPO_DIR"

# Check if docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not available"
    exit 1
fi

# Start NATS and etcd services using docker compose
echo "Starting NATS and etcd services..."
docker compose -f deploy/metrics/docker-compose.yml up -d

# Wait for services to be ready with better checking
echo "Waiting for NATS and etcd services to be ready..."
sleep 10

# Check if services are actually running
echo "Checking service status..."
docker compose -f deploy/metrics/docker-compose.yml ps

# Step 5: Start Dynamo serve following official documentation
echo "Step 5: Starting Dynamo serve..."

# Set DYNAMO_HOME as required for non-dockerized deployment
export DYNAMO_HOME="$DYNAMO_REPO_DIR"
echo "Setting DYNAMO_HOME=$DYNAMO_HOME"

cd "$DYNAMO_HOME/examples/llm"

# Copy our configuration file to the configs directory, replacing the existing one
echo "Copying configuration to dynamo configs directory..."
cp "$DYNAMO_CONFIG_FILE" configs/

# Extract the filename without path for use in dynamo serve
CONFIG_FILENAME=$(basename "$CONFIG_FILE")

# Validate deployment structure
echo "Validating deployment structure..."
echo "Working directory: $(pwd)"
echo "DYNAMO_HOME: $DYNAMO_HOME"
echo "Available graphs:"
ls -la graphs/ || echo "No graphs directory found"
echo "Available configs:"
ls -la configs/ || echo "No configs directory found"
echo "Configuration file contents:"
cat "configs/$CONFIG_FILENAME"

# Check if the disaggregated graph module exists
if [ ! -f "graphs/disagg.py" ]; then
    echo "ERROR: graphs/disagg.py module not found in $(pwd)"
    echo "Available files in graphs directory:"
    ls -la graphs/
    exit 1
fi

# Set up environment for CUDA libraries (from user's fixes)
echo "Setting up CUDA environment..."
export CUDA_LIB_DIR="/usr/local/cuda/lib64"
export LD_LIBRARY_PATH="$CUDA_LIB_DIR:$LD_LIBRARY_PATH"
export LD_PRELOAD="$CUDA_LIB_DIR/libcublas.so.12 $CUDA_LIB_DIR/libcusolver.so.11"

# Use the disaggregated deployment pattern from team documentation
# Following: dynamo serve graphs.disagg:Frontend -f ./configs/disagg.yaml
echo "Starting dynamo serve using disaggregated deployment pattern..."
echo "Command: dynamo serve graphs.disagg:Frontend -f ./configs/$CONFIG_FILENAME"
echo "This follows the team documentation for disaggregated deployment"

# Apply required protocol modification from team documentation
echo "Applying required protocol modification for ignore_eos=True..."
if [ -f "utils/protocol.py" ]; then
    # Check if modification is already applied
    if ! grep -q "v.ignore_eos = True" utils/protocol.py; then
        echo "Modifying utils/protocol.py to force ignore_eos=True..."
        # Create a backup
        cp utils/protocol.py utils/protocol.py.backup
        
        # Apply the modification using sed
        sed -i '/if isinstance(v, dict):/a\        v.ignore_eos = True' utils/protocol.py
        
        echo "Protocol modification applied successfully"
    else
        echo "Protocol modification already applied"
    fi
else
    echo "WARNING: utils/protocol.py not found - this may cause issues"
fi

# Start with detailed logging
echo "Starting dynamo serve process..."
nohup dynamo serve graphs.disagg:Frontend -f "./configs/$CONFIG_FILENAME" > "$SCRIPT_DIR/dynamo_serve.log" 2>&1 &
DYNAMO_PID=$!

# Store the PID for cleanup
echo $DYNAMO_PID > "$SCRIPT_DIR/dynamo_serve.pid"

echo "Dynamo serve started with PID: $DYNAMO_PID"

# Monitor process startup with better diagnostics
echo "Monitoring dynamo serve startup..."
sleep 2

# Check initial startup
if ! kill -0 $DYNAMO_PID 2>/dev/null; then
    echo "ERROR: Dynamo serve process failed to start or died immediately"
    echo "Recent logs from $SCRIPT_DIR/dynamo_serve.log:"
    tail -30 "$SCRIPT_DIR/dynamo_serve.log" 2>/dev/null || echo "No log file created"
    exit 1
fi

echo "Process started successfully (PID: $DYNAMO_PID), waiting for initialization..."
sleep 8

# Check if process is still running after initialization
if ! kill -0 $DYNAMO_PID 2>/dev/null; then
    echo "ERROR: Dynamo serve process died during initialization"
    echo "This usually indicates a configuration, dependency, or CUDA library issue"
    echo "Environment variables set:"
    echo "  DYNAMO_HOME=$DYNAMO_HOME"
    echo "  TRANSFORMERS_NO_TF=$TRANSFORMERS_NO_TF"
    echo "  CUDA_LIB_DIR=$CUDA_LIB_DIR"
    echo "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "  LD_PRELOAD=$LD_PRELOAD"
    echo ""
    echo "Recent logs from $SCRIPT_DIR/dynamo_serve.log:"
    tail -30 "$SCRIPT_DIR/dynamo_serve.log"
    echo ""
    echo "Checking for common issues:"
    echo "1. CUDA libraries:"
    ls -la /usr/local/cuda/lib64/libcublas.so.12 2>/dev/null || echo "   libcublas.so.12 not found"
    ls -la /usr/local/cuda/lib64/libcusolver.so.11 2>/dev/null || echo "   libcusolver.so.11 not found"
         echo "2. Python modules:"
     python3 -c "import dynamo; print('dynamo OK')" 2>/dev/null || echo "   dynamo import failed"
     python3 -c "import tensorboardX; print('tensorboardX OK')" 2>/dev/null || echo "   tensorboardX import failed"
     
     # Restore tensorflow directory if it was renamed
     if [ -d "/usr/lib/python3/dist-packages/tensorflow.disabled" ]; then
         echo "Restoring system tensorflow directory..."
         sudo mv "/usr/lib/python3/dist-packages/tensorflow.disabled" "/usr/lib/python3/dist-packages/tensorflow" 2>/dev/null || echo "Could not restore tensorflow directory"
     fi
     exit 1
fi

echo "Dynamo serve process is running successfully (PID: $DYNAMO_PID)"
echo "Logs are being written to: $SCRIPT_DIR/dynamo_serve.log"
echo "Initial startup complete, service should be initializing..."

# Return to script directory
cd "$SCRIPT_DIR"

# Step 6: Wait for service readiness using common wait script
echo "Step 6: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "Dynamo" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "ERROR: Common wait script not found at $COMMON_WAIT_SCRIPT"
    echo "Falling back to basic wait..."
    bash wait.sh
fi

echo "=== Dynamo Deployment Complete ==="
echo "Dynamo serve is running in the background. Check logs at: $SCRIPT_DIR/dynamo_serve.log"
echo "To stop the service, run: kill \$(cat $SCRIPT_DIR/dynamo_serve.pid)"

# Restore tensorflow directory if it was renamed
if [ -d "/usr/lib/python3/dist-packages/tensorflow.disabled" ]; then
    echo "Restoring system tensorflow directory..."
    sudo mv "/usr/lib/python3/dist-packages/tensorflow.disabled" "/usr/lib/python3/dist-packages/tensorflow" 2>/dev/null || echo "Could not restore tensorflow directory"
fi










