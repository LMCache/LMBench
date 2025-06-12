#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../../" && pwd )"
cd "$SCRIPT_DIR"

# Set the path to the 4-latest-results directory

if [[ $# -lt 10 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> <limit> <min_rounds> <start_round> <name> <serving_index> <spec_file_path> <lmbench_session_id> [qps_values...]"
    echo "Example: $0 meta-llama/Llama-3.1-8B-Instruct http://localhost:8000 /mnt/requests/sharegpt-run1 1000 10 0 layerwise-benchmark 0 0-bench-specs/layerwise-spec.yaml lmbench-1234567890-abcd1234 1.34 2.0 3.0"
    exit 1
fi

MODEL=$1
BASE_URL=$2
KEY=$3
LIMIT=$4
MIN_ROUNDS=$5
START_ROUND=$6
NAME=$7
SERVING_INDEX=$8
SPEC_FILE_PATH=$9
LMBENCH_SESSION_ID=${10}

# If QPS values are provided, use them; otherwise use default
if [[ $# -gt 10 ]]; then
    QPS_VALUES=("${@:11}")
else
    QPS_VALUES=(1.34)  # Default QPS value
fi

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

warm_up() {
    # $1: qps
    # $2: output file

    python3 "${SCRIPT_DIR}/sharegpt-qa.py" \
        --qps "$1" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --output /tmp/warmup.csv \
        --log-interval 30 \
        --sharegpt-file "../warmup.json" \
        --request-with-user-id

    sleep 10
}

run_benchmark() {
    # $1: qps
    # $2: output file

    # Real run
    python3 "${SCRIPT_DIR}/sharegpt-qa.py" \
        --qps "$1" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --output "$2" \
        --log-interval 30 \
        --sharegpt-file "../run.json" \
        --request-with-user-id

    sleep 10
}

# Run benchmarks for the specified QPS values
for qps in "${QPS_VALUES[@]}"; do
    output_file="../../../4-latest-results/${KEY}_sharegpt_output_${qps}.csv"
    warm_up "$qps"
    run_benchmark "$qps" "$output_file"

    # Collect pod logs after benchmark completion
    collect_pod_logs "$KEY" "sharegpt" "$qps"

    # Change to project root before running summarize.py
    cd "$PROJECT_ROOT"
    python3 "4-latest-results/post-processing/summarize.py" \
        "${output_file#../../../}" \
        NAME="$NAME" \
        KEY="$KEY" \
        WORKLOAD="sharegpt" \
        LIMIT="$LIMIT" \
        MIN_ROUNDS="$MIN_ROUNDS" \
        START_ROUND="$START_ROUND" \
        QPS="$qps" \
        SERVING_INDEX="$SERVING_INDEX" \
        SPEC_FILE_PATH="$SPEC_FILE_PATH" \
        LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
        AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
        API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"
    # Change back to script directory
    cd "$SCRIPT_DIR"
done