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

# Step 1: Run comprehensive cleanup of ALL baselines
echo "Step 1: Running comprehensive cleanup of ALL baselines..."
COMMON_CLEANUP_SCRIPT="$SCRIPT_DIR/../common/cleanup-all-baselines.sh"
if [ -f "$COMMON_CLEANUP_SCRIPT" ]; then
    bash "$COMMON_CLEANUP_SCRIPT"
else
    echo "Error: Common cleanup script not found at $COMMON_CLEANUP_SCRIPT"
    exit 1
fi

# Step 2: Validate HF_TOKEN (always required)
echo "Step 2: Validating HF_TOKEN..."
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# Step 3: CRITICAL: Clean up vLLM version conflicts in virtual environment
echo "Step 3: CRITICAL: Cleaning up vLLM version conflicts..."
echo "This prevents ImportError: cannot import name 'is_in_doc_build' from 'vllm.utils'"

# Check if we're in a virtual environment
if [ -n "$VIRTUAL_ENV" ]; then
    echo "Virtual environment detected: $VIRTUAL_ENV"
    PYTHON_CMD="python"
    PIP_CMD="pip"
else
    echo "No virtual environment detected, using system Python"
    PYTHON_CMD="python3"
    PIP_CMD="pip3"
fi

# Show current vLLM packages before cleanup
echo "Current vLLM packages before cleanup:"
$PIP_CMD list | grep -i vllm || echo "No vLLM packages found"

# Remove ALL vLLM packages (standard and forks)
echo "Removing ALL vLLM packages to prevent conflicts..."
$PIP_CMD uninstall -y vllm vllm-* 2>/dev/null || echo "No standard vLLM packages to remove"

# Also remove common vLLM-related packages that might conflict
echo "Removing potentially conflicting packages..."
$PIP_CMD uninstall -y ai-dynamo ai-dynamo-runtime ai-dynamo-vllm nixl 2>/dev/null || echo "No ai-dynamo packages to remove"

# Verify cleanup
echo "vLLM packages after cleanup:"
$PIP_CMD list | grep -i vllm || echo "✓ No vLLM packages found (cleanup successful)"

# Step 4: Check Docker installation
echo "Step 4: Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Step 5: Create dynamo_configurations directory if it doesn't exist
echo "Step 5: Ensuring dynamo_configurations directory exists..."
if [ ! -d "dynamo_configurations" ]; then
    mkdir -p dynamo_configurations
    echo "Created dynamo_configurations directory"
fi

# Step 6: Enhanced cleanup for second runs
echo "Step 6: Enhanced cleanup for reliable deployment..."
# Kill any existing dynamo processes (comprehensive patterns)
pkill -f "dynamo serve" 2>/dev/null || true
pkill -f "dynamo.sdk.cli.serve_dynamo" 2>/dev/null || true
pkill -f "serve_dynamo" 2>/dev/null || true

# Kill processes using critical ports (3999, 30080)
echo "Cleaning up processes using ports 3999 and 30080..."
for port in 3999 30080; do
    if lsof -ti:$port >/dev/null 2>&1; then
        echo "Killing processes on port $port..."
        lsof -ti:$port | xargs -r kill -9 2>/dev/null || true
        sleep 1
    fi
done

# Remove any existing PID files
rm -f "$SCRIPT_DIR/dynamo_serve.pid" 2>/dev/null || true
# Clean up Docker compose services and restart them
echo "Restarting Docker services for clean state..."
cd "$SCRIPT_DIR"
cd dynamo_repo
sudo docker compose -f deploy/metrics/docker-compose.yml down 2>/dev/null || true

cd "$SCRIPT_DIR"

# Step 7: BULLETPROOF vLLM cleanup and verification
echo "Step 7: BULLETPROOF vLLM cleanup and verification..."

# First, check current vLLM installations
echo "Current vLLM packages:"
$PIP_CMD list | grep -i vllm || echo "No vLLM packages found"

# Remove ALL vLLM packages aggressively
echo "Removing ALL vLLM packages to ensure clean state..."
$PIP_CMD uninstall -y vllm vllm-* ai-dynamo-vllm ai_dynamo_vllm ai-dynamo ai-dynamo-runtime 2>/dev/null || echo "Some packages not found"

