#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../" && pwd )"
cd "$SCRIPT_DIR"

if [[ $# -lt 13 ]]; then
    echo "Usage: $0 \"<model list>\" <base url> <save file key> <num_users_warmup> <num_agents> <num_rounds> <system_prompt> <chat_history> <answer_len> <name> <serving_index> <spec_file_path> <lmbench_session_id> [new_user_intervals...]"
    echo "Example: $0 \"meta-llama/Llama-3.1-8B-Instruct\" http://localhost:8000 test 100 10 10 0 100 20 layerwise-benchmark 0 0-bench-specs/layerwise-spec.yaml lmbench-1234567890-abcd1234 1 2"
    exit 1
fi

MODEL_LIST="$1"      # Space-separated models, e.g. "gpt-3.5-turbo gpt-4"
BASE_URL=$2
KEY=$3

# Configuration
NUM_USERS_WARMUP=$4
NUM_AGENTS=$5
NUM_ROUNDS=$6
SYSTEM_PROMPT=$7
CHAT_HISTORY=$8
ANSWER_LEN=$9
NAME=${10}
SERVING_INDEX=${11}
SPEC_FILE_PATH=${12}
LMBENCH_SESSION_ID=${13}

# Optional QPS-like values (we'll use as new-user-intervals here)
if [ $# -gt 13 ]; then
    NEW_USER_INTERVALS=("${@:14}")
else
    NEW_USER_INTERVALS=(2)  # Default new user interval
fi

# init-user-id starts at 1, will add 400 each iteration
INIT_USER_ID=1

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

warmup() {
    echo "Warming up with agent count=$NUM_AGENTS..."
    python3 "${SCRIPT_DIR}/agentic-qa.py" \
        --num-agents "$NUM_AGENTS" \
        --num-rounds 2 \
        --shared-system-prompt "$SYSTEM_PROMPT" \
        --user-history-prompt "$CHAT_HISTORY" \
        --answer-len "$ANSWER_LEN" \
        --model $MODEL_LIST \
        --base-url "$BASE_URL" \
        --user-request-interval 1 \
        --new-user-interval 2 \
        --output /tmp/warmup.csv \
        --log-interval 30 \
        --time $((NUM_USERS_WARMUP / 2))
}

run_benchmark() {
    local new_user_interval=$1
    local output_file="../../4-latest-results/${KEY}_agentic_output_${new_user_interval}.csv"

    # warmup with current init ID
    warmup

    # actual benchmark with same init ID
    echo "Running benchmark with new_user_interval=$new_user_interval..."
    python3 "${SCRIPT_DIR}/agentic-qa.py" \
        --num-agents "$NUM_AGENTS" \
        --shared-system-prompt "$SYSTEM_PROMPT" \
        --user-history-prompt "$CHAT_HISTORY" \
        --answer-len "$ANSWER_LEN" \
        --num-rounds "$NUM_ROUNDS" \
        --model $MODEL_LIST \
        --base-url "$BASE_URL" \
        --user-request-interval 1 \
        --new-user-interval "$new_user_interval" \
        --output "$output_file" \
        --time 100

    sleep 10

    # increment init-user-id by NUM_USERS_WARMUP
    INIT_USER_ID=$(( INIT_USER_ID + NUM_USERS_WARMUP ))
}

# Run benchmarks for each new_user_interval value
for interval in "${NEW_USER_INTERVALS[@]}"; do
    run_benchmark "$interval"
    output_file="../../4-latest-results/${KEY}_agentic_output_${interval}.csv"

    # Collect pod logs after benchmark completion
    collect_pod_logs "$KEY" "agentic" "$interval"

    # Change to project root before running summarize.py
    cd "$PROJECT_ROOT"
    python3 "4-latest-results/post-processing/summarize.py" \
        "${output_file#../../}" \
        NAME="$NAME" \
        KEY="$KEY" \
        WORKLOAD="agentic" \
        NUM_USERS_WARMUP="$NUM_USERS_WARMUP" \
        NUM_AGENTS="$NUM_AGENTS" \
        NUM_ROUNDS="$NUM_ROUNDS" \
        SYSTEM_PROMPT="$SYSTEM_PROMPT" \
        CHAT_HISTORY="$CHAT_HISTORY" \
        ANSWER_LEN="$ANSWER_LEN" \
        NEW_USER_INTERVAL="$interval" \
        SERVING_INDEX="$SERVING_INDEX" \
        SPEC_FILE_PATH="$SPEC_FILE_PATH" \
        LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
        AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
        API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"

    # Change back to script directory
    cd "$SCRIPT_DIR"
done