#!/bin/bash

# VLLMBenchmark workload script
# This script runs the vLLM benchmark serving script with specified parameters

# Script parameters from run-bench.py:
# $1 = MODEL_URL
# $2 = BASE_URL (http://localhost:30080/v1/)
# $3 = KEY (baseline identifier)
# $4 = BACKEND
# $5 = DATASET_NAME
# $6 = DATASET_PATH
# $7 = NUM_PROMPTS
# $8 = BENCHMARK_NAME
# $9 = SERVING_INDEX
# $10 = SPEC_FILE_PATH
# $11 = REQUEST_RATE
# $12+ = Additional arguments

# Set up paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check if using SLURM
if [[ "$SLURM_JOB_ID" != "" ]]; then
    echo "SLURM detected. Setting up environment..."
    cd "$BASE_DIR"
    source lmbench_venv/bin/activate || {
        echo "Error: Could not activate virtual environment at $BASE_DIR/lmbench_venv/bin/activate"
        exit 1
    }
fi

# Parse arguments
MODEL_URL="$1"
BASE_URL="$2"
KEY="$3"
BACKEND="$4"
DATASET_NAME="$5"
DATASET_PATH="$6"
NUM_PROMPTS="$7"
BENCHMARK_NAME="$8"
SERVING_INDEX="$9"
SPEC_FILE="${10}"
REQUEST_RATE="${11}"
shift 11  # Remove first 11 arguments
ADDITIONAL_ARGS="$@"  # Remaining arguments

# Validate required arguments
if [[ -z "$MODEL_URL" || -z "$BASE_URL" || -z "$KEY" || -z "$BACKEND" || -z "$DATASET_NAME" || -z "$NUM_PROMPTS" || -z "$REQUEST_RATE" ]]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 <model_url> <base_url> <key> <backend> <dataset_name> <dataset_path> <num_prompts> <benchmark_name> <serving_index> <spec_file> <request_rate> [additional_args...]"
    exit 1
fi

# Create output directory
mkdir -p "$BASE_DIR/4-latest-results"

# Generate timestamp for output file
TIMESTAMP=$(date +%Y%m%d-%H%M)
OUTPUT_JSON="$BASE_DIR/4-latest-results/${KEY}_${BACKEND}_benchmark_${REQUEST_RATE}_${TIMESTAMP}.json"
OUTPUT_CSV="$BASE_DIR/4-latest-results/${KEY}_${BACKEND}_benchmark_${REQUEST_RATE}_${TIMESTAMP}.csv"

echo "Script directory: $SCRIPT_DIR"
echo "Base directory: $BASE_DIR"

echo "Running VLLMBenchmark workload:"
echo "  Model: $MODEL_URL"
echo "  Base URL: $BASE_URL"
echo "  Key: $KEY"
echo "  Backend: $BACKEND"
echo "  Dataset: $DATASET_NAME"
echo "  Dataset Path: $DATASET_PATH"
echo "  Num Prompts: $NUM_PROMPTS"
echo "  Request Rate: $REQUEST_RATE"
echo "  Output File: $OUTPUT_CSV"
echo "  Additional Args: $ADDITIONAL_ARGS"

# Check server connectivity
echo "Checking server connectivity..."
if ! curl -s --connect-timeout 5 "${BASE_URL%/v1}/v1/models" >/dev/null 2>&1; then
    echo "Warning: Server connectivity check failed. Proceeding anyway..."
else
    echo "Server appears to be reachable"
fi

# Change to the script directory
cd "$SCRIPT_DIR" || {
    echo "Error: Could not change to script directory: $SCRIPT_DIR"
    exit 1
}

# Build command arguments
BENCHMARK_CMD="python benchmark_serving.py --backend $BACKEND --base-url ${BASE_URL%/v1} --model $MODEL_URL --dataset-name $DATASET_NAME --num-prompts $NUM_PROMPTS --request-rate $REQUEST_RATE --save-result --result-dir ../../4-latest-results --result-filename $(basename "$OUTPUT_JSON")"

# Add dataset path if provided - convert to absolute path if it's relative
if [[ -n "$DATASET_PATH" && "$DATASET_PATH" != "\"\"" && "$DATASET_PATH" != "''" ]]; then
    # Check if the path is already absolute
    if [[ "$DATASET_PATH" = /* ]]; then
        # Already absolute path
        BENCHMARK_CMD="$BENCHMARK_CMD --dataset-path $DATASET_PATH"
    else
        # Relative path - convert to absolute path from base directory
        ABS_DATASET_PATH="$BASE_DIR/$DATASET_PATH"
        if [[ -f "$ABS_DATASET_PATH" ]]; then
            BENCHMARK_CMD="$BENCHMARK_CMD --dataset-path $ABS_DATASET_PATH"
        else
            echo "Warning: Dataset file not found at $ABS_DATASET_PATH, using original path"
            BENCHMARK_CMD="$BENCHMARK_CMD --dataset-path $DATASET_PATH"
        fi
    fi
fi

# Add additional arguments
if [[ -n "$ADDITIONAL_ARGS" ]]; then
    BENCHMARK_CMD="$BENCHMARK_CMD $ADDITIONAL_ARGS"
fi

echo "Executing: $BENCHMARK_CMD"
echo

# Execute the benchmark
if eval "$BENCHMARK_CMD"; then
    echo "VLLMBenchmark completed successfully"

    # Convert JSON to CSV
    echo "Converting JSON to CSV format..."
    python3 -c "
import json
import csv
import sys
import os

json_file = '$OUTPUT_JSON'
csv_file = '$OUTPUT_CSV'

try:
    if not os.path.exists(json_file):
        print('Warning: JSON file not found: {}'.format(json_file))
        sys.exit(0)

    with open(json_file, 'r') as f:
        data = json.load(f)

    # Write CSV header and data
    with open(csv_file, 'w', newline='') as f:
        writer = csv.writer(f)

        # Write header
        if isinstance(data, dict):
            writer.writerow(['metric', 'value'])
            for key, value in data.items():
                writer.writerow([key, value])
        elif isinstance(data, list) and data:
            # If it's a list of dicts, use the keys of the first dict as headers
            if isinstance(data[0], dict):
                writer.writerow(data[0].keys())
                for item in data:
                    writer.writerow(item.values())

    print('Converted to CSV: {}'.format(csv_file))

except Exception as e:
    print('Error converting JSON to CSV: {}'.format(e))
"
else
    echo "VLLMBenchmark failed with exit code $?"
    exit 1
fi
