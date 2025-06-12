#!/bin/bash
set -e

# 1. Go to the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

VALUES_FILE=$1

# ------------------------ NEW: argument parsing ------------------------
# Supports one optional flag: --skip-node-affinity to bypass node pool assignment
SKIP_NODE_AFFINITY=false
for arg in "$@"; do
  if [[ "$arg" == "--skip-node-affinity" ]]; then
    SKIP_NODE_AFFINITY=true
  fi
done

# ------------------------ NEW: free up local port 30080 ------------------------
# Clean up any kubectl port-forward processes already binding to 30080
pkill -f "kubectl port-forward.*30080" 2>/dev/null || true
PID_ON_30080=$(sudo lsof -t -i :30080 2>/dev/null)
if [[ -n "$PID_ON_30080" ]]; then
  echo "Found process on port 30080 (PID: $PID_ON_30080). Killing it..."
  sudo kill -9 "$PID_ON_30080" || echo "  ❗️ Failed to kill PID $PID_ON_30080"
else
  echo "✅ Port 30080 is free."
fi
sleep 2  # short grace period

# Kill any process using port 30080
if lsof -ti :30080 > /dev/null; then
  echo "⚠️  Port 30080 is already in use. Killing existing process..."
  kill -9 $(lsof -ti :30080)
fi

# Clean up any existing deployments to avoid conflicts
echo "Cleaning up kubectl resources..."
kubectl delete all --all || true
kubectl delete pvc --all || true
kubectl delete poddisruptionbudget --all || true
kubectl delete serviceaccount --all || true
kubectl delete configmap --all || true
kubectl delete secret --all || true
kubectl delete ingress --all || true
kubectl delete networkpolicy --all || true
kubectl delete role --all || true
kubectl delete rolebinding --all || true

# Add these:
kubectl delete deployment --all || true
kubectl delete statefulset --all || true
kubectl delete daemonset --all || true
kubectl delete replicaset --all || true
kubectl delete job --all || true
kubectl delete cronjob --all || true
kubectl delete hpa --all || true
kubectl delete pdb --all || true
kubectl delete service --all || true
kubectl delete endpoints --all || true

# ------------------------ NEW: helper to wait for deletion completion ------------------------
wait_for_cleanup() {
  local timeout=60
  local start=$(date +%s)
  echo "Waiting for Kubernetes resources to terminate..."
  while true; do
    local elapsed=$(( $(date +%s) - start ))
    if [[ $elapsed -gt $timeout ]]; then
      echo "⚠️  Timeout waiting for resources to delete (> ${timeout}s). Continuing anyway."
      break
    fi
    # Count terminating pods across all namespaces
    local terminating=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c Terminating || true)
    if [[ $terminating -eq 0 ]]; then
      echo "✅ Cluster appears clean after ${elapsed}s."
      break
    fi
    echo "⏳ Still waiting for $terminating terminating pods... ($elapsed/${timeout}s)"
    sleep 2
  done
}

# Call wait for cleanup just after deletions
wait_for_cleanup

# Clone and deploy llm-d-deployer
git clone https://github.com/llm-d/llm-d-deployer.git || true
cd llm-d-deployer/quickstart

# Install dependencies
bash ./install-deps.sh

# Run llmd installer with minikube
bash ./llmd-installer.sh --minikube --values-file $VALUES_FILE

# Set up Istio ingress gateway
helm repo add istio https://istio-release.storage.googleapis.com/charts || true
helm repo update
helm install istio-ingressgateway istio/gateway --namespace istio-system

# Wait for ingress gateway to be ready
echo "Waiting for istio-ingressgateway to be ready..."
kubectl wait --namespace istio-system   --for=condition=ready pod   --selector=app=istio-ingressgateway   --timeout=120s

# ------------------------ NEW: optional node-affinity assignment ------------------------
if [ "$SKIP_NODE_AFFINITY" = true ]; then
  echo "Skipping node pool affinity assignments as requested"
else
  echo "Assigning node pools for llm-d deployments..."
  sleep 5  # give k8s time to create deployments

  # Patch helper
  assign_pool() {
    local deploy=$1
    local pool=$2
    echo "🔧 Patching $deploy to pool=$pool"
    kubectl patch deployment $deploy -n llm-d \
      -p '{"spec":{"template":{"spec":{"nodeSelector":{"pool":"'"$pool"'"}}}}}' 2>/dev/null || true
  }

  # Detect deployments in llm-d namespace
  DEPLOYMENTS=$(kubectl get deployments -n llm-d -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)
  for deploy in $DEPLOYMENTS; do
    case $deploy in
      *gateway*|*inference-gateway*|*router*)
        assign_pool "$deploy" "cpu-pool";;
      *redis*|*modelservice*)
        assign_pool "$deploy" "default-pool";;
      *)
        assign_pool "$deploy" "gpu-pool";;
    esac
  done
fi

# ------------------------ NEW: pod readiness wait loop ------------------------
TIMEOUT=1500  # 25 minutes
START_TIME=$(date +%s)
echo "Waiting for llm-d pods to become Ready (timeout ${TIMEOUT}s)..."
while true; do
  current=$(date +%s)
  elapsed=$((current - START_TIME))
  if [[ $elapsed -gt $TIMEOUT ]]; then
    echo "❌ Timeout reached after ${TIMEOUT}s. Pods not ready."
    kubectl get pods -n llm-d
    exit 1
  fi

  PODS=$(kubectl get pods -n llm-d 2>/dev/null)
  TOTAL=$(echo "$PODS" | tail -n +2 | wc -l)
  READY=$(echo "$PODS" | grep -E "^[^ ]+ +[0-9]+/[0-9]+ +Running" | awk '{print $2}' | awk -F"/" '$1==$2{c++} END{print c+0}')

  echo "⏳ $READY/$TOTAL llm-d pods ready... (${elapsed}s elapsed)"

  if [[ $READY -eq $TOTAL && $TOTAL -gt 0 ]]; then
    echo "✅ All $TOTAL llm-d pods are running and ready."
    kubectl get pods -n llm-d
    break
  fi
  sleep 5
done

# ------------------------ NEW: background port-forward ------------------------
# Forward Istio ingress gateway service to localhost:30080
kubectl port-forward -n istio-system svc/istio-ingressgateway 30080:80 &
PORT_FORWARD_PID=$!
echo "Port forwarding started on 30080 (PID: $PORT_FORWARD_PID)"

echo "🎉 llm-d deployment complete and accessible at http://localhost:30080"
