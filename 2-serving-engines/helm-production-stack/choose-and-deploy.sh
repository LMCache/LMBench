#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# This script will choose the correct helm config file and deploy it to the cluster

# Parse arguments
SKIP_NODE_AFFINITY=false
HELM_CONFIG_FILENAME=""

for arg in "$@"; do
  if [[ "$arg" == "--skip-node-affinity" ]]; then
    SKIP_NODE_AFFINITY=true
  elif [[ "$arg" != --* ]]; then
    HELM_CONFIG_FILENAME="$arg"
  fi
done

if [ -z "$HELM_CONFIG_FILENAME" ]; then
    echo "Error: Helm configuration filename not provided."
    echo "Usage: $0 <helm_config_filename> [--skip-node-affinity]"
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

# Set the path to the helm configurations directory
HELM_CONFIG_DIR="$SCRIPT_DIR/helm_configurations"
HELM_CONFIG_FILE="$HELM_CONFIG_DIR/$HELM_CONFIG_FILENAME"

# Check if the file exists
if [ ! -f "$HELM_CONFIG_FILE" ]; then
    echo "Error: Helm configuration file not found: $HELM_CONFIG_FILE"
    echo "Available configurations:"
    ls -la "$HELM_CONFIG_DIR" || echo "No configurations directory found at $HELM_CONFIG_DIR"
    exit 1
fi

# Kill any process using port 30080
if lsof -ti :30080 > /dev/null; then
  echo "⚠️  Port 30080 is already in use. Killing existing process..."
  kill -9 $(lsof -ti :30080)
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

# Process the helm config file to substitute HF_TOKEN
echo "Processing Helm configuration: $HELM_CONFIG_FILE"
PROCESSED_CONFIG_FILE="/tmp/processed-helm-config.yaml"

# Substitute <YOUR_HF_TOKEN> with actual HF_TOKEN
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

sed "s/<YOUR_HF_TOKEN>/$HF_TOKEN/g" "$HELM_CONFIG_FILE" > "$PROCESSED_CONFIG_FILE"

# Clone production-stack repo
git clone https://github.com/vllm-project/production-stack.git
# Install the stack
echo "Installing vLLM stack..."
# make sure we don't have an existing release
helm uninstall vllm || true
# release name is vllm
helm install vllm production-stack/helm -f "$PROCESSED_CONFIG_FILE"

# IMMEDIATELY patch deployment strategy to avoid creating excess pods
echo "🔧 Patching deployment strategy to avoid creating excess pods..."
sleep 3  # Give helm a moment to create resources

# Wait for deployments to be created with proper timeout (60 seconds should be enough)
DEPLOYMENT_TIMEOUT=60
START_TIME=$(date +%s)
echo "⏳ Waiting for vLLM deployments to be created..."
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

  if [ $ELAPSED_TIME -gt $DEPLOYMENT_TIMEOUT ]; then
    echo "❌ Timeout: vLLM deployments not found after ${DEPLOYMENT_TIMEOUT}s"
    echo "Available deployments:"
    kubectl get deployments 2>/dev/null || echo "No deployments found"
    exit 1
  fi

  VLLM_DEPLOYMENTS=$(kubectl get deployments 2>/dev/null | grep "deployment-vllm" | grep -v "router" | awk '{print $1}' || true)
  if [ -n "$VLLM_DEPLOYMENTS" ]; then
    echo "✅ Found vLLM deployments after ${ELAPSED_TIME}s"
    echo "$VLLM_DEPLOYMENTS" | while read deploy; do
      kubectl patch deployment $deploy \
          -p '{"spec": {"strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}}}'
      echo "✅ $deploy patched with maxSurge=0 strategy"
    done
    break
  else
    echo "⏳ Still waiting for deployments... (${ELAPSED_TIME}s elapsed)"
    sleep 2
  fi
done

# IMMEDIATE AUTOMATED FIX FOR VLLM ENTRYPOINT ISSUE
echo "🔧 Applying immediate vLLM entrypoint fixes for lmcache/vllm-openai images..."

# The deployments should already exist from above, but add a small safety check
if [ -z "$VLLM_DEPLOYMENTS" ]; then
  VLLM_DEPLOYMENTS=$(kubectl get deployments 2>/dev/null | grep "deployment-vllm" | grep -v "router" | awk '{print $1}' || true)
fi

