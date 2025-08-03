#!/bin/bash

echo "VIRTUAL_ENV is: $VIRTUAL_ENV"

# should be launched from 2-serving-engines/flat/choose-and-deploy.sh

# Check if vllm command is available
if ! command -v vllm &> /dev/null; then
    echo "ERROR: vllm command not found in PATH" >&2
    echo "Please ensure vLLM is installed and accessible:" >&2
    echo "  pip install vllm" >&2
    echo "Or activate the appropriate virtual environment" >&2
    echo "Current PATH: $PATH" >&2
    echo "Python location: $(which python3 2>/dev/null || echo 'not found')" >&2
    exit 1
fi

pip install mooncake-transfer-engine


NUM_INSTANCES=4


# Find N free ports starting from START_PORT
find_free_ports() {
    local start=$1
    local count=$2
    local port=$start
    local free_ports=()

    while [ "${#free_ports[@]}" -lt "$count" ]; do
        if ! lsof -iTCP:$port -sTCP:LISTEN &>/dev/null; then
            free_ports+=($port)
        fi
        ((port++))
    done

    echo "${free_ports[@]}"
}

find_free_gpus() {
    local count=$1
    local free_gpus=()

    local total_gpus
    total_gpus=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)

    for ((i=0; i<total_gpus; i++)); do
        has_process=$(nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader | grep -c "$(nvidia-smi --query-gpu=uuid --format=csv,noheader -i $i)" || true)
        if [[ "$has_process" -eq 0 ]]; then
            free_gpus+=("$i")
        fi
        if [[ "${#free_gpus[@]}" -ge "$count" ]]; then
            break
        fi
    done

    if [[ "${#free_gpus[@]}" -lt "$count" ]]; then
        echo "ERROR: Only found ${#free_gpus[@]} free GPUs, need $count" >&2
        exit 1
    fi

    echo "${free_gpus[@]}"
}

# Get 4 free ports starting from 8000
free_ports=($(find_free_ports 8000 "$NUM_INSTANCES"))
free_gpus=($(find_free_gpus "$NUM_INSTANCES"))

echo "Using ports: ${free_ports[*]}"
echo "Using GPUs:  ${free_gpus[*]}"

if [ "${#free_ports[@]}" -ne "$NUM_INSTANCES" ]; then
    echo "ERROR: Only found ${#free_ports[@]} free ports, need $NUM_INSTANCES" >&2
    exit 1
fi

if [ "${#free_gpus[@]}" -ne "$NUM_INSTANCES" ]; then
    echo "ERROR: Only found ${#free_gpus[@]} free GPUs, need $NUM_INSTANCES" >&2
    exit 1
fi


for i in $(seq 0 $((NUM_INSTANCES - 1))); do
    port="${free_ports[$i]}"
    gpu="${free_gpus[$i]}"
    log_file="vllm_${port}.log"

    echo "Launching vLLM on port $port with GPU $gpu..."
    CUDA_VISIBLE_DEVICES="$gpu" \
    LMCACHE_CONFIG_FILE="configs/cpu-offload.yaml" \
    nohup vllm serve \
        meta-llama/Llama-3.1-8B-Instruct \
        --max-model-len 32000 \
        --port "$port" \
        > "$log_file" 2>&1 &
done

# do a trick here where we alternate querying each port with v1/models
# and we return once we get NUM_INSTANCES good responses in a row
# every query, we also print out the tail of the logs
echo "Waiting for all $NUM_INSTANCES engines to be ready in a row..."


ready_in_a_row=0
i=0
while true; do
    port="${free_ports[$((i % NUM_INSTANCES))]}"
    log_file="vllm_${port}.log"

    echo "⏳ Checking port $port..."
    if curl -s http://localhost:$port/v1/models > /dev/null 2>&1; then
        echo "✅ Port $port responded OK"
        ((ready_in_a_row++))
    else
        echo "❌ Port $port not ready. Resetting counter."
        ready_in_a_row=0
    fi

    echo "↪ Log tail for port $port:"
    tail -n 5 "$log_file" || echo "(no log yet)"
    echo ""

    if [[ "$ready_in_a_row" -ge "$NUM_INSTANCES" ]]; then
        echo "🎉 All $NUM_INSTANCES engines responded successfully in a row"
        break
    fi

    sleep 2
    ((i++))
done

port_arg=$(IFS=, ; echo "${free_ports[*]}")

nohup python routers/round-robin-router.py --ports "$port_arg" &