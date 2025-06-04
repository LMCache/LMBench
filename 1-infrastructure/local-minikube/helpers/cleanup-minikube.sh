#!/bin/bash

set -e

echo "Starting complete minikube cleanup..."

# Function to safely run commands that might fail
safe_run() {
  "$@" 2>/dev/null || true
}

# Stop minikube if it's running
echo "Stopping minikube..."
safe_run minikube stop

# Delete minikube cluster
echo "Deleting minikube cluster..."
safe_run minikube delete

# Remove all minikube profiles
echo "Removing all minikube profiles..."
safe_run minikube delete --all

# Remove minikube docker containers
echo "Removing minikube docker containers..."
safe_run docker rm -f minikube

# Clean up minikube docker networks
echo "Cleaning up minikube docker networks..."
minikube_networks=$(docker network ls --filter name=minikube --format "{{.ID}}" 2>/dev/null || true)
if [[ -n "$minikube_networks" ]]; then
  echo "$minikube_networks" | xargs -r docker network rm 2>/dev/null || true
fi

# Clean up minikube docker volumes
echo "Cleaning up minikube docker volumes..."
minikube_volumes=$(docker volume ls --filter name=minikube --format "{{.Name}}" 2>/dev/null || true)
if [[ -n "$minikube_volumes" ]]; then
  echo "$minikube_volumes" | xargs -r docker volume rm 2>/dev/null || true
fi

# Remove minikube configuration directory
echo "Removing minikube configuration directory..."
safe_run rm -rf ~/.minikube

# Remove kubectl minikube contexts
echo "Removing kubectl minikube contexts..."
safe_run kubectl config delete-context minikube
safe_run kubectl config delete-cluster minikube
safe_run kubectl config delete-user minikube

# Clean up any remaining minikube processes
echo "Cleaning up any remaining minikube processes..."
pkill -f minikube 2>/dev/null || true

# Clean up minikube cache directories
echo "Cleaning up minikube cache directories..."
safe_run rm -rf ~/.cache/minikube
safe_run rm -rf /tmp/minikube*

# Clean up any minikube-related systemd services (if any)
echo "Cleaning up minikube systemd services..."
safe_run sudo systemctl stop minikube 2>/dev/null || true
safe_run sudo systemctl disable minikube 2>/dev/null || true

echo "Complete minikube cleanup finished successfully!"
echo "You can now run the installation script to set up a fresh minikube cluster."