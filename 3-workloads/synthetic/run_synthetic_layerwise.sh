#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
cd "$SCRIPT_DIR"

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> [qps_values...]"
    echo "Example: $0 meta-llama/Llama-3.1-8B-Instruct http://localhost:8000 test 15 20 25"
    exit 1
fi

MODEL=$1
BASE_URL=$2
KEY=$3

# Configuration
NUM_USERS_WARMUP=$4
NUM_USERS=$5
NUM_ROUNDS=$6
SYSTEM_PROMPT=$7
CHAT_HISTORY=$8
ANSWER_LEN=$9
USE_SHAREGPT=${10}
# If QPS values are provided, use them; otherwise use default
if [ $# -gt 10 ]; then
    QPS_VALUES=("${@:11}")
else
    QPS_VALUES=(0.7)  # Default QPS value
fi

# init-user-id starts at 1, will add 400 each iteration
INIT_USER_ID=1

warmup() {
    echo "Warming up with QPS=$((NUM_USERS_WARMUP / 2))..."
    python3 "${SCRIPT_DIR}/multi-round-qa.py" \
        --num-users 1 \
        --num-rounds 2 \
        --qps 2 \
        --shared-system-prompt "$(echo -n "$SYSTEM_PROMPT" | wc -w)" \
        --user-history-prompt $CHAT_HISTORY \
        --answer-len $ANSWER_LEN \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --init-user-id "$INIT_USER_ID" \
        --output /tmp/warmup.csv \
        --log-interval 30 \
        --time $((NUM_USERS_WARMUP / 2))
}

run_benchmark() {
    local qps=$1
    local output_file="../../4-latest-results/${KEY}_synthetic_output_${qps}.csv"

    # warmup with current init ID
    warmup

    # actual benchmark with same init ID
    echo "Running benchmark with QPS=$qps..."
    python3 "${SCRIPT_DIR}/multi-round-qa.py" \
        --num-users "$NUM_USERS" \
        --shared-system-prompt "$(echo -n "$SYSTEM_PROMPT" | wc -w)" \
        --user-history-prompt $CHAT_HISTORY \
        --answer-len "$ANSWER_LEN" \
        --num-rounds "$NUM_ROUNDS" \
        --qps "$qps" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --init-user-id "$INIT_USER_ID" \
        --output "$output_file" \
        --time 100

    sleep 10

    # increment init-user-id by NUM_USERS_WARMUP
    INIT_USER_ID=$(( INIT_USER_ID + NUM_USERS_WARMUP ))
}

# Run benchmarks for each QPS value
for qps in "${QPS_VALUES[@]}"; do
    run_benchmark "$qps"

    # Change to project root before running summarize.py
    cd "$PROJECT_ROOT"

    python3 "4-latest-results/post-processing/summarize.py" \
        "4-latest-results/${KEY}_synthetic_output_${qps}.csv" \
        KEY="$KEY" \
        WORKLOAD="synthetic" \
        NUM_USERS_WARMUP="$NUM_USERS_WARMUP" \
        NUM_USERS="$NUM_USERS" \
        NUM_ROUNDS="$NUM_ROUNDS" \
        SYSTEM_PROMPT="$SYSTEM_PROMPT" \
        CHAT_HISTORY="$CHAT_HISTORY" \
        ANSWER_LEN="$ANSWER_LEN" \
        QPS="$qps" \
        USE_SHAREGPT="$USE_SHAREGPT"

    # Change back to script directory
    cd "$SCRIPT_DIR"
done

# Debugging:
# python3 "4-latest-results/post-processing/summarize.py" \
#     "4-latest-results/stack_synthetic_output_0.7.csv" \
#     KEY="stack" \
#     WORKLOAD="synthetic" \
#     NUM_USERS_WARMUP="750" \
#     NUM_USERS="350" \
#     NUM_ROUNDS="20" \
#     SYSTEM_PROMPT="0" \
#     CHAT_HISTORY="20000" \
#     ANSWER_LEN="1000" \
#     QPS="0.7" \
#     USE_SHAREGPT="false"
