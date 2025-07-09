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

# Step 3: Wait for service readiness
echo "Step 3: Waiting for service readiness..."
bash wait.sh

nohup kubectl port-forward -n llm-d svc/llm-d-inference-gateway-istio 30080:80 &

echo "=== LLM-D Deployment Complete ==="
