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
  echo "[OK] Port 30080 is free."
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
  echo "[WARN]  Port 30080 is already in use. Killing existing process..."
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

# Remove any existing production-stack repo
rm -rf production-stack
# Clone production-stack repo
git clone https://github.com/vllm-project/production-stack.git
# Install the stack
echo "Installing vLLM stack..."
# make sure we don't have an existing release
helm uninstall vllm || true
# release name is vllm
helm install vllm production-stack/helm -f "$PROCESSED_CONFIG_FILE"

# IMMEDIATELY patch deployment strategy to avoid creating excess pods
echo "[FIX] Patching deployment strategy to avoid creating excess pods..."
sleep 3  # Give helm a moment to create resources

# Wait for deployments to be created with proper timeout (60 seconds should be enough)
DEPLOYMENT_TIMEOUT=60
START_TIME=$(date +%s)
echo "[WAIT] Waiting for vLLM deployments to be created..."
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

  if [ $ELAPSED_TIME -gt $DEPLOYMENT_TIMEOUT ]; then
    echo "[ERROR] Timeout: vLLM deployments not found after ${DEPLOYMENT_TIMEOUT}s"
    echo "Available deployments:"
    kubectl get deployments 2>/dev/null || echo "No deployments found"
    exit 1
  fi

  VLLM_DEPLOYMENTS=$(kubectl get deployments 2>/dev/null | grep "deployment-vllm" | grep -v "router" | awk '{print $1}' || true)
  if [ -n "$VLLM_DEPLOYMENTS" ]; then
    echo "[OK] Found vLLM deployments after ${ELAPSED_TIME}s"
    echo "$VLLM_DEPLOYMENTS" | while read deploy; do
      # Fix pod duplication bug: use proper rolling update strategy
      kubectl patch deployment $deploy \
          -p '{"spec": {"strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}}}'
      echo "[OK] $deploy patched with maxSurge=0 maxUnavailable=1 strategy (fixed pod duplication)"
      
      # Wait for rollout to complete before proceeding with live progress monitoring
      echo "[WAIT] Waiting for rollout of $deploy to complete..."
      
      # Monitor rollout progress with observability
      ROLLOUT_START=$(date +%s)
      while true; do
        ROLLOUT_CURRENT=$(date +%s)
        ROLLOUT_ELAPSED=$((ROLLOUT_CURRENT - ROLLOUT_START))
        
        # Check if pods are actually ready (more reliable than rollout status)
        # Use a more general selector to catch all vllm-related pods
        READY_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="1/1" && $3=="Running"' | wc -l)
        TOTAL_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | wc -l)
        
        if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
          echo "[OK] Rollout completed for $deploy - all $READY_PODS/$TOTAL_PODS pods ready"
          break
        fi
        
        # Check for persistent failures (CrashLoopBackOff, Error, ImagePullBackOff)
        FAILED_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$3 ~ /CrashLoopBackOff|Error|ImagePullBackOff/' | wc -l)
        if [ "$FAILED_PODS" -gt 0 ]; then
          CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
          echo "[WARN] Rollout progress (${ROLLOUT_ELAPSED}s): $FAILED_PODS pods in failure state (consecutive failures: $CONSECUTIVE_FAILURES/$MAX_CONSECUTIVE_FAILURES)"
          
          if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            echo "[ERROR] Persistent failures detected - $FAILED_PODS pods failing for $((CONSECUTIVE_FAILURES * 5)) seconds"
            echo "[ERROR] Deployment $deploy appears to have a configuration issue. Last pod status:"
            kubectl get pods
            echo "[ERROR] Recent logs from failing pods:"
            kubectl get pods --no-headers | grep -E "(vllm|deployment)" | awk '$3 ~ /CrashLoopBackOff|Error/' | head -1 | awk '{print $1}' | xargs -r kubectl logs --tail=10
            break
          fi
        else
          CONSECUTIVE_FAILURES=0
        fi
        
        # Show current pod status for observability
        echo "[INFO] Rollout progress (${ROLLOUT_ELAPSED}s): $(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '{print $1 "=" $3}' | tr '\n' ' ') ($READY_PODS/$TOTAL_PODS ready)"
        sleep 5
      done
    done
    break
  else
    echo "[WAIT] Still waiting for deployments... (${ELAPSED_TIME}s elapsed)"
    sleep 2
  fi
