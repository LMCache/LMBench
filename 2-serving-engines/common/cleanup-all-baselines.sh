#!/bin/bash
set -e

echo "=== Comprehensive Baseline Cleanup ==="
echo "This script will clean up ALL baselines to ensure a clean deployment environment."

# 0. Environment Variable Cleanup
echo "0. Cleaning up environment variables from previous runs..."
# Dynamo environment variables
unset DYNAMO_SERVING_ENGINE
unset DYNAMO_ENABLE_TORCH_COMPILE
unset DYNAMO_MODEL_NAME
unset DYNAMO_CACHE_SIZE
unset DYNAMO_TENSOR_PARALLEL_SIZE
unset DYNAMO_MAX_SEQ_LEN
unset DYNAMO_BLOCK_SIZE
unset DYNAMO_GPU_MEMORY_UTILIZATION
unset DYNAMO_SWAP_SPACE
unset DYNAMO_ENABLE_CHUNKED_PREFILL
unset DYNAMO_ENABLE_PREFIX_CACHING
unset DYNAMO_QUANTIZATION
unset DYNAMO_TORCH_COMPILE_BACKEND
unset DYNAMO_TORCH_COMPILE_MODE
unset DYNAMO_TORCH_COMPILE_CUSTOM_OPS
unset DYNAMO_TORCH_COMPILE_DISABLE_CUDAGRAPHS
unset DYNAMO_TORCH_COMPILE_MAX_CAPTURE_SIZE
unset DYNAMO_TORCH_COMPILE_CAPTURE_DYNAMIC_SHAPES
# SGLang environment variables
unset SGLANG_DISABLE_CACHE
unset SGLANG_ENABLE_FLASHINFER
unset SGLANG_ENABLE_TORCHCOMPILE
unset SGLANG_ENABLE_MIXED_PRECISION
unset SGLANG_ENABLE_FP8_E5M2
unset SGLANG_ENABLE_FP8_E4M3
unset SGLANG_ENABLE_SPECULATIVE_DECODING
unset SGLANG_ENABLE_TRITON_ATTENTION
unset SGLANG_ENABLE_TRITON_FUSED_MLP
unset SGLANG_ENABLE_TRITON_LAYERNORM
unset SGLANG_ENABLE_TRITON_QUANTIZATION
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS_FAST
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS_SAFE
unset SGLANG_ENABLE_TRITON_CUSTOM_OPS_UNSAFE
# RayServe environment variables
unset VLLM_USE_V1
unset RAY_DEDUP_LOGS
# General cleanup
unset TORCH_LOGS
unset CUDA_VISIBLE_DEVICES
unset NCCL_DEBUG
unset NCCL_SOCKET_IFNAME
unset NCCL_IB_DISABLE
unset OMP_NUM_THREADS
echo "Environment variables cleaned up."

# 1. GPU Process Cleanup
echo "1. Clearing GPU processes..."
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

# 2. Port 30080 Cleanup
echo "2. Cleaning up port 30080..."
# Kill kubectl port-forward processes
pkill -f "kubectl port-forward.*30080" 2>/dev/null || true
# Kill any other processes using port 30080
PID_ON_30080=$(lsof -t -i :30080 2>/dev/null || true)
if [[ -n "$PID_ON_30080" ]]; then
    echo "Found process on port 30080 (PID: $PID_ON_30080). Killing it..."
    kill -9 "$PID_ON_30080" 2>/dev/null || sudo kill -9 "$PID_ON_30080" 2>/dev/null || echo "Failed to kill PID $PID_ON_30080"
fi
sleep 2

# 3. Ray Services Cleanup (for RayServe baseline)
echo "3. Stopping Ray services..."
if command -v ray &> /dev/null; then
    ray stop --force 2>/dev/null || true
    echo "Ray services stopped."
else
    echo "Ray not found, skipping Ray cleanup"
fi

# 4. Helm Cleanup (for Helm-ProductionStack baseline)
echo "4. Cleaning up Helm releases..."
if command -v helm &> /dev/null; then
    # Get all helm releases and uninstall them
    HELM_RELEASES=$(helm list --all-namespaces -q 2>/dev/null || true)
    if [ -n "$HELM_RELEASES" ]; then
        echo "Found Helm releases to uninstall:"
        echo "$HELM_RELEASES" | while read release; do
            if [ -n "$release" ]; then
                echo "Uninstalling Helm release: $release"
                helm uninstall "$release" --timeout=60s 2>/dev/null || true
            fi
        done
    else
        echo "No Helm releases found to uninstall."
    fi
