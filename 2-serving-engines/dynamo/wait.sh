#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== Waiting for Dynamo service to be ready ==="

# Wait for Dynamo service to be ready on port 30080
TIMEOUT=300  # 5 minutes
SLEEP_INTERVAL=5
START_TIME=$(date +%s)

echo "Waiting for Dynamo service to become ready on http://localhost:30080..."

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: Timeout waiting for Dynamo service to become ready after ${TIMEOUT} seconds"
        exit 1
    fi
    
    # Check if service is responding
    if curl -s --max-time 10 http://localhost:30080/health > /dev/null 2>&1; then
        echo "SUCCESS: Dynamo service is ready on port 30080"
        break
    elif curl -s --max-time 10 http://localhost:30080 > /dev/null 2>&1; then
        echo "SUCCESS: Dynamo service is ready on port 30080"
        break
    else
        echo "Service not ready yet... waiting ${SLEEP_INTERVAL} seconds (elapsed: ${ELAPSED}s)"
        sleep $SLEEP_INTERVAL
    fi
done

echo "=== Dynamo service is ready ===" 