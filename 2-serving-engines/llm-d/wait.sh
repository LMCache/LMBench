#!/bin/bash
set -e

echo "=== Waiting for LLM-D Baseline Readiness ==="

# Configuration
TIMEOUT=600  # 10 minutes timeout (LLM-D can take time for model loading)
POLL_INTERVAL=10  # Check every 10 seconds
START_TIME=$(date +%s)

echo "Waiting for LLM-D service on localhost:30080..."
echo "Timeout: ${TIMEOUT}s, Poll interval: ${POLL_INTERVAL}s"

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    # Check timeout
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        echo "ERROR: Timeout reached! LLM-D service not ready after ${TIMEOUT}s"
        echo "=== Final Kubernetes status ==="
        kubectl get pods -n llm-d 2>/dev/null || echo "No llm-d namespace found"
        kubectl get services -n llm-d 2>/dev/null || echo "No services found"
        echo "=== Recent pod logs ==="
        kubectl logs -n llm-d --tail=20 -l llm-d.ai/role=decode 2>/dev/null || echo "No decode pod logs available"
        exit 1
    fi
    
    # Check if Kubernetes pods are ready first
    PODS_READY=false
    if kubectl get namespace llm-d > /dev/null 2>&1; then
        # Count ready pods vs total pods
        READY_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | wc -l)
        TOTAL_PODS=$(kubectl get pods -n llm-d --no-headers 2>/dev/null | wc -l)
        
        if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
            PODS_READY=true
            echo "Kubernetes pods ready ($READY_PODS/$TOTAL_PODS), checking service endpoint..."
        else
            echo "Kubernetes pods not ready ($READY_PODS/$TOTAL_PODS): $(kubectl get pods -n llm-d --no-headers 2>/dev/null | awk '{print $1 "=" $3}' | tr '\n' ' ')"
        fi
    else
        echo "llm-d namespace not found yet..."
    fi
    
    # Only test endpoint if pods are ready
    if [ "$PODS_READY" = true ]; then
        # Test /v1/models endpoint
        if curl -s -f "http://localhost:30080/v1/models" > /dev/null 2>&1; then
            echo "SUCCESS: LLM-D service is ready on localhost:30080 (took ${ELAPSED_TIME}s)"
            
            # Verify we can also hit /v1/chat/completions
            if curl -s -f -X POST "http://localhost:30080/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{"model": "gemma-2b", "messages": [{"role": "user", "content": "test"}], "max_tokens": 1}' > /dev/null 2>&1; then
                echo "SUCCESS: Chat completions endpoint also working"
            else
                echo "WARNING: Models endpoint ready but chat completions may not be fully ready yet"
            fi
            
            echo "=== LLM-D service is fully ready ==="
            exit 0
        else
            echo "Pods ready but service endpoint not responding yet..."
        fi
    fi
    
    echo "Waiting... (${ELAPSED_TIME}s elapsed)"
    sleep $POLL_INTERVAL
done 