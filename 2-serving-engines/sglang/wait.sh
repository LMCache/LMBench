#!/bin/bash
set -e

echo "=== Waiting for SGLang Baseline Readiness ==="

# Configuration
TIMEOUT=300  # 5 minutes timeout
POLL_INTERVAL=5  # Check every 5 seconds
START_TIME=$(date +%s)

echo "Waiting for SGLang service on localhost:30080..."
echo "Timeout: ${TIMEOUT}s, Poll interval: ${POLL_INTERVAL}s"

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    # Check timeout
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        echo "ERROR: Timeout reached! SGLang service not ready after ${TIMEOUT}s"
        echo "Check sglang.log for details:"
        tail -20 sglang.log 2>/dev/null || echo "No log file found"
        exit 1
    fi
    
    # Test /v1/models endpoint
    if curl -s -f "http://localhost:30080/v1/models" > /dev/null 2>&1; then
        echo "SUCCESS: SGLang service is ready on localhost:30080 (took ${ELAPSED_TIME}s)"
        
        # Verify we can also hit /v1/chat/completions
        if curl -s -f -X POST "http://localhost:30080/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"model": "meta-llama/Meta-Llama-3.1-8B-Instruct", "messages": [{"role": "user", "content": "test"}], "max_tokens": 1}' > /dev/null 2>&1; then
            echo "SUCCESS: Chat completions endpoint also working"
        else
            echo "WARNING: Models endpoint ready but chat completions may not be fully ready yet"
        fi
        
        echo "=== SGLang service is fully ready ==="
        exit 0
    else
        echo "Waiting... (${ELAPSED_TIME}s elapsed, service not ready yet)"
        sleep $POLL_INTERVAL
    fi
done 