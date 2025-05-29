#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../../" && pwd )"
cd "$SCRIPT_DIR"

# Set the path to the 4-latest-results directory

if [[ $# -lt 8 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> <limit> <min_rounds> <start_round> <name> <serving_index> [qps_values...]"
    echo "Example: $0 meta-llama/Llama-3.1-8B-Instruct http://localhost:8000 /mnt/requests/sharegpt-run1 1000 10 0 layerwise-benchmark 0 1.34 2.0 3.0"
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

# If QPS values are provided, use them; otherwise use default
if [[ $# -gt 8 ]]; then
    QPS_VALUES=("${@:9}")
else
    QPS_VALUES=(1.34)  # Default QPS value
fi

warm_up() {
    # $1: qps
    # $2: output file

    python3 "${SCRIPT_DIR}/sharegpt-qa.py" \
        --qps "$1" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --output /tmp/warmup.csv \
        --log-interval 30 \
        --sharegpt-file "../warmup.json"

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
        --sharegpt-file "../run.json"

    sleep 10
}

# Run benchmarks for the specified QPS values
for qps in "${QPS_VALUES[@]}"; do
    output_file="../../../4-latest-results/${KEY}_sharegpt_output_${qps}.csv"
    warm_up "$qps"
    run_benchmark "$qps" "$output_file"

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
        SERVING_INDEX="$SERVING_INDEX"
    # Change back to script directory
    cd "$SCRIPT_DIR"
done