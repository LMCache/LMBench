#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
cd "$SCRIPT_DIR"

if [[ $# -lt 11 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> <num_users> <num_rounds> <prompt_len> <answer_len> <name> <serving_index> <spec_file_path> <lmbench_session_id> [qps_values...]"
    echo "Example: $0 meta-llama/Llama-3.1-8B-Instruct http://localhost:8000 test 50 5 100 50 random-benchmark 0 0-bench-specs/random-spec.yaml session123 1.0"
    exit 1
fi

MODEL=$1
BASE_URL=$2
KEY=$3

# Configuration
NUM_USERS=$4
NUM_ROUNDS=$5
PROMPT_LEN=$6
ANSWER_LEN=$7
NAME=$8
SERVING_INDEX=$9
SPEC_FILE_PATH=${10}
LMBENCH_SESSION_ID=${11}

# If QPS values are provided, use them; otherwise use default
if [ $# -gt 11 ]; then
    QPS_VALUES=("${@:12}")
else
    QPS_VALUES=(1.0)  # Default QPS value
fi

# init-user-id starts at 1, will add 400 each iteration
INIT_USER_ID=1

run_benchmark() {
    local qps=$1
    local output_file="../../4-latest-results/${KEY}_random_output_${qps}.csv"

    echo "Running random benchmark with QPS=$qps..."
    python3 "${SCRIPT_DIR}/random-qa.py" \
        --num-users "$NUM_USERS" \
        --prompt-len "$PROMPT_LEN" \
        --answer-len "$ANSWER_LEN" \
        --num-rounds "$NUM_ROUNDS" \
        --qps "$qps" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --init-user-id "$INIT_USER_ID" \
        --output "$output_file" \
        --time 100 \
        --request-with-user-id

    sleep 10

    # increment init-user-id by NUM_USERS for next iteration
    INIT_USER_ID=$(( INIT_USER_ID + NUM_USERS ))
}

# Run benchmarks for each QPS value
for qps in "${QPS_VALUES[@]}"; do
    run_benchmark "$qps"

    # Change to project root before running summarize.py
    cd "$PROJECT_ROOT"

    python3 "4-latest-results/post-processing/summarize.py" \
        "4-latest-results/${KEY}_random_output_${qps}.csv" \
        NAME="$NAME" \
        KEY="$KEY" \
        WORKLOAD="random" \
        NUM_USERS="$NUM_USERS" \
        NUM_ROUNDS="$NUM_ROUNDS" \
        PROMPT_LEN="$PROMPT_LEN" \
        ANSWER_LEN="$ANSWER_LEN" \
        QPS="$qps" \
        SERVING_INDEX="$SERVING_INDEX" \
        SPEC_FILE_PATH="$SPEC_FILE_PATH" \
        LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
        AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
        API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"

    # Change back to script directory
    cd "$SCRIPT_DIR"
done

# Debugging:
# python3 "4-latest-results/post-processing/summarize.py" \
#     "4-latest-results/stack_random_output_1.0.csv" \
#     KEY="stack" \
#     WORKLOAD="random" \
#     NUM_USERS="50" \
#     NUM_ROUNDS="5" \
#     PROMPT_LEN="100" \
#     ANSWER_LEN="50" \
#     QPS="1.0"

# Hard coded command to try at terminal
# python3 "3-workloads/random/random-qa.py" \
#     --num-users "50" \
#     --prompt-len "100" \
#     --answer-len "50" \
#     --num-rounds "5" \
#     --qps "1.0" \
#     --model "meta-llama/Llama-3.1-8B-Instruct" \
#     --base-url "http://localhost:30080/v1/" \
#     --init-user-id "1" \
#     --output "4-latest-results/stack_random_output_1.0.csv" \
#     --time 100
