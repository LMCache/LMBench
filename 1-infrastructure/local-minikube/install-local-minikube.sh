#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$SCRIPT_DIR/helpers"

echo "Starting local Kubernetes environment setup..."

# Function to check if minikube is in a healthy state
check_minikube_health() {
  echo "Checking minikube health..."

  # Check if minikube command exists
  if ! command -v minikube &>/dev/null; then
    echo "minikube command not found"
    return 1
  fi

  # Check minikube status
  if ! minikube status &>/dev/null; then
    echo "minikube status check failed"
    return 1
  fi

  # Check if kubectl can connect to the cluster (with timeout)
  if ! timeout 10 kubectl cluster-info &>/dev/null; then
    echo "kubectl cannot connect to minikube cluster"
    return 1
  fi

  # Check if the minikube docker container actually exists
  local minikube_container_status
  minikube_container_status=$(docker container inspect minikube --format='{{.State.Status}}' 2>/dev/null || echo "not_found")

  if [[ "$minikube_container_status" != "running" ]]; then
    echo "minikube docker container is not running (status: $minikube_container_status)"
    return 1
  fi

  echo "minikube appears to be healthy"
  return 0
}

# Function to completely clean up minikube
cleanup_minikube() {
  echo "Performing complete minikube cleanup..."

  # Stop minikube if it's running
  minikube stop 2>/dev/null || true

  # Delete minikube cluster
  minikube delete 2>/dev/null || true

  # Remove minikube docker containers
  docker rm -f minikube 2>/dev/null || true

  # Clean up minikube profiles
  minikube delete --all 2>/dev/null || true

  # Remove minikube configuration directory
  rm -rf ~/.minikube 2>/dev/null || true

  # Remove kubectl minikube context
  kubectl config delete-context minikube 2>/dev/null || true
  kubectl config delete-cluster minikube 2>/dev/null || true
  kubectl config delete-user minikube 2>/dev/null || true

  # Prune minikube docker images (only if minikube is running)
  if minikube status >/dev/null 2>&1; then
    eval $(minikube docker-env)
    docker system prune -a --volumes -f
    eval $(minikube docker-env -u)
  else
    echo "Skipping docker cleanup - minikube not running"
  fi

  # Clean up any remaining minikube docker networks
  docker network ls --filter name=minikube --format "{{.ID}}" | xargs -r docker network rm 2>/dev/null || true

  # Clean up any remaining minikube docker volumes
  docker volume ls --filter name=minikube --format "{{.Name}}" | xargs -r docker volume rm 2>/dev/null || true

  echo "minikube cleanup completed"
}

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

# Check and install minikube if needed, with health checking
if command -v minikube &>/dev/null; then
  echo "minikube is installed, checking health..."
  if check_minikube_health; then
    echo "minikube is healthy and running, skipping installation and configuration."
  else
    echo "minikube is installed but not healthy, performing cleanup and reinstallation..."
    cleanup_minikube
    echo "Installing and configuring minikube..."
    bash "$HELPERS_DIR/install-minikube-cluster.sh"
  fi
else
  echo "Installing and configuring minikube..."
  bash "$HELPERS_DIR/install-minikube-cluster.sh"
fi

# Final health checks
echo "Performing final health checks..."

# Confirm minikube is installed
minikube version || { echo "minikube installation failed"; exit 1; }

# Confirm minikube is running
minikube status || { echo "minikube not running"; exit 1; }

# Confirm kubectl can connect
timeout 30 kubectl cluster-info || { echo "kubectl cannot connect to cluster"; exit 1; }

# Confirm minikube has at least one GPU enabled
if kubectl describe nodes | grep -q "nvidia.com/gpu"; then
  echo "GPU is detected on the Kubernetes node"
else
  echo "GPU not found on the node. Check GPU drivers and device plugin status."
  echo "Checking GPU status in detail..."
  kubectl describe nodes | grep -A 10 -B 5 -i "gpu\|nvidia" || echo "No GPU resources found in node description"
  exit 1
fi

echo "Local minikube Kubernetes environment setup is running with GPU access"
