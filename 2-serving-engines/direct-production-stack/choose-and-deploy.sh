#! /bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# This script will choose the correct kubernetes config file and apply it to the cluster

# Parse arguments
SKIP_NODE_AFFINITY=false
KUBE_CONFIG_FILENAME=""

for arg in "$@"; do
  if [[ "$arg" == "--skip-node-affinity" ]]; then
    SKIP_NODE_AFFINITY=true
  elif [[ "$arg" != --* ]]; then
    KUBE_CONFIG_FILENAME="$arg"
  fi
done

if [ -z "$KUBE_CONFIG_FILENAME" ]; then
    echo "Error: Kubernetes configuration filename not provided."
    echo "Usage: $0 <kubernetes_config_filename> [--skip-node-affinity]"
    exit 1
fi

# Clean up port 30080 early to avoid conflicts
echo "Cleaning up any existing port forwarding on port 30080..."
# Kill any kubectl port-forward processes specifically
pkill -f "kubectl port-forward.*30080" 2>/dev/null || true
# Also check for any other processes using port 30080
PID_ON_30080=$(sudo lsof -t -i :30080 2>/dev/null)
if [[ -n "$PID_ON_30080" ]]; then
  echo "Found process on port 30080 (PID: $PID_ON_30080). Killing it..."
  sudo kill -9 "$PID_ON_30080" || echo "  ❗️ Failed to kill PID $PID_ON_30080"
else
  echo "✅ Port 30080 is free."
fi
# Wait a moment for the port to be fully released
sleep 2

# Set the path to the kubernetes configurations directory
KUBE_CONFIG_DIR="$SCRIPT_DIR/kubernetes_configurations"
KUBE_CONFIG_FILE="$KUBE_CONFIG_DIR/$KUBE_CONFIG_FILENAME"

# Check if the file exists
if [ ! -f "$KUBE_CONFIG_FILE" ]; then
    echo "Error: Kubernetes configuration file not found: $KUBE_CONFIG_FILE"
    echo "Available configurations:"
    ls -la "$KUBE_CONFIG_DIR" || echo "No configurations directory found at $KUBE_CONFIG_DIR"
    exit 1
fi

# Clean up any existing deployments to avoid conflicts
echo "Cleaning up kubectl resources..."
kubectl delete deployment --all
kubectl delete pods --all
kubectl delete service --all
kubectl delete pvc --all

# Wait for all resources to be fully deleted
echo "Waiting for all resources to be fully deleted..."
while true; do
  PODS=$(kubectl get pods | grep "deployment-vllm" | grep -v "router" 2>/dev/null || true)
  ROUTER_PODS=$(kubectl get pods -l environment=router 2>/dev/null | grep -v "No resources found" || true)

  if [ -z "$PODS" ] && [ -z "$ROUTER_PODS" ]; then
    echo "✅ All previous resources have been cleaned up"
    break
  fi

  echo "⏳ Waiting for resources to be deleted..."
  sleep 3
done

echo "Applying Kubernetes configuration: $KUBE_CONFIG_FILE"
kubectl apply -f "$KUBE_CONFIG_FILE"

# Skip node affinity assignments if requested
if [ "$SKIP_NODE_AFFINITY" = true ]; then
  echo "Skipping node pool affinity assignments as requested"
