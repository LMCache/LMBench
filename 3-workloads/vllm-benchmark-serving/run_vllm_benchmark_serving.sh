#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../" && pwd )"
cd "$SCRIPT_DIR"

if [[ $# -lt 12 ]]; then
    echo "Usage: $0 <model> <base url> <save file key> <backend> <dataset_name> <dataset_path> <num_prompts> <name> <serving_index> <spec_file_path> <lmbench_session_id> <request_rate> [additional_args...]"
    echo "Example: $0 meta-llama/Llama-3.1-8B-Instruct http://localhost:30080/v1 test vllm random \"\" 100 benchmark-serving-workloads 0 0-bench-specs/helm/benchmark-serving-workloads.yaml session123 1.0 --temperature 0.0"
    exit 1
fi

MODEL=$1
BASE_URL=$2
KEY=$3
BACKEND=$4
DATASET_NAME=$5
DATASET_PATH=$6
NUM_PROMPTS=$7
NAME=$8
SERVING_INDEX=$9
SPEC_FILE_PATH=${10}
LMBENCH_SESSION_ID=${11}
REQUEST_RATE=${12}
shift 12  # Remove first 12 arguments
ADDITIONAL_ARGS="$@"  # Remaining arguments

# Create output directory
mkdir -p "$PROJECT_ROOT/4-latest-results"

# Generate timestamp for output file
TIMESTAMP=$(date +%Y%m%d-%H%M)
OUTPUT_JSON="$PROJECT_ROOT/4-latest-results/${KEY}_vllm_benchmark_${REQUEST_RATE}_${TIMESTAMP}.json"
OUTPUT_CSV="$PROJECT_ROOT/4-latest-results/${KEY}_vllm_benchmark_${REQUEST_RATE}_${TIMESTAMP}.csv"

# Generate workload name: vllm_{DATASET_NAME}_{DATASET_PATH}
# Sanitize dataset path by replacing "/" with "_" and handling empty paths
SANITIZED_DATASET_PATH=""
if [[ -n "$DATASET_PATH" ]]; then
    # Strip the 3-workloads/vllm-benchmark-serving/ prefix if present
    CLEANED_DATASET_PATH="$DATASET_PATH"
    if [[ "$DATASET_PATH" == 3-workloads/vllm-benchmark-serving/* ]]; then
        CLEANED_DATASET_PATH="${DATASET_PATH#3-workloads/vllm-benchmark-serving/}"
    fi
    SANITIZED_DATASET_PATH=$(echo "$CLEANED_DATASET_PATH" | sed 's/\//_/g')
fi

# Create workload name - only include dataset path for "hf" dataset
if [[ "$DATASET_NAME" == "hf" && -n "$SANITIZED_DATASET_PATH" ]]; then
    WORKLOAD_NAME="vllm_${DATASET_NAME}_${SANITIZED_DATASET_PATH}"
else
    WORKLOAD_NAME="vllm_${DATASET_NAME}"
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

echo "Running VLLMBenchmark workload:"
echo "  Model: $MODEL"
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

run_vllm_benchmark() {
    local request_rate=$1
    local output_json=$2
    local output_csv=$3

    # Build command arguments
    local benchmark_cmd="python benchmark_serving.py --backend $BACKEND --base-url ${BASE_URL%/v1} --model $MODEL --dataset-name $DATASET_NAME --num-prompts $NUM_PROMPTS --request-rate $request_rate --save-result --result-dir ../../4-latest-results --result-filename $(basename "$output_json")"

    # Add dataset path if provided - convert to absolute path if it's relative
    if [[ -n "$DATASET_PATH" && "$DATASET_PATH" != "\"\"" && "$DATASET_PATH" != "''" ]]; then
        # Check if the path is already absolute
        if [[ "$DATASET_PATH" = /* ]]; then
            # Already absolute path
            benchmark_cmd="$benchmark_cmd --dataset-path $DATASET_PATH"
        else
            # Relative path - convert to absolute path from base directory
            local abs_dataset_path="$PROJECT_ROOT/$DATASET_PATH"
            if [[ -f "$abs_dataset_path" ]]; then
                benchmark_cmd="$benchmark_cmd --dataset-path $abs_dataset_path"
            else
                echo "Warning: Dataset file not found at $abs_dataset_path, using original path"
                benchmark_cmd="$benchmark_cmd --dataset-path $DATASET_PATH"
            fi
        fi
    fi

    # Add additional arguments
    if [[ -n "$ADDITIONAL_ARGS" ]]; then
        benchmark_cmd="$benchmark_cmd $ADDITIONAL_ARGS"
    fi

    echo "Executing: $benchmark_cmd"
    echo

    # Execute the benchmark
    if eval "$benchmark_cmd"; then
        echo "VLLMBenchmark completed successfully"

        # Convert JSON to CSV
        echo "Converting JSON to CSV format..."
        python3 -c "
import json
import csv
import sys
import os

json_file = '$output_json'
csv_file = '$output_csv'

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
                first_item = data[0]
                headers = []
                for key in first_item:
                    headers.append(key)
                writer.writerow(headers)
                for item in data:
                    row_values = []
                    for key in headers:
                        row_values.append(item.get(key, ''))
                    writer.writerow(row_values)

    print('Converted to CSV: {}'.format(csv_file))

except Exception as e:
    print('Error converting JSON to CSV: {}'.format(e))
"
        return 0
    else
        echo "VLLMBenchmark failed with exit code $?"
        return 1
    fi
}

# Run the benchmark
run_vllm_benchmark "$REQUEST_RATE" "$OUTPUT_JSON" "$OUTPUT_CSV"

if [[ $? -eq 0 ]]; then
    echo "VLLMBenchmark workload completed successfully for request rate $REQUEST_RATE"

    # Collect pod logs after benchmark completion
    collect_pod_logs "$KEY" "$WORKLOAD_NAME" "$REQUEST_RATE"

    # Change to project root before running summarize.py
    cd "$PROJECT_ROOT"
    python3 "4-latest-results/post-processing/summarize.py" \
        "${OUTPUT_CSV#$PROJECT_ROOT/}" \
        NAME="$NAME" \
        KEY="$KEY" \
        WORKLOAD="$WORKLOAD_NAME" \
        BACKEND="$BACKEND" \
        DATASET_NAME="$DATASET_NAME" \
        DATASET_PATH="$DATASET_PATH" \
        NUM_PROMPTS="$NUM_PROMPTS" \
        REQUEST_RATE="$REQUEST_RATE" \
        SERVING_INDEX="$SERVING_INDEX" \
        SPEC_FILE_PATH="$SPEC_FILE_PATH" \
        LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
        AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
        API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"

    # Change back to script directory
    cd "$SCRIPT_DIR"
else
    echo "VLLMBenchmark workload failed for request rate $REQUEST_RATE"
    exit 1
fi