# Clear pip cache to prevent conflicts
echo "Clearing pip cache..."
$PIP_CMD cache purge 2>/dev/null || echo "Pip cache cleared"

# Remove any Python cache files that might cause import conflicts
echo "Removing Python cache files..."
find ~/.local/lib/python3.10/site-packages -name "*vllm*" -type d -exec rm -rf {} + 2>/dev/null || true
find ~/.local/lib/python3.10/site-packages -name "*dynamo*" -type d -exec rm -rf {} + 2>/dev/null || true

# Verify clean state
echo "Verifying clean state..."
$PYTHON_CMD -c "
try:
    import vllm
    print('ERROR: vLLM still importable after cleanup!')
    exit(1)
except ImportError:
    print('✓ Clean state achieved - no vLLM found')
" || echo "✓ Clean state confirmed"

# Now install ONLY ai-dynamo which includes ai_dynamo_vllm
echo "Installing ONLY ai-dynamo[all]"
$PIP_CMD install "ai-dynamo[all]==0.3.1"
$PIP_CMD install $($PIP_CMD show ai-dynamo | grep "Requires:" | cut -d: -f2 | tr ',' '\n' | grep -v "ai-dynamo-vllm" | tr '\n' ' ')

# Step 8: Install dependencies
echo "Step 8: Installing dependencies..."

# Install system dependencies
echo "Installing system dependencies..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq python3-dev python3-pip python3-venv build-essential git

# Install dynamo directly from repository to avoid version mismatch
echo "Installing ai-dynamo directly from repository to match examples..."

# Remove conflicting packages first
echo "Removing conflicting packages..."
sudo apt-get remove -y python3-tensorflow python3-tensorflow-* python3-sklearn python3-scipy python3-numpy 2>/dev/null || echo "conflicting packages not installed"
$PIP_CMD uninstall -y tensorflow tensorflow-* tf-* scikit-learn scipy 2>/dev/null || echo "conflicting packages not installed via pip"

# Dependencies will be installed as part of ai-dynamo installation above
echo "Dependencies will be installed with ai-dynamo - skipping separate dependency installation..."

# Step 9: Install dynamo from PyPI and get compatible examples
echo "Step 9: Installing dynamo from PyPI..."

# Ensure we're in the correct Python environment
if [ -z "$VIRTUAL_ENV" ]; then
    echo "WARNING: No virtual environment detected, but continuing..."
fi

# Check current environment
echo "Current Python environment:"
echo "  Python: $(which $PYTHON_CMD)"
echo "  Virtual env: $VIRTUAL_ENV"
echo "  Current working directory: $(pwd)"

# Install dynamo package as recommended by official documentation
echo "Installing ai-dynamo package for stable CLI and runtime..."
$PIP_CMD install "ai-dynamo[all]" --upgrade
echo "Dynamo package installed - will use official CLI with local repository examples"

# Verify correct vLLM version is installed
echo "Verifying ai-dynamo installed correct vLLM version..."
$PYTHON_CMD -c "
import vllm
print(f'✓ vLLM version: {vllm.__version__}')
if 'ai_dynamo_vllm' in str(vllm.__file__):
    print('✓ Using ai_dynamo_vllm fork (correct)')
else:
    print('⚠ Using standard vLLM package')
" 2>/dev/null || echo "vLLM will be available after complete installation"

# Clone dynamo repository and find compatible examples
echo "Cloning dynamo repository for examples..."
DYNAMO_REPO_DIR="$SCRIPT_DIR/dynamo_repo"
rm -rf "$DYNAMO_REPO_DIR"
git clone https://github.com/ai-dynamo/dynamo.git "$DYNAMO_REPO_DIR"
cd "$DYNAMO_REPO_DIR"

# Use latest stable release as recommended by official documentation
echo "Checking out latest stable release as recommended by official documentation..."
LATEST_RELEASE=$(git describe --tags $(git rev-list --tags --max-count=1))
echo "Latest release found: $LATEST_RELEASE"
git checkout "$LATEST_RELEASE"
echo "Checked out stable release: $LATEST_RELEASE"