else
  # PATCHING DEPLOYMENTS TO USE APPROPRIATE NODE POOLS
  echo "Assigning deployments to node pools based on type..."

  # Give kubernetes a moment to create the resources
  sleep 5

  # Function to check if a node pool has sufficient resources
  check_node_resources() {
    local pool=$1
    local cpu_request=$2
    local memory_request=$3

    # Get available resources from nodes with this pool label
    local node_resources=$(kubectl get nodes -l pool=$pool -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\t"}{.status.allocatable.memory}{"\n"}{end}')

    if [ -z "$node_resources" ]; then
      echo "No nodes found with pool=$pool"
      return 1
    fi

    # Check if any node in the pool has enough resources
    local has_capacity=false
    while IFS= read -r line; do
      local node_cpu=$(echo $line | awk '{print $1}')
      local node_memory=$(echo $line | awk '{print $2}')

      # Convert memory strings to comparable values (Gi)
      local node_memory_gi=$(echo $node_memory | sed 's/Ki$/\/1048576/g; s/Mi$/\/1024/g; s/Gi$//g; s/Ti$/\*1024/g' | bc -l)
      local req_memory_gi=$(echo $memory_request | sed 's/G$//g; s/Gi$//g')

      if (( $(echo "$node_cpu >= $cpu_request" | bc -l) )) && (( $(echo "$node_memory_gi >= $req_memory_gi" | bc -l) )); then
        has_capacity=true
        break
      fi
    done < <(echo "$node_resources")

    if [ "$has_capacity" = true ]; then
      return 0
    else
      return 1
    fi
  }

  # Determine which pool to use for router based on resource requirements
  echo "Analyzing node pools for router deployment..."
  ROUTER_CPU_REQUEST=$(grep -A10 "resources:" "$KUBE_CONFIG_FILE" | grep -A2 "requests:" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
  ROUTER_MEMORY_REQUEST=$(grep -A10 "resources:" "$KUBE_CONFIG_FILE" | grep -A2 "requests:" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"')

  echo "Router requires CPU: $ROUTER_CPU_REQUEST, Memory: $ROUTER_MEMORY_REQUEST"

  # Try to find an appropriate pool for the router
  ROUTER_POOL=""
  if check_node_resources "cpu-pool" "$ROUTER_CPU_REQUEST" "$ROUTER_MEMORY_REQUEST"; then
    ROUTER_POOL="cpu-pool"
    echo "cpu-pool has sufficient resources for router"
  elif check_node_resources "default-pool" "$ROUTER_CPU_REQUEST" "$ROUTER_MEMORY_REQUEST"; then
    ROUTER_POOL="default-pool"
    echo "default-pool has sufficient resources for router"
  else
    echo "⚠️ Warning: No pool found with sufficient resources for router"
    ROUTER_POOL=""
  fi

  # Check for router deployment - using consistent name from k8s config files
  echo "Patching router deployment..."
  if kubectl get deployment vllm-deployment-router &>/dev/null; then
      if [ -n "$ROUTER_POOL" ]; then
          kubectl patch deployment vllm-deployment-router \
              -p '{"spec": {"template": {"spec": {"nodeSelector": {"pool": "'$ROUTER_POOL'"}}}}}'
          echo "✅ vllm-deployment-router assigned to $ROUTER_POOL"
      else
          echo "⚠️ Not assigning router to any specific pool due to resource constraints"
      fi
  else
      echo "⚠️ Router deployment not found to patch"
  fi

  # Check for model serving deployments - using pattern from k8s config files
  echo "Patching model deployments to use GPU nodes..."
  DEPLOYMENTS=$(kubectl get deployments -o name 2>/dev/null)
  if [ $? -eq 0 ]; then
      # Find vllm model deployments that match our pattern
      VLLM_DEPLOYMENTS=$(echo "$DEPLOYMENTS" | grep -E 'deployment.*/vllm-.*deployment-vllm')

      if [ -n "$VLLM_DEPLOYMENTS" ]; then
          echo "$VLLM_DEPLOYMENTS" | while read deploy; do
              if [[ $deploy != *"router"* ]]; then
                  kubectl patch $deploy \
                      -p '{"spec": {"template": {"spec": {"nodeSelector": {"pool": "gpu-pool"}}}}}'
                  echo "✅ $(echo $deploy | sed 's|deployment.apps/||') assigned to gpu-pool"
              fi
          done
      else
          echo "⚠️ No model serving deployments found matching pattern"
      fi
  else
      echo "⚠️ Error getting deployments list"
  fi

  # Also patch the deployment strategy to reduce max surge to 0 (create new pods only after old ones are terminated)
  echo "Patching deployment strategy to avoid creating excess pods..."
  VLLM_DEPLOYMENTS=$(kubectl get deployments | grep "deployment-vllm" | grep -v "router" | awk '{print $1}' | sed 's/^/deployment.apps\//' 2>/dev/null)
  if [ -n "$VLLM_DEPLOYMENTS" ]; then
      echo "$VLLM_DEPLOYMENTS" | while read deploy; do
          kubectl patch $deploy \
              -p '{"spec": {"strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}}}'
      done
      echo "✅ Patched deployment strategy to reduce max surge"
  fi
fi

# Wait until all pods are ready
echo "Waiting for all pods to be ready..."
# Add timeout of 20 minutes (1200 seconds)
TIMEOUT=1200
START_TIME=$(date +%s)
while true; do
  # Check if we've reached the timeout
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
    echo "❌ Timeout reached! Pods not ready after 20 minutes."
    kubectl get pods
    kubectl delete all --all
    exit 1
  fi

  PODS=$(kubectl get pods 2>/dev/null)

  TOTAL=$(echo "$PODS" | tail -n +2 | wc -l)
  READY=$(echo "$PODS" | grep '1/1' | wc -l)

  # # Check for pods in error state
  # if echo "$PODS" | grep -E 'CrashLoopBackOff|Error|ImagePullBackOff' > /dev/null; then
  #   echo "❌ Detected pod in CrashLoopBackOff / Error / ImagePullBackOff state!"
  #   kubectl get pods
  #   kubectl describe pods | grep -A 10 "Events:"
  #   kubectl delete all --all
  #   exit 1
  # fi

  # # Check for CUDA OOM
  # kubectl get pods -o name | grep -E 'vllm|lmcache' | while read pod; do
  #   echo "Checking logs for $pod for CUDA OOM"
  #   if kubectl logs $pod --tail=50 2>/dev/null | grep "CUDA out of memory" >/dev/null; then
  #     echo "❗ CUDA OOM detected in $pod"
  #     kubectl get pods
  #     kubectl describe pod $pod
  #     kubectl delete all --all
  #     exit 1
  #   fi
  # done

  if [ "$READY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "✅ All $TOTAL pods are running and ready."
    kubectl get pods
    break
  else
    echo "⏳ $READY/$TOTAL pods ready... (${ELAPSED_TIME}s elapsed out of ${TIMEOUT}s timeout)"
    kubectl get pods
    sleep 5
  fi
done

echo "Ready for port forwarding!"

# Start port forwarding in the background
kubectl port-forward svc/vllm-router-service 30080:80 &
echo "Port forwarding started on 30080"