done

# IMMEDIATE AUTOMATED FIX FOR VLLM ENTRYPOINT ISSUE
echo "[FIX] Applying immediate vLLM entrypoint fixes for lmcache/vllm-openai images..."

# The deployments should already exist from above, but add a small safety check
if [ -z "$VLLM_DEPLOYMENTS" ]; then
  VLLM_DEPLOYMENTS=$(kubectl get deployments 2>/dev/null | grep -E ".*deployment-vllm|.*vllm.*deployment" | grep -v "router" | awk '{print $1}' || true)
fi

if [ -n "$VLLM_DEPLOYMENTS" ]; then
  echo "[FIX] Found vLLM deployments, checking for lmcache/vllm-openai images..."
  echo "$VLLM_DEPLOYMENTS" | while read deploy; do
    IMAGE=$(kubectl get deployment $deploy -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    if [[ $IMAGE == *"lmcache/vllm-openai"* ]]; then
      echo "[FIX] FIXING: $deploy uses $IMAGE - applying entrypoint fix..."
      kubectl patch deployment $deploy --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/0", "value": "/opt/venv/bin/vllm"}]' 2>/dev/null || true
      echo "[OK] FIXED: $deploy patched to use /opt/venv/bin/vllm"

      # Clean up old ReplicaSets to avoid multiple ReplicaSets for the same deployment
      echo "[FIX] Cleaning up old ReplicaSets for $deploy..."

      # Fix pod duplication bug: use proper rolling update strategy
      kubectl patch deployment $deploy \
          -p '{"spec": {"strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}}}'
      echo "[OK] Updated deployment strategy for $deploy (fixed pod duplication)"

      # Wait for rollout to complete before cleaning up old ReplicaSets with live progress
      echo "[WAIT] Waiting for rollout of $deploy to complete..."
      
      # Monitor rollout progress with observability and failure detection
      ROLLOUT_START=$(date +%s)
      CONSECUTIVE_FAILURES=0
      MAX_CONSECUTIVE_FAILURES=6  # 30 seconds of consecutive failures
      
      while true; do
        ROLLOUT_CURRENT=$(date +%s)
        ROLLOUT_ELAPSED=$((ROLLOUT_CURRENT - ROLLOUT_START))
        
        # Check if pods are actually ready (more reliable than rollout status)
        # Use a more general selector to catch all vllm-related pods
        READY_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="1/1" && $3=="Running"' | wc -l)
        TOTAL_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | wc -l)
        
        if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
          echo "[OK] Rollout completed for $deploy - all $READY_PODS/$TOTAL_PODS pods ready"
          break
        fi
        
        # Check for persistent failures (CrashLoopBackOff, Error, ImagePullBackOff)
        FAILED_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$3 ~ /CrashLoopBackOff|Error|ImagePullBackOff/' | wc -l)
        if [ "$FAILED_PODS" -gt 0 ]; then
          CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
          echo "[WARN] Rollout progress (${ROLLOUT_ELAPSED}s): $FAILED_PODS pods in failure state (consecutive failures: $CONSECUTIVE_FAILURES/$MAX_CONSECUTIVE_FAILURES)"
          
          if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            echo "[ERROR] Persistent failures detected - $FAILED_PODS pods failing for $((CONSECUTIVE_FAILURES * 5)) seconds"
            echo "[ERROR] Deployment $deploy appears to have a configuration issue. Last pod status:"
            kubectl get pods
            echo "[ERROR] Recent logs from failing pods:"
            kubectl get pods --no-headers | grep -E "(vllm|deployment)" | awk '$3 ~ /CrashLoopBackOff|Error/' | head -1 | awk '{print $1}' | xargs -r kubectl logs --tail=10
            break
          fi
        else
          CONSECUTIVE_FAILURES=0
        fi
        
        # Show current pod status for observability
        echo "[INFO] Rollout progress (${ROLLOUT_ELAPSED}s): $(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '{print $1 "=" $3}' | tr '\n' ' ') ($READY_PODS/$TOTAL_PODS ready)"
        sleep 5
      done

      # Clean up old ReplicaSets only after successful rollout
      echo "[FIX] Cleaning up old ReplicaSets for $deploy after successful rollout..."
      kubectl get replicaset --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="0" {print $1}' | while read rs_name; do
        if [ -n "$rs_name" ]; then
          echo "[FIX] Deleting old ReplicaSet: $rs_name"
          kubectl delete replicaset $rs_name --grace-period=30 2>/dev/null || true
        fi
      done
    else
      echo "[INFO]  $deploy uses $IMAGE - no fix needed"
    fi
  done
