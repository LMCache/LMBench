#! /bin/bash

# 1. go to the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"


# 2. run the sglang server
kubectl apply -f ../../4-latest-results/generated-sglang-config.yaml

# 3. Wait until all sglang pods are ready
echo "Waiting for all sglang pods to be ready..."
while true; do
  PODS=$(kubectl get pods 2>/dev/null)

  TOTAL=$(echo "$PODS" | tail -n +2 | wc -l)
  READY=$(echo "$PODS" | grep '1/1' | wc -l)

  # Comment when debugging kubernetes
  if echo "$PODS" | grep -E 'CrashLoopBackOff|Error|ImagePullBackOff' > /dev/null; then
    echo "❌ Detected pod in CrashLoopBackOff / Error / ImagePullBackOff state!"
    kubectl get pods
    kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep 'sglang-' | xargs kubectl describe pod
    kubectl delete all --all
    exit 1
  fi

  kubectl get pods -o name | grep sglang | while read pod; do
    echo "Checking logs for $pod for CUDA OOM"
    if kubectl logs $pod --tail=50 | grep "CUDA out of memory" >/dev/null; then
      echo "❗ CUDA OOM detected in $pod"
      kubectl get pods
      kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep '^sglang-' | xargs kubectl describe pod
      kubectl delete all --all
      exit 1
    fi
  done

  if [ "$READY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "✅ All $TOTAL pods are running and ready."
    kubectl get pods
    break
  else
    echo "⏳ $READY/$TOTAL pods ready..."
    kubectl get pods
    sleep 5
  fi
done

echo "Ready for port forwarding!"

nohup kubectl port-forward svc/sglang-service 30080:30000 > /dev/null 2>&1 &


# Testing it manually:
# curl -X POST http://localhost:30080/v1/completions \
#   -H "Content-Type: application/json" \
#   -d '{
#     "model": "meta-llama/Meta-Llama-3-8B-Instruct",
#     "prompt": "What is the capital of France?",
#     "max_tokens": 16
#   }'