if [ -n "$VLLM_DEPLOYMENTS" ]; then
  echo "🔧 Found vLLM deployments, checking for lmcache/vllm-openai images..."
  echo "$VLLM_DEPLOYMENTS" | while read deploy; do
    IMAGE=$(kubectl get deployment $deploy -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    if [[ $IMAGE == *"lmcache/vllm-openai"* ]]; then
      echo "🔧 FIXING: $deploy uses $IMAGE - applying entrypoint fix..."
      kubectl patch deployment $deploy --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/0", "value": "/opt/venv/bin/vllm"}]' 2>/dev/null || true
      echo "✅ FIXED: $deploy patched to use /opt/venv/bin/vllm"

      # Clean up old ReplicaSets to avoid multiple ReplicaSets for the same deployment
      echo "🔧 Cleaning up old ReplicaSets for $deploy..."
      OLD_REPLICASETS=$(kubectl get replicaset -l app=$deploy 2>/dev/null | awk 'NR>1 && $2==0 {print $1}' || true)
      if [ -n "$OLD_REPLICASETS" ]; then
        echo "$OLD_REPLICASETS" | while read rs; do
          echo "🔧 Deleting old ReplicaSet: $rs"
          kubectl delete replicaset $rs 2>/dev/null || true
        done
      fi
    else
      echo "ℹ️  $deploy uses $IMAGE - no fix needed"
    fi
  done
else
  echo "⚠️ No vLLM deployments found for entrypoint fixes"
fi

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
  ROUTER_CPU_REQUEST=$(grep -A10 "resources:" "$PROCESSED_CONFIG_FILE" | grep -A2 "requests:" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
  ROUTER_MEMORY_REQUEST=$(grep -A10 "resources:" "$PROCESSED_CONFIG_FILE" | grep -A2 "requests:" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"')

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

                  # Clean up old ReplicaSets after node assignment patch
                  DEPLOYMENT_NAME=$(echo $deploy | sed 's|deployment.apps/||')
                  echo "🔧 Cleaning up old ReplicaSets for $DEPLOYMENT_NAME after node assignment..."
                  OLD_REPLICASETS=$(kubectl get replicaset -l app=$DEPLOYMENT_NAME 2>/dev/null | awk 'NR>1 && $2==0 {print $1}' || true)
                  if [ -n "$OLD_REPLICASETS" ]; then
                    echo "$OLD_REPLICASETS" | while read rs; do
                      echo "🔧 Deleting old ReplicaSet: $rs"
                      kubectl delete replicaset $rs 2>/dev/null || true
                    done
                  fi
              fi
          done
      else
          echo "⚠️ No model serving deployments found matching pattern"
      fi
  else
      echo "⚠️ Error getting deployments list"
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

  # Check for pods in CrashLoopBackOff state and fix vLLM entrypoint issues
  CRASHLOOP_PODS=$(echo "$PODS" | grep 'CrashLoopBackOff' | awk '{print $1}')
  if [ -n "$CRASHLOOP_PODS" ]; then
    echo "🔧 Detected pods in CrashLoopBackOff state, checking for vLLM entrypoint issues..."
    echo "$CRASHLOOP_PODS" | while read pod; do
      # Check if this is a vLLM pod and if it has the entrypoint issue
      if [[ $pod == *"deployment-vllm"* ]] && [[ $pod != *"router"* ]]; then
        LOGS=$(kubectl logs $pod --tail=10 2>/dev/null || true)
        if echo "$LOGS" | grep -q 'exec: "vllm": executable file not found'; then
          echo "🔧 Found vLLM entrypoint issue in pod $pod, applying fix..."

          # Get the deployment name from the pod
          DEPLOYMENT=$(kubectl get pod $pod -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
          if [ -n "$DEPLOYMENT" ]; then
            DEPLOYMENT_NAME=$(kubectl get replicaset $DEPLOYMENT -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
            if [ -n "$DEPLOYMENT_NAME" ]; then
              echo "🔧 Patching deployment $DEPLOYMENT_NAME to use correct vLLM entrypoint..."
              kubectl patch deployment $DEPLOYMENT_NAME --type='json' \
                -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/0", "value": "/opt/venv/bin/vllm"}]' 2>/dev/null

              # Delete the failing pod to trigger recreation with correct command
              echo "🔧 Deleting failing pod $pod to trigger recreation..."
              kubectl delete pod $pod 2>/dev/null

              # Delete old replicaset to prevent creating more failing pods
              echo "🔧 Cleaning up old replicaset $DEPLOYMENT..."
              kubectl delete replicaset $DEPLOYMENT 2>/dev/null || true

              echo "✅ Applied vLLM entrypoint fix for $DEPLOYMENT_NAME"
            fi
          fi
        fi
      fi
    done
  fi

  # ALSO check for any failing vLLM pods and apply fixes aggressively
  FAILING_PODS=$(echo "$PODS" | grep -E 'Error|ContainerCannotRun|CrashLoopBackOff|ImagePullBackOff' | awk '{print $1}')
  if [ -n "$FAILING_PODS" ]; then
    echo "$FAILING_PODS" | while read pod; do
      if [[ $pod == *"deployment-vllm"* ]] && [[ $pod != *"router"* ]]; then
        # Check if it's the vllm entrypoint issue
        DESCRIBE_OUTPUT=$(kubectl describe pod $pod 2>/dev/null || true)
        if echo "$DESCRIBE_OUTPUT" | grep -q 'exec: "vllm": executable file not found'; then
          echo "🔧 AGGRESSIVE FIX: Found vLLM entrypoint issue in failing pod $pod"

          # Get deployment name and fix it
          DEPLOYMENT=$(kubectl get pod $pod -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
          if [ -n "$DEPLOYMENT" ]; then
            DEPLOYMENT_NAME=$(kubectl get replicaset $DEPLOYMENT -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
            if [ -n "$DEPLOYMENT_NAME" ]; then
              echo "🔧 AGGRESSIVE FIX: Patching $DEPLOYMENT_NAME..."
              kubectl patch deployment $DEPLOYMENT_NAME --type='json' \
                -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/0", "value": "/opt/venv/bin/vllm"}]' 2>/dev/null || true
              kubectl delete pod $pod 2>/dev/null || true
              kubectl delete replicaset $DEPLOYMENT 2>/dev/null || true
              echo "✅ AGGRESSIVE FIX: Applied to $DEPLOYMENT_NAME"
            fi
          fi
        fi
      fi
    done
  fi

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

# Clean up temporary file
rm -f "$PROCESSED_CONFIG_FILE"
