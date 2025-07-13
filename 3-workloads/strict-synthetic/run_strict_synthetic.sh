#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
cd "$SCRIPT_DIR"

# Standard parameters according to LMBench pattern
MODEL=$1
BASE_URL=$2
KEY=$3
NUM_CONCURRENT_USERS=$4
NUM_ROUNDS_PER_USER=$5
SHARED_SYSTEM_PROMPT_LEN=$6
FIRST_PROMPT_LEN=$7
FOLLOW_UP_PROMPTS_LEN=$8
ANSWER_LEN=$9
API_TYPE=${10}
NAME=${11}
SERVING_INDEX=${12}
SPEC_FILE_PATH=${13}
LMBENCH_SESSION_ID=${14}
TIME_BETWEEN_REQUESTS_VALUES=("${@:15}")  # All remaining arguments are time_between_requests_per_user values

echo "=== Strict Synthetic Workload ==="
echo "MODEL: $MODEL"
echo "BASE_URL: $BASE_URL"
echo "KEY: $KEY"
echo "NUM_CONCURRENT_USERS: $NUM_CONCURRENT_USERS"
echo "NUM_ROUNDS_PER_USER: $NUM_ROUNDS_PER_USER"
echo "SHARED_SYSTEM_PROMPT_LEN: $SHARED_SYSTEM_PROMPT_LEN"
echo "FIRST_PROMPT_LEN: $FIRST_PROMPT_LEN"
echo "FOLLOW_UP_PROMPTS_LEN: $FOLLOW_UP_PROMPTS_LEN"
echo "ANSWER_LEN: $ANSWER_LEN"
echo "API_TYPE: $API_TYPE"
echo "NAME: $NAME"
echo "SERVING_INDEX: $SERVING_INDEX"
echo "SPEC_FILE_PATH: $SPEC_FILE_PATH"
echo "LMBENCH_SESSION_ID: $LMBENCH_SESSION_ID"
echo "TIME_BETWEEN_REQUESTS_VALUES: ${TIME_BETWEEN_REQUESTS_VALUES[@]}"

# Check for Python (needed for QPS calculation)
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 command not found. Please install Python 3."
    exit 1
fi

# Run benchmark for each time_between_requests_per_user value
for time_between_requests in "${TIME_BETWEEN_REQUESTS_VALUES[@]}"; do
    echo "Running benchmark with time_between_requests_per_user: $time_between_requests"
    
    # Calculate QPS as num_concurrent_users / time_between_requests_per_user
    QPS=$(python3 "${SCRIPT_DIR}/calculate_qps.py" "$NUM_CONCURRENT_USERS" "$time_between_requests")
    echo "Calculated QPS: $QPS"
    
    # Generate output filename
    output_file="../../4-latest-results/${KEY}_strict_synthetic_output_${QPS}.csv"
    
    # Install dependencies if needed
    if [ ! -f "${SCRIPT_DIR}/.deps_installed" ]; then
        echo "Installing dependencies..."
        pip3 install -r "${SCRIPT_DIR}/requirements.txt"
        touch "${SCRIPT_DIR}/.deps_installed"
    fi

    # Run the Python workload generator (request-with-user-id defaults to True in the script)
    python3 "${SCRIPT_DIR}/strict-multi-round-qa.py" \
        --num-concurrent-users "$NUM_CONCURRENT_USERS" \
        --num-rounds-per-user "$NUM_ROUNDS_PER_USER" \
        --time-between-requests-per-user "$time_between_requests" \
        --shared-system-prompt-len "$SHARED_SYSTEM_PROMPT_LEN" \
        --first-prompt-len "$FIRST_PROMPT_LEN" \
        --follow-up-prompts-len "$FOLLOW_UP_PROMPTS_LEN" \
        --answer-len "$ANSWER_LEN" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --api-type "$API_TYPE" \
        --output "$output_file"
    
    # Check if the benchmark completed successfully
    if [ $? -eq 0 ]; then
        echo "Benchmark completed successfully for time_between_requests_per_user: $time_between_requests"
        
        # Post-process results with special strict synthetic flag
        cd "$PROJECT_ROOT"
        python3 "4-latest-results/post-processing/summarize.py" \
            "${output_file#../../}" \
            NAME="$NAME" \
            KEY="$KEY" \
            WORKLOAD="strict_synthetic" \
            QPS="$QPS" \
            TIME_BETWEEN_REQUESTS_PER_USER="$time_between_requests" \
            NUM_CONCURRENT_USERS="$NUM_CONCURRENT_USERS" \
            NUM_ROUNDS_PER_USER="$NUM_ROUNDS_PER_USER" \
            SHARED_SYSTEM_PROMPT_LEN="$SHARED_SYSTEM_PROMPT_LEN" \
            FIRST_PROMPT_LEN="$FIRST_PROMPT_LEN" \
            FOLLOW_UP_PROMPTS_LEN="$FOLLOW_UP_PROMPTS_LEN" \
            ANSWER_LEN="$ANSWER_LEN" \
            API_TYPE="$API_TYPE" \
            IS_STRICT_SYNTHETIC="true" \
            SERVING_INDEX="$SERVING_INDEX" \
            SPEC_FILE_PATH="$SPEC_FILE_PATH" \
            LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
            AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
            API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}" \
            IS_STRICT_SYNTHETIC="true"
        cd "$SCRIPT_DIR"
    else
        echo "ERROR: Benchmark failed for time_between_requests_per_user: $time_between_requests"
        exit 1
    fi
done

echo "=== All Strict Synthetic benchmarks completed ===" 