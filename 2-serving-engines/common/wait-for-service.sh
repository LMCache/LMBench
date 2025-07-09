#!/bin/bash
set -e

# Common wait script for all serving baselines
# Usage: wait-for-service.sh [timeout_seconds] [baseline_name] [script_directory]

DEFAULT_TIMEOUT=600  # 10 minutes default
TIMEOUT=${1:-$DEFAULT_TIMEOUT}
BASELINE_NAME=${2:-"Service"}
SCRIPT_DIR=${3:-$(pwd)}
BASE_URL="http://localhost:30080"

echo "=== Waiting for $BASELINE_NAME service to be ready ==="
echo "Target URL: $BASE_URL"
echo "Timeout: $TIMEOUT seconds"
echo "Checking every 5 seconds..."

start_time=$(date +%s)
elapsed=0

# Function to check if service is ready
check_service_ready() {
    local models_response
    local health_response
    
    # Try to curl the models endpoint
    if models_response=$(curl -s -m 10 "$BASE_URL/v1/models" 2>/dev/null); then
        if echo "$models_response" | grep -q "object.*list" || echo "$models_response" | grep -q "data"; then
            echo "✅ Models endpoint returned valid response"
            return 0
        else
            echo "⚠️  Models endpoint returned unexpected response: $models_response"
        fi
    else
        echo "❌ Models endpoint not accessible"
    fi
    
    # Try basic health check
    if health_response=$(curl -s -m 10 "$BASE_URL/health" 2>/dev/null); then
        echo "ℹ️  Health endpoint response: $health_response"
    fi
    
    # Try root endpoint
    if curl -s -m 10 "$BASE_URL" >/dev/null 2>&1; then
        echo "ℹ️  Root endpoint is responding"
    else
        echo "❌ Root endpoint not responding"
    fi
    
    return 1
}

# Function to show what's running on port 30080
show_port_info() {
    echo "📊 Port 30080 status:"
    if command -v netstat >/dev/null; then
        netstat -tlnp 2>/dev/null | grep ":30080" || echo "  No process listening on port 30080"
    elif command -v ss >/dev/null; then
        ss -tlnp 2>/dev/null | grep ":30080" || echo "  No process listening on port 30080"
    else
        echo "  netstat/ss not available"
    fi
    
    echo "🔍 Processes that might be relevant:"
    ps aux | grep -E "(dynamo|sglang|ray|llm-d|vllm)" | grep -v grep || echo "  No relevant processes found"
}

# Function to show recent logs (if available)
show_recent_logs() {
    local log_file="$1"
    # Check current directory first
    if [ -f "$log_file" ]; then
        echo "📝 Recent logs from $log_file:"
        tail -10 "$log_file" | sed 's/^/  /'
    # Check script directory if provided
    elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$log_file" ]; then
        echo "📝 Recent logs from $SCRIPT_DIR/$log_file:"
        tail -10 "$SCRIPT_DIR/$log_file" | sed 's/^/  /'
    else
        echo "📝 Log file $log_file not found"
    fi
}

# Main wait loop
while [ $elapsed -lt $TIMEOUT ]; do
    echo "⏳ Checking service readiness... (elapsed: ${elapsed}s)"
    
    if check_service_ready; then
        echo "🎉 $BASELINE_NAME service is ready after ${elapsed}s!"
        exit 0
    fi
    
    # Show diagnostic info every 30 seconds
    if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
        echo "🔍 Diagnostic info at ${elapsed}s:"
        show_port_info
        
        # Show logs if they exist
        show_recent_logs "dynamo_serve.log"
        show_recent_logs "sglang.log"
        show_recent_logs "rayserve.log"
    fi
    
    echo "😴 Service not ready yet... waiting 5 seconds (elapsed: ${elapsed}s)"
    sleep 5
    
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
done

echo "💥 ERROR: Timeout waiting for $BASELINE_NAME service to become ready after $TIMEOUT seconds"
echo "🔍 Final diagnostic info:"
show_port_info
show_recent_logs "dynamo_serve.log"
show_recent_logs "sglang.log"
show_recent_logs "rayserve.log"

exit 1 