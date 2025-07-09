#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== LLM-D Baseline Setup ==="

# Check if configuration file argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <config-file-name>"
    echo "Example: $0 debug-deployment.yaml"
    echo "Available configurations:"
    ls -1 llmd_configurations/ 2>/dev/null || echo "  No configurations found in llmd_configurations/"
    exit 1
fi

CONFIG_FILE="$1"

# 1. Clear out all processes currently using GPUs
echo "Clearing GPU processes..."
if command -v nvidia-smi &> /dev/null; then
    echo "Killing GPU processes..."
    
    # Method 1: Use nvidia-smi to get compute processes
    GPU_PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
    
    # Method 2: Also check pmon output for additional processes
    PMON_PIDS=$(nvidia-smi pmon -c 1 2>/dev/null | awk 'NR>2 && $2!="[Unknown]" {print $2}' | grep -v '^-$' || true)
    
    # Combine and deduplicate PIDs
    ALL_PIDS=$(echo -e "$GPU_PIDS\n$PMON_PIDS" | sort -u | grep -E '^[0-9]+$' || true)
    
    if [ -n "$ALL_PIDS" ]; then
        for pid in $ALL_PIDS; do
            if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
                echo "Killing GPU process PID: $pid"
                # Try regular kill first, then sudo if needed
                if ! kill -9 "$pid" 2>/dev/null; then
                    sudo kill -9 "$pid" 2>/dev/null || echo "  Failed to kill PID $pid"
                fi
            fi
        done
        
        # Wait for processes to die and verify
        sleep 3
        
        # Verify GPU is actually free
        REMAINING_PROCESSES=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
        if [ -n "$REMAINING_PROCESSES" ]; then
            echo "Warning: Some GPU processes may still be running:"
            nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader || true
        else
            echo "GPU processes cleared successfully."
        fi
    else
        echo "No GPU processes found to kill."
    fi
else
    echo "nvidia-smi not found, skipping GPU cleanup"
fi

# 2. Clean up any processes using port 30080
echo "Cleaning up port 30080..."
pkill -f "kubectl port-forward.*30080" 2>/dev/null || true
PID_ON_30080=$(lsof -t -i :30080 2>/dev/null || true)
if [[ -n "$PID_ON_30080" ]]; then
    echo "Found process on port 30080 (PID: $PID_ON_30080). Killing it..."
    kill -9 "$PID_ON_30080" || echo "Failed to kill PID $PID_ON_30080"
fi
sleep 2

# 3. Clean up Kubernetes environment
echo "Cleaning up Kubernetes environment..."

# Check if minikube is accessible
if ! kubectl cluster-info &>/dev/null; then
    echo "Cannot connect to Kubernetes cluster. Please ensure minikube is running."
    exit 1
fi

echo "Cluster is accessible, proceeding with cleanup..."

# Delete LLM-D namespace and all its resources (this is sufficient)
kubectl delete namespace llm-d --ignore-not-found=true --timeout=60s

# Clean up Istio resources (but don't restart the whole cluster)
kubectl delete namespace istio-system --ignore-not-found=true --timeout=60s
kubectl delete namespace llm-d-monitoring --ignore-not-found=true --timeout=60s

# Clean up specific CRDs related to LLM-D/Istio
kubectl delete crd \
  authorizationpolicies.security.istio.io \
  destinationrules.networking.istio.io \
  envoyfilters.networking.istio.io \
  gateways.networking.istio.io \
  istiooperators.install.istio.io \
  peerauthentications.security.istio.io \
  proxyconfigs.networking.istio.io \
  requestauthentications.security.istio.io \
  serviceentries.networking.istio.io \
  sidecars.networking.istio.io \
  telemetries.telemetry.istio.io \
  virtualservices.networking.istio.io \
  workloadentries.networking.istio.io \
  workloadgroups.networking.istio.io \
  --ignore-not-found

echo "Kubernetes environment cleaned (without cluster restart)."

# 4. Validate HF_TOKEN
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

echo "=== Setup complete. Ready for deployment. ===" 