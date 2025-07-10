#!/bin/bash
set -e

# Deploy LLM-D to a local minikube Cluster 

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if configuration file argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <config-file-name>"
    echo "Example: $0 comparison-baseline.yaml"
    echo "Available configurations:"
    ls -1 llmd_configurations/ 2>/dev/null || echo "  No configurations found in llmd_configurations/"
    exit 1
fi

CONFIG_FILE="$1"

echo "=== LLM-D Baseline Deployment ==="
echo "Configuration: $CONFIG_FILE"

# Step 1: Setup - Clean GPU processes, K8s environment, validate HF_TOKEN
echo "Step 1: Running setup..."
bash setup.sh "$CONFIG_FILE"

# Step 2: Deployment - Run the original deployment logic
echo "Step 2: Starting deployment..."

# Determine OS and architecture
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64) ARCH="amd64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Helper: install via package manager or brew if available
install_pkg() {
  PKG="$1"
  if [[ "$OS" == "linux" ]]; then
    if command -v apt &> /dev/null; then
      sudo apt-get install -y "$PKG"
    elif command -v dnf &> /dev/null; then
      sudo dnf install -y "$PKG"
    elif command -v yum &> /dev/null; then
      sudo yum install -y "$PKG"
    else
      echo "Unsupported Linux distro (no apt, dnf, or yum).";
      exit 1
    fi
  elif [[ "$OS" == "darwin" ]]; then
    if command -v brew &> /dev/null; then
      brew install "$PKG"
    else
      echo "Homebrew not found. Please install Homebrew or add manual install logic.";
      exit 1
    fi
  else
    echo "Unsupported OS: $OS";
    exit 1
  fi
}

# Install base utilities
for pkg in git jq make curl tar wget; do
  if ! command -v "$pkg" &> /dev/null; then
    install_pkg "$pkg"
  fi
done

# Install yq (v4+)
if ! command -v yq &> /dev/null; then
  echo "Installing yq..."
  if [[ "$OS" == "linux" ]]; then
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}
  else  # macOS
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_darwin_${ARCH}
  fi
  sudo chmod +x /usr/local/bin/yq
fi

# Install kustomize
if ! command -v kustomize &> /dev/null; then
  echo "Installing Kustomize..."
  KUSTOMIZE_TAG=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | jq -r '.tag_name')
  VERSION_NUM=${KUSTOMIZE_TAG#kustomize/}
  ARCHIVE="kustomize_${VERSION_NUM}_${OS}_${ARCH}.tar.gz"
  curl -sLo kustomize.tar.gz \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/${KUSTOMIZE_TAG}/${ARCHIVE}"
  tar -xzf kustomize.tar.gz
  sudo mv kustomize /usr/local/bin/
  rm kustomize.tar.gz
fi

# Copy configuration file to examples directory
kubectl config set-context --current --namespace=llm-d
echo "Copying configuration file to examples directory..."
cp "llmd_configurations/$CONFIG_FILE" "llm-d-deployer/quickstart/examples/"

# Change to quickstart directory and run the installer
echo "Deploying with configuration: $CONFIG_FILE"
cd llm-d-deployer/quickstart
bash llmd-installer.sh --minikube --values-file "examples/$CONFIG_FILE"

# Return to script directory
cd "$SCRIPT_DIR"

# Step 3: Set up port forwarding before waiting for service readiness
echo "Step 3: Setting up port forwarding..."

# Clean up any existing port forwarding on port 30080
echo "Cleaning up any existing port forwarding on port 30080..."
pkill -f "kubectl port-forward.*30080" || true

# Wait for cleanup to complete
sleep 2

# Start port forwarding with proper error handling
echo "Starting port forwarding: llm-d-inference-gateway-istio:80 -> localhost:30080"
kubectl port-forward -n llm-d svc/llm-d-inference-gateway-istio 30080:80 > /tmp/llm-d-port-forward.log 2>&1 &
PORT_FORWARD_PID=$!

# Verify port forwarding started successfully
sleep 5
if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
    echo "ERROR: Port forwarding failed to start. Check logs:"
    cat /tmp/llm-d-port-forward.log
    exit 1
fi

# Test that port forwarding is working
echo "Verifying port forwarding is working..."
RETRY_COUNT=0
MAX_RETRIES=6
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -m 5 localhost:30080 > /dev/null 2>&1; then
        echo "Port forwarding is working!"
        break
    else
        echo "Port forwarding not ready yet, waiting... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
        sleep 5
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "ERROR: Port forwarding failed to become accessible after $MAX_RETRIES attempts"
    echo "Port forwarding process status:"
    if kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        echo "  Port forwarding process is still running (PID: $PORT_FORWARD_PID)"
    else
        echo "  Port forwarding process has died"
    fi
    echo "Port forwarding logs:"
    cat /tmp/llm-d-port-forward.log
    exit 1
fi

# Step 4: Wait for service readiness using common wait script
echo "Step 4: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "LLM-D" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "ERROR: Common wait script not found at $COMMON_WAIT_SCRIPT"
    echo "Falling back to basic wait..."
    bash wait.sh
fi

echo "=== LLM-D Deployment Complete ==="
echo "Port forwarding is running in background (PID: $PORT_FORWARD_PID)"
echo "Service is accessible at: http://localhost:30080"
