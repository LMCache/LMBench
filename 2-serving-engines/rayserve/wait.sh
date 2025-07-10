#!/bin/bash
set -e

echo "=== Waiting for RayServe Baseline Readiness ==="

# Configuration
TIMEOUT=600  # 10 minutes timeout
POLL_INTERVAL=5  # Check every 5 seconds
START_TIME=$(date +%s)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$SCRIPT_DIR/rayserve.log"
PID_FILE="$SCRIPT_DIR/rayserve.pid"

echo "Monitoring: $LOG_FILE"
echo "Timeout: ${TIMEOUT}s"
echo ""

check_count=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    check_count=$((check_count + 1))
    
    # Check timeout
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        echo "ERROR: Timeout reached after ${TIMEOUT}s"
        exit 1
    fi
    
    # Show log content every check
    echo "--- Check #$check_count (${ELAPSED_TIME}s) ---"
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$LOG_SIZE" -gt 0 ]; then
            echo "rayserve.log (last 8 lines):"
            tail -8 "$LOG_FILE" 2>/dev/null || echo "  Could not read log file"
        else
            echo "rayserve.log is empty"
        fi
    else
        echo "rayserve.log not found"
    fi
    
    # Quick process check
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "Process running (PID: $PID)"
        else
            echo "Process dead (PID: $PID)"
        fi
    else
        echo "No PID file"
    fi
    
    # Test endpoint
    if curl -s -f "http://localhost:30080/v1/models" > /dev/null 2>&1; then
        echo ""
        echo "SUCCESS: RayServe service is ready!"
        echo "Service URL: http://localhost:30080"
        echo "Total time: ${ELAPSED_TIME}s"
        exit 0
    fi
    
    echo ""
    sleep $POLL_INTERVAL
done 