else
    echo "Helm not found, skipping Helm cleanup"
fi

# 5. Kubernetes Resources Cleanup
echo "5. Cleaning up Kubernetes resources..."
if command -v kubectl &> /dev/null && kubectl cluster-info &>/dev/null; then
    echo "Cluster is accessible, proceeding with Kubernetes cleanup..."
    
    # Delete all resources in default namespace
    echo "Deleting all resources in default namespace..."
    kubectl delete all --all --timeout=60s 2>/dev/null || true
    kubectl delete pvc --all --timeout=60s 2>/dev/null || true
    kubectl delete poddisruptionbudget --all --timeout=60s 2>/dev/null || true
    kubectl delete serviceaccount --all --timeout=60s 2>/dev/null || true
    kubectl delete configmap --all --timeout=60s 2>/dev/null || true
    kubectl delete secret --all --timeout=60s 2>/dev/null || true
    kubectl delete ingress --all --timeout=60s 2>/dev/null || true
    kubectl delete networkpolicy --all --timeout=60s 2>/dev/null || true
    kubectl delete role --all --timeout=60s 2>/dev/null || true
    kubectl delete rolebinding --all --timeout=60s 2>/dev/null || true
    kubectl delete deployment --all --timeout=60s 2>/dev/null || true
    kubectl delete statefulset --all --timeout=60s 2>/dev/null || true
    kubectl delete daemonset --all --timeout=60s 2>/dev/null || true
    kubectl delete replicaset --all --timeout=60s 2>/dev/null || true
    kubectl delete job --all --timeout=60s 2>/dev/null || true
    kubectl delete cronjob --all --timeout=60s 2>/dev/null || true
    kubectl delete hpa --all --timeout=60s 2>/dev/null || true
    kubectl delete pdb --all --timeout=60s 2>/dev/null || true
    kubectl delete service --all --timeout=60s 2>/dev/null || true
    kubectl delete endpoints --all --timeout=60s 2>/dev/null || true
    
    # Delete application namespaces (keep system namespaces)
    echo "Deleting application namespaces..."
    NAMESPACES_TO_DELETE=$(kubectl get namespaces --no-headers | grep -v -E "^(kube-system|kube-public|kube-node-lease|default)" | awk '{print $1}' || true)
    if [ -n "$NAMESPACES_TO_DELETE" ]; then
        echo "$NAMESPACES_TO_DELETE" | while read namespace; do
            if [ -n "$namespace" ]; then
                echo "Deleting namespace: $namespace"
                kubectl delete namespace "$namespace" --timeout=60s --ignore-not-found=true 2>/dev/null || true
            fi
        done
    else
        echo "No application namespaces found to delete."
    fi
    
    # Clean up specific CRDs that might be left behind
    echo "Cleaning up Custom Resource Definitions..."
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
      --ignore-not-found 2>/dev/null || true
    
    # Force delete any stuck resources
    echo "Force deleting any stuck resources..."
    kubectl get pods --all-namespaces --field-selector=status.phase=Terminating --no-headers 2>/dev/null | while read namespace pod others; do
        if [ -n "$namespace" ] && [ -n "$pod" ]; then
            echo "Force deleting stuck pod: $namespace/$pod"
            kubectl delete pod "$pod" -n "$namespace" --force --grace-period=0 2>/dev/null || true
        fi
    done
    
    echo "Kubernetes resources cleaned up."
    
    # Reset kubectl context to default namespace to avoid namespace conflicts
    echo "Resetting kubectl context to use default namespace..."
    kubectl config set-context --current --namespace=default 2>/dev/null || true
    echo "kubectl context reset to default namespace."
else
    echo "Cannot connect to Kubernetes cluster, skipping Kubernetes cleanup"
fi

# Clean up any remaining port forwarding
pkill -f "kubectl port-forward" 2>/dev/null || true

echo "=== Comprehensive cleanup completed ==="
echo "All baselines have been cleaned up. Ready for fresh deployment." 