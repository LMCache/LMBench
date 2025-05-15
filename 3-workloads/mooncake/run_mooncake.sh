#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../" && pwd )"
cd "$SCRIPT_DIR"

if [[ $# -ne 7 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> <num rounds> <system prompt> <chat history> <answer len>"
    exit 1
fi

MODEL=$1
BASE_URL=$2
KEY=$3

# CONFIGURATION
NUM_ROUNDS=$4
SYSTEM_PROMPT=$5 # Shared system prompt length
CHAT_HISTORY=$6 # User specific chat history length
ANSWER_LEN=$7 # Generation length per round

run_mooncake() {
    # $1: qps
    # $2: output file

    # Real run
    python3 ./mooncake-qa.py \
        --num-rounds $NUM_ROUNDS \
        --qps "$1" \
        --shared-system-prompt "$SYSTEM_PROMPT" \
        --user-history-prompt "$CHAT_HISTORY" \
        --answer-len $ANSWER_LEN \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --output "$2" \
        --log-interval 30 \
        --time 100 \
        --slowdown-factor 1

    sleep 10
}
# Run benchmarks for different QPS values

QPS_VALUES=(1)

# prepare the mooncake data
chmod +x ./prepare_mooncake.sh
./prepare_mooncake.sh

# Run benchmarks for the determined QPS values
for qps in "${QPS_VALUES[@]}"; do
    output_file="../../4-latest-results/${KEY}_mooncake_output_${qps}.csv"
    run_mooncake "$qps" "$output_file"

    # Change to project root before running summarize.py
    cd "$PROJECT_ROOT"
    python3 "4-latest-results/post-processing/summarize.py" \
        "4-latest-results/${output_file#../../}" \
        KEY="$KEY" \
        WORKLOAD="mooncake" \
        NUM_ROUNDS="$NUM_ROUNDS" \
        SYSTEM_PROMPT="$SYSTEM_PROMPT" \
        CHAT_HISTORY="$CHAT_HISTORY" \
        ANSWER_LEN="$ANSWER_LEN" \
        QPS="$qps"

    # Change back to script directory
    cd "$SCRIPT_DIR"
done
