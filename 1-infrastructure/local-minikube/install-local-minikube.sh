#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$SCRIPT_DIR/helpers"

echo "Starting local Kubernetes environment setup..."

# Check and install kubectl if needed
if kubectl version --client &>/dev/null; then
  echo "kubectl is already installed, skipping installation."
else
  echo "Installing kubectl..."
  bash "$HELPERS_DIR/install-kubectl.sh"
  # Confirm kubectl is installed
  kubectl version --client || { echo "kubectl installation failed"; exit 1; }
fi

# Check and install helm if needed
if helm version &>/dev/null; then
  echo "helm is already installed, skipping installation."
else
  echo "Installing helm..."
  bash "$HELPERS_DIR/install-helm.sh"
  # Confirm helm is installed
  helm version || { echo "helm installation failed"; exit 1; }
fi

# Ensure Docker is installed
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker is not installed. Please install Docker first."
  exit 14
fi

# Check Docker access
if ! docker info &>/dev/null; then
  echo "Docker is installed but not accessible. Attempting to fix..."

  # Attempt to add current user to docker group (will require sudo)
  if sudo usermod -aG docker "$USER"; then
    echo "User $USER added to docker group."

    # Apply group change (won't affect parent shell)
    echo "Starting a new shell with docker group permissions..."
    exec sg docker "$0" "$@"  # re-run this script inside the docker group shell
  else
    echo "Failed to add user to docker group. Please run:"
    echo "    sudo usermod -aG docker $USER"
    exit 14
  fi
else
  echo "Docker is accessible."
fi

# Check and install minikube if needed
if command -v minikube &>/dev/null && minikube status &>/dev/null; then
  echo "minikube is already installed and running, skipping installation and configuration."
else
  echo "Installing and configuring minikube..."
  bash "$HELPERS_DIR/install-minikube-cluster.sh"

  # Confirm minikube is installed
  minikube version || { echo "minikube installation failed"; exit 1; }

  # Confirm minikube is running
  minikube status || { echo "minikube not running"; exit 1; }
fi

# Confirm minikube has at least one GPU enabled
if kubectl describe nodes | grep -q "nvidia.com/gpu"; then
  echo "GPU is detected on the Kubernetes node"
else
  echo "GPU not found on the node. Check GPU drivers and device plugin status."
  exit 1
fi

echo "Local minikube Kubernetes environment setup is running with GPU access"
