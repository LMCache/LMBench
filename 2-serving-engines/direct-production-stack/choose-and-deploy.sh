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
  echo "[OK] Port 30080 is free."
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
kubectl delete all --all
kubectl delete pvc --all
kubectl delete poddisruptionbudget --all
kubectl delete serviceaccount --all
kubectl delete configmap --all
kubectl delete secret --all
kubectl delete ingress --all
kubectl delete networkpolicy --all
kubectl delete role --all
kubectl delete rolebinding --all

# Add these:
kubectl delete deployment --all
kubectl delete statefulset --all
kubectl delete daemonset --all
kubectl delete replicaset --all
kubectl delete job --all
kubectl delete cronjob --all
kubectl delete hpa --all
kubectl delete pdb --all
kubectl delete service --all
kubectl delete endpoints --all

# Wait for all resources to be fully deleted
echo "Waiting for all resources to be fully deleted..."
while true; do
  PODS=$(kubectl get pods | grep "deployment-vllm" | grep -v "router" 2>/dev/null || true)
  ROUTER_PODS=$(kubectl get pods -l environment=router 2>/dev/null | grep -v "No resources found" || true)

  if [ -z "$PODS" ] && [ -z "$ROUTER_PODS" ]; then
    echo "[OK] All previous resources have been cleaned up"
    break
  fi

  echo "[WAIT] Waiting for resources to be deleted..."
  sleep 3
done

# Process the kubernetes config file to substitute HF_TOKEN
echo "Processing Kubernetes configuration: $KUBE_CONFIG_FILE"
PROCESSED_CONFIG_FILE="/tmp/processed-k8s-config.yaml"

# Check if HF_TOKEN is set
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    exit 1
fi

# Substitute <YOUR_HF_TOKEN> with actual HF_TOKEN and encode it as base64
HF_TOKEN_BASE64=$(echo -n "$HF_TOKEN" | base64 -w 0)

# Substitute both the placeholder and the base64 encoded version
sed -e "s/<YOUR_HF_TOKEN>/$HF_TOKEN/g" \
    -e "s/<YOUR_HF_TOKEN_BASE64>/$HF_TOKEN_BASE64/g" \
    "$KUBE_CONFIG_FILE" > "$PROCESSED_CONFIG_FILE"

echo "Applying Kubernetes configuration: $PROCESSED_CONFIG_FILE"
kubectl apply -f "$PROCESSED_CONFIG_FILE"

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
    echo "[WARN] Warning: No pool found with sufficient resources for router"
    ROUTER_POOL=""
  fi

  # Check for router deployment - using consistent name from k8s config files
  echo "Patching router deployment..."
  if kubectl get deployment vllm-deployment-router &>/dev/null; then
      if [ -n "$ROUTER_POOL" ]; then
          kubectl patch deployment vllm-deployment-router \
              -p '{"spec": {"template": {"spec": {"nodeSelector": {"pool": "'$ROUTER_POOL'"}}}}}'
          echo "[OK] vllm-deployment-router assigned to $ROUTER_POOL"
      else
          echo "[WARN] Not assigning router to any specific pool due to resource constraints"
      fi
  else
      echo "[WARN] Router deployment not found to patch"
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
                  echo "[OK] $(echo $deploy | sed 's|deployment.apps/||') assigned to gpu-pool"
              fi
          done
      else
          echo "[WARN] No model serving deployments found matching pattern"
      fi
  else
      echo "[WARN] Error getting deployments list"
  fi

  # Fix pod duplication bug: patch the deployment strategy to prevent creating excess pods
  echo "Patching deployment strategy to avoid creating excess pods (fixing pod duplication bug)..."
  VLLM_DEPLOYMENTS=$(kubectl get deployments | grep "deployment-vllm" | grep -v "router" | awk '{print $1}' | sed 's/^/deployment.apps\//' 2>/dev/null)
  if [ -n "$VLLM_DEPLOYMENTS" ]; then
      echo "$VLLM_DEPLOYMENTS" | while read deploy; do
          # Fix pod duplication bug: use proper rolling update strategy
          kubectl patch $deploy \
              -p '{"spec": {"strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}}}'
          echo "[OK] Updated deployment strategy for $(echo $deploy | sed 's|deployment.apps/||') (fixed pod duplication)"

          # Wait for rollout to complete before cleaning up old ReplicaSets with live progress
          DEPLOYMENT_NAME=$(echo $deploy | sed 's|deployment.apps/||')
          echo "[WAIT] Waiting for rollout of $DEPLOYMENT_NAME to complete..."
          
          # Monitor rollout progress with observability
          ROLLOUT_START=$(date +%s)
          while true; do
            ROLLOUT_CURRENT=$(date +%s)
            ROLLOUT_ELAPSED=$((ROLLOUT_CURRENT - ROLLOUT_START))
            
            # Check if pods are actually ready (more reliable than rollout status)
            READY_PODS=$(kubectl get pods -l helm-release-name=vllm --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | wc -l)
            TOTAL_PODS=$(kubectl get pods -l helm-release-name=vllm --no-headers 2>/dev/null | wc -l)
            
            if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
              echo "[OK] Rollout completed for $DEPLOYMENT_NAME - all $READY_PODS/$TOTAL_PODS pods ready"
              break
            fi
            
            # Show comprehensive pod status for observability
            echo "[INFO] Rollout progress (${ROLLOUT_ELAPSED}s) - ALL PODS STATUS:"
            ALL_PODS=$(kubectl get pods 2>/dev/null)
            if [ -n "$ALL_PODS" ]; then
              echo "$ALL_PODS"
              
              # Summary counts
              TOTAL_PODS=$(echo "$ALL_PODS" | tail -n +2 | wc -l)
              READY_PODS=$(echo "$ALL_PODS" | grep -c " 1/1 " 2>/dev/null || echo "0")
              RUNNING_PODS=$(echo "$ALL_PODS" | grep -c " Running " 2>/dev/null || echo "0")
              echo "  SUMMARY: $READY_PODS/$TOTAL_PODS pods ready, $RUNNING_PODS running"
            else
              echo "  No pods found"
            fi
            echo "--- END POD STATUS ---"
            sleep 5
          done

          # Clean up old ReplicaSets only after successful rollout
          echo "[FIX] Cleaning up old ReplicaSets for $DEPLOYMENT_NAME after successful rollout..."
          kubectl get replicaset -l helm-release-name=vllm -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null | while read rs_name rs_replicas; do
            if [ -n "$rs_name" ] && [ "$rs_replicas" = "0" ]; then
              echo "[FIX] Deleting old ReplicaSet: $rs_name"
              kubectl delete replicaset $rs_name --grace-period=30 2>/dev/null || true
            fi
          done
      done
      echo "[OK] Patched deployment strategy to use maxSurge=0 maxUnavailable=1 (fixed pod duplication bug)"


  fi
