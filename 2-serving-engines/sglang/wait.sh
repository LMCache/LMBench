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

# Function to show recent logs with more context - brief version for frequent polling
show_recent_logs_brief() {
    if [ -f "$LOG_FILE" ]; then
        # Show last 3 non-empty lines for frequent polling
        RECENT_LOGS=$(tail -10 "$LOG_FILE" 2>/dev/null | grep -v "^$" | tail -3)
        if [ -n "$RECENT_LOGS" ]; then
            echo "📝 Recent logs:"
            echo "$RECENT_LOGS" | sed 's/^/  /'
        else
            LOG_SIZE=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
            echo "📝 Log file has $LOG_SIZE lines (no recent activity)"
        fi
    else
        echo "📝 Log file not found: $LOG_FILE"
    fi
}

# Function to show full recent logs for detailed diagnostics
show_recent_logs_full() {
    if [ -f "$LOG_FILE" ]; then
        echo "📝 Recent logs from $LOG_FILE:"
        tail -15 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  Could not read log file"
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
        PORT_INFO=$(netstat -tlnp 2>/dev/null | grep ":30080" || echo "")
        if [ -n "$PORT_INFO" ]; then
            echo "  ✅ $PORT_INFO"
        else
            echo "  ❌ No process listening on port 30080"
        fi
    elif command -v ss >/dev/null; then
        PORT_INFO=$(ss -tlnp 2>/dev/null | grep ":30080" || echo "")
        if [ -n "$PORT_INFO" ]; then
            echo "  ✅ $PORT_INFO"
        else
            echo "  ❌ No process listening on port 30080"
        fi
    else
        echo "  ⚠️  netstat/ss not available"
    fi
}

# Function to show GPU status
show_gpu_status() {
    echo "🖥️  GPU status:"
    if command -v nvidia-smi >/dev/null; then
        GPU_STATUS=$(nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "")
        if [ -n "$GPU_STATUS" ]; then
            echo "$GPU_STATUS" | head -4 | while read line; do
                echo "  GPU $line"
            done
        else
            echo "  ⚠️  Could not get GPU status"
        fi
    else
        echo "  ⚠️  nvidia-smi not available"
    fi
}

# Function to analyze log for errors
analyze_log_errors() {
    if [ -f "$LOG_FILE" ]; then
        echo "🔍 Log analysis:"
        
        # Count errors and warnings
        ERRORS=$(grep -c "Error\|Exception\|Failed\|ModuleNotFoundError\|ImportError" "$LOG_FILE" 2>/dev/null || echo "0")
        WARNINGS=$(grep -c "Warning\|WARN" "$LOG_FILE" 2>/dev/null || echo "0")
        
        echo "  📊 Error count: $ERRORS, Warning count: $WARNINGS"
        
        # Check for common error patterns
        if [ "$ERRORS" -gt 0 ]; then
            echo "  ❌ Recent errors:"
            grep -n "Error\|Exception\|Failed\|ModuleNotFoundError\|ImportError" "$LOG_FILE" 2>/dev/null | tail -2 | sed 's/^/    /'
        fi
        
        # Check for successful startup indicators
        if grep -q "Uvicorn running\|server started\|listening\|ready\|started successfully" "$LOG_FILE" 2>/dev/null; then
            echo "  ✅ Found positive startup indicators:"
            grep -n "Uvicorn running\|server started\|listening\|ready\|started successfully" "$LOG_FILE" 2>/dev/null | tail -2 | sed 's/^/    /'
        fi
        
        # Check for GPU initialization
        if grep -q "CUDA\|GPU" "$LOG_FILE" 2>/dev/null; then
            echo "  🖥️  GPU activity detected"
            GPU_LINES=$(grep -c "CUDA\|GPU" "$LOG_FILE" 2>/dev/null || echo "0")
            echo "    GPU-related log lines: $GPU_LINES"
        fi
    fi
}

# Main wait loop
consecutive_failures=0
max_consecutive_failures=6  # 30 seconds of consecutive failures
check_count=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    check_count=$((check_count + 1))
    
    echo ""
    echo "⏳ Check #$check_count - Service readiness... (elapsed: ${ELAPSED_TIME}s)"
    
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
        show_recent_logs_full
        exit 1
    fi
    
    # Always show brief logs on every check
    show_recent_logs_brief
    
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
            show_recent_logs_full
            exit 1
        fi
    else
        consecutive_failures=0
    fi
    
    # Show detailed diagnostics every 3 checks (15 seconds) instead of 30
    if [ $((check_count % 3)) -eq 0 ]; then
        echo "🔍 Detailed status:"
        show_port_status
        analyze_log_errors
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
    
    echo "😴 Waiting ${POLL_INTERVAL} seconds..."
    sleep $POLL_INTERVAL
done 