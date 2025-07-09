#! /bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# This is a raw deployment without kubernetes
# It is used to compare baselines with the following setup:
# 4x Llama 70B 2x TP 

export PATH=/usr/local/cuda/bin:$PATH

# need to be in a virtual environment to even start lmbench
pip install "sglang[all]>=0.4.9"
pip install sglang-router

# NOTE: sglang router automatically waits until workers are ready
# NOTE: the default timeout is 300 seconds

# debugging on a single GPU
# python -m sglang.launch_server --model-path meta-llama/Meta-Llama-3-8B-Instruct
# python -m sglang_router.launch_server --model-path meta-llama/Meta-Llama-3.1-8B-Instruct --dp-size 1 --tp 1 --host 0.0.0.0 --port 30080

nohup python -m sglang_router.launch_server --model-path Qwen/Qwen3-32B --dp-size 4 --tp 2 --host 0.0.0.0 --port 30080 &