fi

# Wait until all pods are ready
echo "Waiting for all pods to be ready..."
# Add timeout of 25 minutes (1500 seconds)
TIMEOUT=1500
START_TIME=$(date +%s)
while true; do
  # Check if we've reached the timeout
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
    echo "[ERROR] Timeout reached! Pods not ready after 25 minutes."
    kubectl get pods
    kubectl delete all --all
    exit 1
  fi

  PODS=$(kubectl get pods 2>/dev/null)

  # Count only pods that are not in permanent failure states
  TOTAL=$(echo "$PODS" | tail -n +2 | grep -v -E '(Error|Failed|Completed)' | wc -l)
  READY=$(echo "$PODS" | grep '1/1' | wc -l)

  # Actively clean up crashed pods to prevent them from blocking progress
  CRASHED_PODS=$(echo "$PODS" | grep -E '(Error|Failed)' | awk '{print $1}')
  if [ -n "$CRASHED_PODS" ]; then
    echo "[FIX] Cleaning up crashed pods..."
    echo "$CRASHED_PODS" | while read pod; do
      echo "[FIX] Deleting crashed pod: $pod"
      kubectl delete pod $pod 2>/dev/null || true
    done
  fi

  # Also clean up Pending pods that are stuck (likely from old ReplicaSets)
  PENDING_PODS=$(echo "$PODS" | grep 'Pending' | awk '{print $1}')
  if [ -n "$PENDING_PODS" ]; then
    echo "[FIX] Cleaning up stuck Pending pods..."
    echo "$PENDING_PODS" | while read pod; do
      # Check if this pod has been pending for more than 12 minutes
      POD_AGE=$(kubectl get pod $pod -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
      if [ -n "$POD_AGE" ]; then
        # Convert to seconds since epoch for comparison
        POD_AGE_SECONDS=$(date -d "$POD_AGE" +%s 2>/dev/null || echo "0")
        CURRENT_SECONDS=$(date +%s)
        AGE_DIFF=$((CURRENT_SECONDS - POD_AGE_SECONDS))

        # If pending for more than 720 seconds (12 minutes), delete it
        if [ $AGE_DIFF -gt 720 ]; then
          echo "[FIX] Deleting stuck Pending pod: $pod (pending for ${AGE_DIFF}s)"
          kubectl delete pod $pod 2>/dev/null || true
        fi
      fi
    done
  fi

  # Aggressively clean up old ReplicaSets to prevent duplicate pods
  echo "[FIX] Cleaning up old ReplicaSets..."
  DEPLOYMENTS=$(kubectl get deployments -o name 2>/dev/null | grep -E ".*deployment-vllm|.*vllm.*deployment" | grep -v "router")
  if [ -n "$DEPLOYMENTS" ]; then
    echo "$DEPLOYMENTS" | while read deploy; do
      DEPLOYMENT_NAME=$(echo $deploy | sed 's|deployment.apps/||')

      # Simple approach: delete any ReplicaSets with 0 replicas for this deployment
      kubectl get replicaset -l helm-release-name=vllm -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null | while read rs_name rs_replicas; do
        if [ -n "$rs_name" ] && [ "$rs_replicas" = "0" ]; then
          echo "[FIX] Force deleting ReplicaSet with 0 replicas: $rs_name (owned by $DEPLOYMENT_NAME)"
          kubectl delete replicaset $rs_name --force --grace-period=0 2>/dev/null || true
        fi
      done
    done
  fi





  if [ "$READY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "[OK] All $TOTAL pods are running and ready."
    echo "=== FINAL POD STATUS ==="
    kubectl get pods
    echo "======================="
    break
  else
    echo "[WAIT] $READY/$TOTAL pods ready... (${ELAPSED_TIME}s elapsed out of ${TIMEOUT}s timeout)"
    echo "=== DETAILED POD STATUS ==="
    ALL_PODS=$(kubectl get pods 2>/dev/null)
    if [ -n "$ALL_PODS" ]; then
      echo "$ALL_PODS"
      echo "=== SUMMARY: $READY/$TOTAL pods ready ==="
    fi
    echo "=========================="
    sleep 5
  fi
done

echo "Ready for port forwarding!"

# Start port forwarding in the background
nohup kubectl port-forward svc/vllm-router-service 30080:80 > /dev/null 2>&1 &
echo "Port forwarding started on 30080"

# Clean up temporary file
rm -f "$PROCESSED_CONFIG_FILE"

