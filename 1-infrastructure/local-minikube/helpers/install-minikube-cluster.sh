#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Allow users to override the paths for the NVIDIA tools.
: "${NVIDIA_SMI_PATH:=nvidia-smi}"
: "${NVIDIA_CTK_PATH:=nvidia-ctk}"

# --- Debug and Environment Setup ---
echo "Current PATH: $PATH"
echo "Operating System: $(uname -a)"

# --- Helper Functions ---
# Check if minikube is installed.
minikube_exists() {
  command -v minikube >/dev/null 2>&1
}

# Get the script directory to reference local scripts reliably.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Install Prerequisites ---
echo "Installing kubectl and helm..."
bash "$SCRIPT_DIR/install-kubectl.sh"
bash "$SCRIPT_DIR/install-helm.sh"

# Install minikube if it isn’t already installed.
if minikube_exists; then
  echo "Minikube already installed."
else
  echo "Minikube not found. Installing minikube..."
  curl -LO https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-amd64
  sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64
fi

# --- Check for existing Minikube cluster ---
if minikube status &>/dev/null; then
  echo "An existing Minikube cluster was detected. Deleting it..."
  minikube delete || { echo "Failed to delete existing Minikube cluster"; exit 1; }
else
  echo "No existing Minikube cluster found. Proceeding..."
fi

# --- Configure BPF (if available) ---
if [ -f /proc/sys/net/core/bpf_jit_harden ]; then
    echo "Configuring BPF: Setting net.core.bpf_jit_harden=0"
    echo "net.core.bpf_jit_harden=0" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
else
    echo "BPF JIT hardening configuration not available, skipping..."
fi

# --- NVIDIA GPU Setup ---
GPU_AVAILABLE=false
if command -v "$NVIDIA_SMI_PATH" >/dev/null 2>&1; then
    echo "NVIDIA GPU detected via nvidia-smi at: $(command -v "$NVIDIA_SMI_PATH")"
    if command -v "$NVIDIA_CTK_PATH" >/dev/null 2>&1; then
      echo "nvidia-ctk found at: $(command -v "$NVIDIA_CTK_PATH")"
      GPU_AVAILABLE=true
    else
      echo "nvidia-ctk not found. Please install the NVIDIA Container Toolkit to enable GPU support."
    fi
else
    echo "No NVIDIA GPU detected. Will start minikube without GPU support."
fi

if [ "$GPU_AVAILABLE" = true ]; then
    # Configure Docker for GPU support.
    echo "Configuring Docker runtime for GPU support..."
    if sudo "$NVIDIA_CTK_PATH" runtime configure --runtime=docker; then
      echo "Restarting Docker to apply changes..."
      sudo systemctl restart docker
      echo "Docker runtime configured successfully."
    else
      echo "Error: Failed to configure Docker runtime using the NVIDIA Container Toolkit."
      exit 1
    fi

    # Start minikube with GPU support.
    echo "Starting minikube with GPU support..."
    minikube start --driver=docker --container-runtime=docker --gpus=all --memory=no-limit --cpus=no-limit --force

    # Update kubeconfig context.
    echo "Updating kubeconfig context..."
    minikube update-context

    # Note: LLM-D doesn't require GPU Operator - minikube's built-in NVIDIA support is sufficient
    echo "Minikube GPU setup complete - using built-in NVIDIA device plugin"
else
    # No GPU: Start minikube without GPU support.
    echo "Starting minikube without GPU support..."
    # Fix potential permission issues.
    sudo sysctl fs.protected_regular=0
    minikube start --memory=max --driver=docker --force
fi

echo "Minikube cluster installation complete."