else
  echo "[WARN] No vLLM deployments found for entrypoint fixes"
fi

# Skip node affinity assignments if requested
if [ "$SKIP_NODE_AFFINITY" = true ]; then
  echo "Skipping node pool affinity assignments as requested"
else
  # PATCHING DEPLOYMENTS TO USE APPROPRIATE NODE POOLS
  echo "Assigning deployments to node pools based on type..."

  # First ensure all pods are ready before doing node assignments to avoid unnecessary rollouts
  echo "Checking if all pods are ready before node assignments..."
  ALL_READY=true
  VLLM_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" || true)
  if [ -n "$VLLM_PODS" ]; then
    NOT_READY=$(echo "$VLLM_PODS" | awk '$2!="1/1" || $3!="Running"' | wc -l)
    if [ "$NOT_READY" -gt 0 ]; then
      ALL_READY=false
      echo "[WARN] $NOT_READY pods not ready yet, skipping node assignments to avoid unnecessary rollouts"
    fi
  fi

  if [ "$ALL_READY" = true ]; then
    echo "[OK] All pods ready, proceeding with node assignments"
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

      # Convert memory strings to comparable values (Gi) - fix bc syntax error
      local node_memory_gi=$(echo $node_memory | sed 's/Ki$/\/1048576/g; s/Mi$/\/1024/g; s/Gi$//g; s/Ti$/\*1024/g' | bc -l 2>/dev/null || echo "0")
      local req_memory_gi=$(echo $memory_request | sed 's/G$//g; s/Gi$//g' | bc -l 2>/dev/null || echo "0")

      # Use awk for safer numeric comparisons instead of bc
      if awk "BEGIN {exit !($node_cpu >= $cpu_request)}" 2>/dev/null && awk "BEGIN {exit !($node_memory_gi >= $req_memory_gi)}" 2>/dev/null; then
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

                  # Clean up old ReplicaSets after node assignment patch
                  DEPLOYMENT_NAME=$(echo $deploy | sed 's|deployment.apps/||')
                  echo "[FIX] Cleaning up old ReplicaSets for $DEPLOYMENT_NAME after node assignment..."

                  # Fix pod duplication bug: use proper rolling update strategy
                  kubectl patch $deploy \
                      -p '{"spec": {"strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}}}'
                  echo "[OK] Updated deployment strategy for $DEPLOYMENT_NAME (fixed pod duplication)"

                  # Wait for rollout to complete before cleaning up old ReplicaSets with live progress
                  echo "[WAIT] Waiting for rollout of $DEPLOYMENT_NAME to complete..."
                  
                  # Monitor rollout progress with observability and failure detection
                  ROLLOUT_START=$(date +%s)
                  CONSECUTIVE_FAILURES=0
                  MAX_CONSECUTIVE_FAILURES=6  # 30 seconds of consecutive failures
                  
                  while true; do
                    ROLLOUT_CURRENT=$(date +%s)
                    ROLLOUT_ELAPSED=$((ROLLOUT_CURRENT - ROLLOUT_START))
                    
                    # Check if pods are actually ready (more reliable than rollout status)
                    # Use a more general selector to catch all vllm-related pods
                    READY_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="1/1" && $3=="Running"' | wc -l)
                    TOTAL_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | wc -l)
                    
                    if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
                      echo "[OK] Rollout completed for $DEPLOYMENT_NAME - all $READY_PODS/$TOTAL_PODS pods ready"
                      break
                    fi
                    
                    # Check for persistent failures (CrashLoopBackOff, Error, ImagePullBackOff)
                    FAILED_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$3 ~ /CrashLoopBackOff|Error|ImagePullBackOff/' | wc -l)
                    if [ "$FAILED_PODS" -gt 0 ]; then
                      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
                      echo "[WARN] Rollout progress (${ROLLOUT_ELAPSED}s): $FAILED_PODS pods in failure state (consecutive failures: $CONSECUTIVE_FAILURES/$MAX_CONSECUTIVE_FAILURES)"
                      
                      if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                        echo "[ERROR] Persistent failures detected - $FAILED_PODS pods failing for $((CONSECUTIVE_FAILURES * 5)) seconds"
                        echo "[ERROR] Deployment $DEPLOYMENT_NAME appears to have a configuration issue. Last pod status:"
                        kubectl get pods
                        echo "[ERROR] Recent logs from failing pods:"
                        kubectl get pods --no-headers | grep -E "(vllm|deployment)" | awk '$3 ~ /CrashLoopBackOff|Error/' | head -1 | awk '{print $1}' | xargs -r kubectl logs --tail=10
                        break
                      fi
                    else
                      CONSECUTIVE_FAILURES=0
                    fi
                    
                    # Show current pod status for observability
                    echo "[INFO] Rollout progress (${ROLLOUT_ELAPSED}s): $(kubectl get pods --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '{print $1 "=" $3}' | tr '\n' ' ') ($READY_PODS/$TOTAL_PODS ready)"
                    sleep 5
                  done

                  # Clean up old ReplicaSets only after successful rollout
                  echo "[FIX] Cleaning up old ReplicaSets for $DEPLOYMENT_NAME after successful rollout..."
                  kubectl get replicaset --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="0" {print $1}' | while read rs_name; do
                    if [ -n "$rs_name" ]; then
                      echo "[FIX] Deleting old ReplicaSet: $rs_name"
                      kubectl delete replicaset $rs_name --grace-period=30 2>/dev/null || true
                    fi
                  done
              fi
          done
      else
          echo "[WARN] No model serving deployments found matching pattern"
      fi
  else
      echo "[WARN] Error getting deployments list"
  fi
  
  else
    echo "[INFO] Skipping node assignments - waiting for pods to be ready first"
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

      # Simpler approach: get current deployment's revision annotation
      CURRENT_REVISION=$(kubectl get $deploy -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null)
      if [ -n "$CURRENT_REVISION" ]; then
        echo "[FIX] Current deployment revision for $DEPLOYMENT_NAME: $CURRENT_REVISION"

        # Find all ReplicaSets for this deployment and delete the ones with 0 replicas
        kubectl get replicaset --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="0" {print $1}' | while read rs_name; do
          if [ -n "$rs_name" ]; then
            echo "[FIX] Force deleting ReplicaSet with 0 replicas: $rs_name"
            kubectl delete replicaset $rs_name --force --grace-period=0 2>/dev/null || true
          fi
        done
      else
        # Fallback: just delete any ReplicaSets with 0 replicas for this deployment
        kubectl get replicaset --no-headers 2>/dev/null | grep -E "(vllm|deployment)" | awk '$2=="0" {print $1}' | while read rs_name; do
          if [ -n "$rs_name" ]; then
            echo "[FIX] Force deleting ReplicaSet with 0 replicas: $rs_name"
            kubectl delete replicaset $rs_name --force --grace-period=0 2>/dev/null || true
          fi
        done
      fi
    done
  fi

  # Check for pods in CrashLoopBackOff state and fix vLLM entrypoint issues
  CRASHLOOP_PODS=$(echo "$PODS" | grep 'CrashLoopBackOff' | awk '{print $1}')
  if [ -n "$CRASHLOOP_PODS" ]; then
    echo "[FIX] Detected pods in CrashLoopBackOff state, checking for vLLM entrypoint issues..."
    echo "$CRASHLOOP_PODS" | while read pod; do
      # Check if this is a vLLM pod and if it has the entrypoint issue
      if [[ $pod =~ .*vllm.*deployment|.*deployment.*vllm ]] && [[ $pod != *"router"* ]]; then
        LOGS=$(kubectl logs $pod --tail=10 2>/dev/null || true)
        if echo "$LOGS" | grep -q 'exec: "vllm": executable file not found'; then
          echo "[FIX] Found vLLM entrypoint issue in pod $pod, applying fix..."

          # Get the deployment name from the pod
          DEPLOYMENT=$(kubectl get pod $pod -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
          if [ -n "$DEPLOYMENT" ]; then
            DEPLOYMENT_NAME=$(kubectl get replicaset $DEPLOYMENT -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
            if [ -n "$DEPLOYMENT_NAME" ]; then
              echo "[FIX] Patching deployment $DEPLOYMENT_NAME to use correct vLLM entrypoint..."
              kubectl patch deployment $DEPLOYMENT_NAME --type='json' \
                -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/0", "value": "/opt/venv/bin/vllm"}]' 2>/dev/null

              # Delete the failing pod to trigger recreation with correct command
              echo "[FIX] Deleting failing pod $pod to trigger recreation..."
              kubectl delete pod $pod 2>/dev/null

              # Delete old replicaset to prevent creating more failing pods
              echo "[FIX] Cleaning up old replicaset $DEPLOYMENT..."
              kubectl delete replicaset $DEPLOYMENT 2>/dev/null || true

              echo "[OK] Applied vLLM entrypoint fix for $DEPLOYMENT_NAME"
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
      if [[ $pod =~ .*vllm.*deployment|.*deployment.*vllm ]] && [[ $pod != *"router"* ]]; then
        # Check if it's the vllm entrypoint issue
        DESCRIBE_OUTPUT=$(kubectl describe pod $pod 2>/dev/null || true)
        if echo "$DESCRIBE_OUTPUT" | grep -q 'exec: "vllm": executable file not found'; then
          echo "[FIX] AGGRESSIVE FIX: Found vLLM entrypoint issue in failing pod $pod"

          # Get deployment name and fix it
          DEPLOYMENT=$(kubectl get pod $pod -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
          if [ -n "$DEPLOYMENT" ]; then
            DEPLOYMENT_NAME=$(kubectl get replicaset $DEPLOYMENT -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
            if [ -n "$DEPLOYMENT_NAME" ]; then
              echo "[FIX] AGGRESSIVE FIX: Patching $DEPLOYMENT_NAME..."
              kubectl patch deployment $DEPLOYMENT_NAME --type='json' \
                -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command/0", "value": "/opt/venv/bin/vllm"}]' 2>/dev/null || true
              kubectl delete pod $pod 2>/dev/null || true
              kubectl delete replicaset $DEPLOYMENT 2>/dev/null || true
              echo "[OK] AGGRESSIVE FIX: Applied to $DEPLOYMENT_NAME"
            fi
          fi
        fi
      fi
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
