#!/bin/bash
set -e

echo "=== Waiting for SGLang Baseline Readiness ==="

# Configuration
TIMEOUT=300  # 5 minutes timeout
POLL_INTERVAL=5  # Check every 5 seconds
START_TIME=$(date +%s)

echo "Waiting for SGLang service on localhost:30080..."
echo "Timeout: ${TIMEOUT}s, Poll interval: ${POLL_INTERVAL}s"
echo "Timestamp: $(date)"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$SCRIPT_DIR/sglang.log"
PID_FILE="$SCRIPT_DIR/sglang.pid"

# Function to show recent logs
show_recent_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo "📝 Recent logs from $LOG_FILE:"
        tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  Could not read log file"
    else
        echo "📝 Log file not found: $LOG_FILE"
    fi
}

# Function to check process status
check_process_status() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "✅ SGLang process is running (PID: $PID)"
            return 0
        else
            echo "❌ SGLang process not running (PID file exists but process dead)"
            return 1
        fi
    else
        # Try to find process by command
        SGLANG_PID=$(pgrep -f "sglang_router.launch_server" 2>/dev/null || echo "")
        if [ -n "$SGLANG_PID" ]; then
            echo "✅ SGLang process found (PID: $SGLANG_PID)"
            return 0
        else
            echo "❌ SGLang process not found"
            return 1
        fi
    fi
}

# Function to show port status
show_port_status() {
    echo "📊 Port 30080 status:"
    if command -v netstat >/dev/null; then
        netstat -tlnp 2>/dev/null | grep ":30080" || echo "  No process listening on port 30080"
    elif command -v ss >/dev/null; then
        ss -tlnp 2>/dev/null | grep ":30080" || echo "  No process listening on port 30080"
    else
        echo "  netstat/ss not available"
    fi
}

# Function to show GPU status
show_gpu_status() {
    echo "🖥️  GPU status:"
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -4 | sed 's/^/  /' || echo "  Could not get GPU status"
    else
        echo "  nvidia-smi not available"
    fi
}

# Function to analyze log for errors
analyze_log_errors() {
    if [ -f "$LOG_FILE" ]; then
        echo "🔍 Analyzing log for errors..."
        
        # Check for common error patterns
        if grep -q "ModuleNotFoundError\|ImportError" "$LOG_FILE" 2>/dev/null; then
            echo "  ❌ Found dependency errors:"
            grep -n "ModuleNotFoundError\|ImportError" "$LOG_FILE" | tail -3 | sed 's/^/    /'
        fi
        
        if grep -q "CUDA\|GPU" "$LOG_FILE" 2>/dev/null; then
            echo "  🖥️  Found GPU-related messages:"
            grep -n "CUDA\|GPU" "$LOG_FILE" | tail -3 | sed 's/^/    /'
        fi
        
        if grep -q "Error\|Exception\|Failed" "$LOG_FILE" 2>/dev/null; then
            echo "  ⚠️  Found error messages:"
            grep -n "Error\|Exception\|Failed" "$LOG_FILE" | tail -3 | sed 's/^/    /'
        fi
        
        # Check for successful startup indicators
        if grep -q "Uvicorn running\|server started\|listening\|ready" "$LOG_FILE" 2>/dev/null; then
            echo "  ✅ Found positive startup indicators:"
            grep -n "Uvicorn running\|server started\|listening\|ready" "$LOG_FILE" | tail -2 | sed 's/^/    /'
        fi
    fi
}

# Main wait loop
consecutive_failures=0
max_consecutive_failures=6  # 30 seconds of consecutive failures

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    # Check timeout
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        echo "💥 ERROR: Timeout reached! SGLang service not ready after ${TIMEOUT}s"
        echo ""
        echo "🔍 Final diagnostic information:"
        check_process_status
        show_port_status
        show_gpu_status
        echo ""
        analyze_log_errors
        echo ""
        show_recent_logs
        exit 1
    fi
    
    echo "⏳ Checking service readiness... (elapsed: ${ELAPSED_TIME}s)"
    
    # Check if process is still running
    if ! check_process_status; then
        consecutive_failures=$((consecutive_failures + 1))
        echo "⚠️  Process check failed (consecutive failures: $consecutive_failures/$max_consecutive_failures)"
        
        if [ $consecutive_failures -ge $max_consecutive_failures ]; then
            echo "💥 ERROR: SGLang process has been down for $((consecutive_failures * POLL_INTERVAL)) seconds"
            echo ""
            echo "🔍 Diagnostic information:"
            show_port_status
            show_gpu_status
            echo ""
            analyze_log_errors
            echo ""
            show_recent_logs
            exit 1
        fi
    else
        consecutive_failures=0
    fi
    
    # Test /v1/models endpoint
    if curl -s -f "http://localhost:30080/v1/models" > /dev/null 2>&1; then
        echo "🎉 SUCCESS: SGLang service is ready on localhost:30080 (took ${ELAPSED_TIME}s)"
        
        # Verify we can also hit /v1/chat/completions
        if curl -s -f -X POST "http://localhost:30080/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "test"}], "max_tokens": 1}' > /dev/null 2>&1; then
            echo "✅ SUCCESS: Chat completions endpoint also working"
        else
            echo "⚠️  WARNING: Models endpoint ready but chat completions may not be fully ready yet"
        fi
        
        echo ""
        echo "=== SGLang service is fully ready ==="
        echo "🔗 Service URL: http://localhost:30080"
        echo "📝 Log file: $LOG_FILE"
        if [ -f "$PID_FILE" ]; then
            echo "🆔 Process ID: $(cat "$PID_FILE" 2>/dev/null || echo "unknown")"
        fi
        echo ""
        exit 0
    else
        echo "❌ Service endpoint not responding yet..."
    fi
    
    # Show diagnostic info every 30 seconds
    if [ $((ELAPSED_TIME % 30)) -eq 0 ] && [ $ELAPSED_TIME -gt 0 ]; then
        echo ""
        echo "🔍 Diagnostic info at ${ELAPSED_TIME}s:"
        show_port_status
        
        # Show log file growth
        if [ -f "$LOG_FILE" ]; then
            LOG_SIZE=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
            echo "📊 Log file has $LOG_SIZE lines"
            
            # Show recent non-empty lines
            RECENT_LOGS=$(tail -3 "$LOG_FILE" 2>/dev/null | grep -v "^$" | head -2)
            if [ -n "$RECENT_LOGS" ]; then
                echo "📝 Recent log activity:"
                echo "$RECENT_LOGS" | sed 's/^/  /'
            fi
        fi
        echo ""
    fi
    
    echo "😴 Service not ready yet... waiting ${POLL_INTERVAL} seconds (elapsed: ${ELAPSED_TIME}s)"
    sleep $POLL_INTERVAL
done 