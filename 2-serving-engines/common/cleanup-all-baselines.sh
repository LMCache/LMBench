#!/bin/bash
# Note: Not using 'set -e' to avoid terminating the script if individual cleanup commands fail
# We want to continue cleaning up even if some processes can't be killed

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

# 1. GPU Process Cleanup (Simple nvidia-smi based approach)
echo "1. Clearing GPU processes..."
if command -v nvidia-smi &> /dev/null; then
    echo "Checking for GPU processes..."
    
    # Check if GPUs are available and accessible
    if ! nvidia-smi &>/dev/null; then
        echo "Warning: nvidia-smi command failed, GPUs may not be accessible"
        echo "nvidia-smi not accessible, skipping GPU cleanup"
    else
        # Get compute processes from nvidia-smi
        GPU_COMPUTE_PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
        
        # Get graphics processes from nvidia-smi  
        GPU_GRAPHICS_PIDS=$(nvidia-smi --query-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
        
        # Combine and deduplicate PIDs from nvidia-smi only
        ALL_GPU_PIDS=$(echo -e "$GPU_COMPUTE_PIDS\n$GPU_GRAPHICS_PIDS" | sort -u | grep -E '^[0-9]+$' || true)
        
        if [ -n "$ALL_GPU_PIDS" ]; then
            echo "Found GPU processes from nvidia-smi, attempting to kill them..."
            for pid in $ALL_GPU_PIDS; do
                if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
                    # Check if process still exists before trying to kill
                    if kill -0 "$pid" 2>/dev/null; then
                        PROCESS_NAME=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                        PROCESS_CMD=$(ps -p "$pid" -o args= 2>/dev/null | head -c 50 || echo "unknown")
                        echo "Killing GPU process PID: $pid ($PROCESS_NAME) - $PROCESS_CMD"
                        # Use sudo kill -9 directly as requested
                        if sudo kill -9 "$pid" 2>/dev/null; then
                            echo "  Successfully killed PID $pid"
                        else
                            echo "  Failed to kill PID $pid (process may have already exited)"
                        fi
                    else
                        echo "Process PID $pid already exited"
                    fi
                fi
            done
            
            # Wait for processes to die and verify
            echo "Waiting for processes to terminate..."
            sleep 3
            
            # Verify GPU is actually free
            echo "Verifying GPU processes are cleared..."
            REMAINING_COMPUTE=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
            REMAINING_GRAPHICS=$(nvidia-smi --query-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
            
            if [ -z "$REMAINING_COMPUTE" ] && [ -z "$REMAINING_GRAPHICS" ]; then
                echo "GPU processes cleared successfully."
            else
                echo "Warning: Some GPU processes may still be running:"
                if [ -n "$REMAINING_COMPUTE" ]; then
                    echo "Compute processes:"
                    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true
                fi
                if [ -n "$REMAINING_GRAPHICS" ]; then
                    echo "Graphics processes:"
                    nvidia-smi --query-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true
                fi
            fi
        else
            echo "No GPU processes found to kill."
        fi
        
        # Show final GPU status
        echo "Final GPU memory status:"
        nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "Could not query GPU memory"
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

# 3. Docker Container Cleanup (for Dynamo baseline)
echo "3. Cleaning up Docker containers..."
if command -v docker &> /dev/null; then
    # Stop and remove dynamo containers
    echo "Stopping dynamo containers..."
    sudo docker stop $(sudo docker ps -q --filter "ancestor=dynamo:latest-vllm" --filter "name=dynamo-serve") 2>/dev/null || true
    sudo docker rm $(sudo docker ps -aq --filter "ancestor=dynamo:latest-vllm" --filter "name=dynamo-serve") 2>/dev/null || true
    
    # Clean up any containers with dynamo in the name
    DYNAMO_CONTAINERS=$(sudo docker ps -aq --filter "name=dynamo" 2>/dev/null || true)
    if [ -n "$DYNAMO_CONTAINERS" ]; then
        echo "Removing additional dynamo containers..."
        sudo docker stop $DYNAMO_CONTAINERS 2>/dev/null || true
        sudo docker rm $DYNAMO_CONTAINERS 2>/dev/null || true
    fi
    
    echo "Docker containers cleaned up."
else
    echo "Docker not found, skipping Docker cleanup"
fi

# 4. Ray Services Cleanup (for RayServe baseline)
echo "4. Stopping Ray services..."
if command -v ray &> /dev/null; then
    ray stop --force 2>/dev/null || true
    echo "Ray services stopped."
else
    echo "Ray not found, skipping Ray cleanup"
fi

# 5. Helm Cleanup (for Helm-ProductionStack baseline)
echo "5. Cleaning up Helm releases..."
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

# 6. Kubernetes Resources Cleanup
echo "6. Cleaning up Kubernetes resources..."
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

# Add a 5-second buffer to ensure all cleanup operations have fully completed
echo "Waiting 5 seconds for cleanup operations to fully complete..."
sleep 5
echo "Cleanup script finished successfully." 