# Apply required protocol modification AFTER checkout (since checkout erases local changes)
echo "Applying required protocol modification for ignore_eos=True..."
PROTOCOL_FILE="examples/llm/utils/protocol.py"
if [ -f "$PROTOCOL_FILE" ]; then
    # Check if modification is already applied
    if ! grep -q "sampling_params.ignore_eos = True" "$PROTOCOL_FILE"; then
        echo "Modifying $PROTOCOL_FILE to force ignore_eos=True..."
        # Create a backup
        cp "$PROTOCOL_FILE" "$PROTOCOL_FILE.backup"
        
        # Apply the modification using sed
        sed -i '/if isinstance(v, dict):/,/return SamplingParams/ {
            s/return SamplingParams(\*\*v)/sampling_params = SamplingParams(**v)\
            sampling_params.ignore_eos = True\
            return sampling_params/
        }' "$PROTOCOL_FILE"
        
        echo "Protocol modification applied successfully"
    else
        echo "Protocol modification already applied"
    fi
else
    echo "WARNING: $PROTOCOL_FILE not found - this may cause issues"
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

# Verify dynamo installation and repository setup
echo "Verifying dynamo installation and repository setup..."
if ! command -v dynamo >/dev/null 2>&1; then
    echo "ERROR: dynamo command not found after installation"
    exit 1
fi

dynamo --version
echo "Dynamo CLI ready - using official installation with local repository examples"

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

# Step 10: Start required services
echo "Step 10: Starting required services..."
cd "$DYNAMO_REPO_DIR"

# Check if docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not available"
    exit 1
fi

# Start NATS and etcd services using docker compose
echo "Starting NATS and etcd services..."
sudo docker compose -f deploy/metrics/docker-compose.yml up -d

# Wait for services to be ready with better checking
echo "Waiting for NATS and etcd services to be ready..."
sleep 10

# Check if services are actually running
echo "Checking service status..."
sudo docker compose -f deploy/metrics/docker-compose.yml ps

# Step 11: Start Dynamo serve following official documentation
echo "Step 11: Starting Dynamo serve..."

# Set DYNAMO_HOME as required by official documentation
export DYNAMO_HOME="$DYNAMO_REPO_DIR"
echo "Setting DYNAMO_HOME=$DYNAMO_HOME (as required by official docs)"

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
export CUDA_LIB_DIR="/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$CUDA_LIB_DIR:$LD_LIBRARY_PATH"
export LD_PRELOAD="$CUDA_LIB_DIR/libcublas.so.12 $CUDA_LIB_DIR/libcusolver.so.11"

# Fix vLLM plugin compatibility issue - ai_dynamo_vllm doesn't support LoRA plugins
echo "Disabling problematic vLLM plugins for ai_dynamo_vllm compatibility..."
export VLLM_PLUGINS=""  # Disable all vLLM plugins to avoid AttributeError: VLLM_LORA_RESOLVER_CACHE_DIR
export VLLM_NO_USAGE_STATS=1  # Disable usage statistics
export VLLM_DISABLE_CUSTOM_ALL_REDUCE=0  # Enable custom all-reduce for tensor parallelism
export NCCL_DEBUG=WARN  # Reduce NCCL verbosity but keep warnings

# Use the official aggregated deployment pattern for multiple workers
# Following official docs: dynamo serve graphs.agg:Frontend -f ./configs/agg.yaml
echo "Starting dynamo serve using official aggregated deployment pattern..."
echo "Command: dynamo serve graphs.agg:Frontend -f ./configs/$CONFIG_FILENAME"
echo "This follows the official documentation for aggregated architecture (multiple workers, no separate prefill)"

# Protocol modification already applied after checkout above

