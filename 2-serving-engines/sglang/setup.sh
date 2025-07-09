#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== SGLang Baseline Setup ==="

# 1. Clear out all processes currently using GPUs
echo "Clearing GPU processes..."
if command -v nvidia-smi &> /dev/null; then
    echo "Killing GPU processes..."
    
    # Method 1: Use nvidia-smi to get compute processes
    GPU_PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
    
    # Method 2: Also check pmon output for additional processes
    PMON_PIDS=$(nvidia-smi pmon -c 1 2>/dev/null | awk 'NR>2 && $2!="[Unknown]" {print $2}' | grep -v '^-$' || true)
    
    # Combine and deduplicate PIDs
    ALL_PIDS=$(echo -e "$GPU_PIDS\n$PMON_PIDS" | sort -u | grep -E '^[0-9]+$' || true)
    
    if [ -n "$ALL_PIDS" ]; then
        for pid in $ALL_PIDS; do
            if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
                echo "Killing GPU process PID: $pid"
                # Try regular kill first, then sudo if needed
                if ! kill -9 "$pid" 2>/dev/null; then
                    sudo kill -9 "$pid" 2>/dev/null || echo "  Failed to kill PID $pid"
                fi
            fi
        done
        
        # Wait for processes to die and verify
        sleep 3
        
        # Verify GPU is actually free
        REMAINING_PROCESSES=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -v '^$' | grep -v 'pid' || true)
        if [ -n "$REMAINING_PROCESSES" ]; then
            echo "Warning: Some GPU processes may still be running:"
            nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader || true
        else
            echo "GPU processes cleared successfully."
        fi
    else
        echo "No GPU processes found to kill."
    fi
else
    echo "nvidia-smi not found, skipping GPU cleanup"
fi

# 2. Clean up any processes using port 30080
echo "Cleaning up port 30080..."
PID_ON_30080=$(lsof -t -i :30080 2>/dev/null || true)
if [[ -n "$PID_ON_30080" ]]; then
    echo "Found process on port 30080 (PID: $PID_ON_30080). Killing it..."
    kill -9 "$PID_ON_30080" || echo "Failed to kill PID $PID_ON_30080"
fi
sleep 2

# 3. SGLang doesn't use Kubernetes, so no K8s cleanup needed

# 4. Validate HF_TOKEN
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# 5. Install dependencies
echo "Installing SGLang dependencies..."
export PATH=/usr/local/cuda/bin:$PATH
pip install "sglang[all]>=0.4.9"
pip install sglang-router

echo "=== Setup complete. Ready for deployment. ===" 