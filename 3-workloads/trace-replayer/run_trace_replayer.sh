#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../" && pwd )"
cd "$SCRIPT_DIR"

if [[ $# -lt 14 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> <n> <serving_index> <spec_file_path> <lmbench_session_id> <trace_file> <start_time> <duration> <preserve_timing> <time_scale> <api_type> <max_delay> [qps_values...]"
    echo "Example: $0 meta-llama/Llama-3.1-8B-Instruct http://localhost:30080 test layerwise-benchmark 0 0-bench-specs/layerwise-spec.yaml lmbench-1234567890-abcd1234 traces/gmi_trace.jsonl 0 60 false 1.0 completions 10.0 1.0 2.0"
    exit 1
fi

MODEL=$1
BASE_URL=$2
KEY=$3
NAME=$4
SERVING_INDEX=$5
SPEC_FILE_PATH=$6
LMBENCH_SESSION_ID=$7

# Trace replayer specific parameters
TRACE_FILE=$8
START_TIME=$9
DURATION=${10}
PRESERVE_TIMING=${11}
TIME_SCALE=${12}
API_TYPE=${13}
MAX_DELAY=${14}  # Maximum delay between requests (for testing production traces)

QPS_VALUES=("${@:15}")  # QPS values for QPS-controlled mode

collect_pod_logs() {
    local baseline="$1"
    local workload="$2"
    local qps="$3"

    echo "📝 Collecting pod logs for baseline: $baseline, workload: $workload, QPS: $qps"

    # Create artifact directory structure
    LOGS_DIR="$PROJECT_ROOT/4-latest-results/$NAME/pod-logs"
    mkdir -p "$LOGS_DIR"

    # Get all pod names
    ALL_PODS=$(kubectl get pods -o name 2>/dev/null | sed 's/pod\///')

    if [ -n "$ALL_PODS" ]; then
        echo "📋 Found $(echo "$ALL_PODS" | wc -l) pods to collect logs from:"
        echo "$ALL_PODS"

        # Collect logs from each pod
        echo "$ALL_PODS" | while read pod; do
            if [ -n "$pod" ]; then
                LOG_FILE="$LOGS_DIR/${pod}_${baseline}_${workload}_${qps}.log"
                echo "📥 Collecting logs from pod: $pod"
                kubectl logs "$pod" > "$LOG_FILE" 2>&1

                # Also collect previous logs if available (in case of restarts)
                PREV_LOG_FILE="$LOGS_DIR/${pod}_${baseline}_${workload}_${qps}_previous.log"
                kubectl logs "$pod" --previous > "$PREV_LOG_FILE" 2>/dev/null || rm -f "$PREV_LOG_FILE"

                # Collect pod description for debugging
                DESC_FILE="$LOGS_DIR/${pod}_${baseline}_${workload}_${qps}_describe.txt"
                kubectl describe pod "$pod" > "$DESC_FILE" 2>&1
            fi
        done

        echo "✅ Pod logs collected in: $LOGS_DIR"
    else
        echo "⚠️ No pods found to collect logs from"
    fi
}

run_trace_replayer() {
    # $1: qps (for QPS mode) or "timed" (for timed mode)
    # $2: output file

    if [ "$PRESERVE_TIMING" = "true" ]; then
        # Timed replay mode - preserves original timestamps
        echo "🎬 Running timed replay (preserving original timestamps)"
        cmd="python3 ./trace-replayer-qa.py \
            --model \"$MODEL\" \
            --base-url \"$BASE_URL\" \
            --output \"$2\" \
            --trace-file \"$TRACE_FILE\" \
            --start-time \"$START_TIME\" \
            --duration \"$DURATION\" \
            --preserve-timing \
            --time-scale \"$TIME_SCALE\" \
            --api-type \"$API_TYPE\""
        
        # Add max-delay if specified (not empty or "None")
        if [[ -n "$MAX_DELAY" && "$MAX_DELAY" != "None" ]]; then
            cmd="$cmd --max-delay \"$MAX_DELAY\""
        fi
        
        eval $cmd
    else
        # QPS-controlled mode
        echo "📊 Running QPS-controlled replay (QPS: $1)"
        cmd="python3 ./trace-replayer-qa.py \
            --model \"$MODEL\" \
            --base-url \"$BASE_URL\" \
            --output \"$2\" \
            --trace-file \"$TRACE_FILE\" \
            --start-time \"$START_TIME\" \
            --duration \"$DURATION\" \
            --qps \"$1\" \
            --api-type \"$API_TYPE\""
        
        # Add max-delay if specified (not empty or "None") - though less useful in QPS mode
        if [[ -n "$MAX_DELAY" && "$MAX_DELAY" != "None" ]]; then
            cmd="$cmd --max-delay \"$MAX_DELAY\""
        fi
        
        eval $cmd
    fi

    sleep 5
}
# Check if trace file exists (support both absolute and relative paths)
TRACE_PATH="$TRACE_FILE"
if [[ ! "$TRACE_FILE" == /* ]] && [[ ! "$TRACE_FILE" == ./* ]]; then
    # If relative path without ./, prepend current directory
    TRACE_PATH="./$TRACE_FILE"
fi

if [ ! -f "$TRACE_PATH" ]; then
    echo "Error: Trace file $TRACE_PATH not found"
    echo "Available trace files:"
    echo "  In traces/ directory:"
    ls -la traces/*.jsonl 2>/dev/null || echo "    No .jsonl files found in traces/"
    echo "  In current directory:"
    ls -la *.jsonl 2>/dev/null || echo "    No .jsonl files found in current directory"
    exit 1
fi

# Update TRACE_FILE to use the resolved path
TRACE_FILE="$TRACE_PATH"

# Sort trace file chronologically (idempotent)
echo "🔄 Ensuring trace file is chronologically sorted..."
python3 ./sort_traces.py "$TRACE_FILE"
if [ $? -ne 0 ]; then
    echo "⚠️ Warning: Failed to sort trace file, continuing anyway..."
fi

# Run benchmarks
if [ "$PRESERVE_TIMING" = "true" ]; then
    # Single timed run
    output_file="../../4-latest-results/${KEY}_trace_replayer_timed.csv"
    run_trace_replayer "timed" "$output_file"
    
    # Collect pod logs
    collect_pod_logs "$KEY" "trace_replayer" "timed"
    
    # Post-process results
    cd "$PROJECT_ROOT"
    python3 "4-latest-results/post-processing/summarize.py" \
        "${output_file#../../}" \
        NAME="$NAME" \
        KEY="$KEY" \
        WORKLOAD="trace_replayer" \
        MODE="timed" \
        TRACE_FILE="$TRACE_FILE" \
        START_TIME="$START_TIME" \
        DURATION="$DURATION" \
        TIME_SCALE="$TIME_SCALE" \
        API_TYPE="$API_TYPE" \
        SERVING_INDEX="$SERVING_INDEX" \
        SPEC_FILE_PATH="$SPEC_FILE_PATH" \
        LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
        AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
        API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"
    cd "$SCRIPT_DIR"
else
    # QPS-controlled runs
    for qps in "${QPS_VALUES[@]}"; do
        output_file="../../4-latest-results/${KEY}_trace_replayer_output_${qps}.csv"
        run_trace_replayer "$qps" "$output_file"
        
        # Collect pod logs
        collect_pod_logs "$KEY" "trace_replayer" "$qps"
        
        # Post-process results
        cd "$PROJECT_ROOT"
        python3 "4-latest-results/post-processing/summarize.py" \
            "${output_file#../../}" \
            NAME="$NAME" \
            KEY="$KEY" \
            WORKLOAD="trace_replayer" \
            QPS="$qps" \
            TRACE_FILE="$TRACE_FILE" \
            START_TIME="$START_TIME" \
            DURATION="$DURATION" \
            API_TYPE="$API_TYPE" \
            SERVING_INDEX="$SERVING_INDEX" \
            SPEC_FILE_PATH="$SPEC_FILE_PATH" \
            LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
            AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
            API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"
        cd "$SCRIPT_DIR"
    done
fi