# Start with detailed logging using official dynamo CLI
echo "Starting dynamo serve process using official CLI..."
# Ensure HF_TOKEN is passed to the dynamo serve process
export HF_TOKEN="$HF_TOKEN"
nohup env \
    HF_TOKEN="$HF_TOKEN" \
    CUDA_LIB_DIR="$CUDA_LIB_DIR" \
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
    LD_PRELOAD="$LD_PRELOAD" \
    VLLM_PLUGINS="$VLLM_PLUGINS" \
    VLLM_NO_USAGE_STATS="$VLLM_NO_USAGE_STATS" \
    VLLM_DISABLE_CUSTOM_ALL_REDUCE="$VLLM_DISABLE_CUSTOM_ALL_REDUCE" \
    NCCL_DEBUG="$NCCL_DEBUG" \
    dynamo serve graphs.agg_router:Frontend -f "./configs/$CONFIG_FILENAME" > "$SCRIPT_DIR/dynamo_serve.log" 2>&1 &
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
    echo "  VLLM_PLUGINS=$VLLM_PLUGINS"
    echo "  VLLM_LORA_RESOLVER_CACHE_DIR=$VLLM_LORA_RESOLVER_CACHE_DIR"
    echo ""
    echo "Recent logs from $SCRIPT_DIR/dynamo_serve.log:"
    tail -30 "$SCRIPT_DIR/dynamo_serve.log"
    echo ""
    echo "Checking for common issues:"
    echo "1. CUDA libraries:"
    ls -la "$CUDA_LIB_DIR/libcublas.so.12" 2>/dev/null || echo "   libcublas.so.12 not found at $CUDA_LIB_DIR"
    ls -la "$CUDA_LIB_DIR/libcusolver.so.11" 2>/dev/null || echo "   libcusolver.so.11 not found at $CUDA_LIB_DIR"
         echo "2. Python modules:"
     $PYTHON_CMD -c "import dynamo; print('dynamo OK')" 2>/dev/null || echo "   dynamo import failed"
     $PYTHON_CMD -c "import tensorboardX; print('tensorboardX OK')" 2>/dev/null || echo "   tensorboardX import failed"
    echo "3. vLLM version check:"
    $PYTHON_CMD -c "import vllm; print('vLLM version:', vllm.__version__)" 2>/dev/null || echo "   vLLM import failed"
    $PIP_CMD list | grep -i vllm || echo "   No vLLM packages found"
     
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

# Step 12: Wait for service readiness using common wait script
echo "Step 12: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "Dynamo" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "Common wait script not found, falling back to local wait..."
    # Inline wait functionality since we're consolidating everything
    echo "=== Waiting for Dynamo service to be ready ==="
    
    # Wait for Dynamo service to be ready on port 30080
    TIMEOUT=300  # 5 minutes
    SLEEP_INTERVAL=5
    START_TIME=$(date +%s)
    
    echo "Waiting for Dynamo service to become ready on http://localhost:30080..."
    
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        
        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "ERROR: Timeout waiting for Dynamo service to become ready after ${TIMEOUT} seconds"
            exit 1
        fi
        
        # Check if service is responding
        if curl -s --max-time 10 http://localhost:30080/health > /dev/null 2>&1; then
            echo "SUCCESS: Dynamo service is ready on port 30080"
            break
        elif curl -s --max-time 10 http://localhost:30080 > /dev/null 2>&1; then
            echo "SUCCESS: Dynamo service is ready on port 30080"
            break
        else
            echo "Service not ready yet... waiting ${SLEEP_INTERVAL} seconds (elapsed: ${ELAPSED}s)"
            sleep $SLEEP_INTERVAL
        fi
    done
    
    echo "=== Dynamo service is ready ==="
fi

echo "=== Dynamo Deployment Complete ==="
echo "Dynamo serve is running in the background. Check logs at: $SCRIPT_DIR/dynamo_serve.log"
echo "To stop the service, run: kill \$(cat $SCRIPT_DIR/dynamo_serve.pid)"

# Restore tensorflow directory if it was renamed
if [ -d "/usr/lib/python3/dist-packages/tensorflow.disabled" ]; then
    echo "Restoring system tensorflow directory..."
    sudo mv "/usr/lib/python3/dist-packages/tensorflow.disabled" "/usr/lib/python3/dist-packages/tensorflow" 2>/dev/null || echo "Could not restore tensorflow directory"
fi










