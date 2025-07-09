#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== Dynamo Setup ==="

# 1. Run comprehensive cleanup of ALL baselines
echo "Running comprehensive cleanup of ALL baselines..."
COMMON_CLEANUP_SCRIPT="$SCRIPT_DIR/../common/cleanup-all-baselines.sh"
if [ -f "$COMMON_CLEANUP_SCRIPT" ]; then
    bash "$COMMON_CLEANUP_SCRIPT"
else
    echo "Error: Common cleanup script not found at $COMMON_CLEANUP_SCRIPT"
    exit 1
fi

# 2. Validate HF_TOKEN (always required)
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    echo "Please set your Hugging Face token: export HF_TOKEN=your_token_here"
    exit 1
fi

# 3. Install Docker and Docker Compose if not present
echo "Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# 4. Create dynamo_configurations directory if it doesn't exist
if [ ! -d "dynamo_configurations" ]; then
    mkdir -p dynamo_configurations
    echo "Created dynamo_configurations directory"
fi

echo "=== Setup complete. Ready for deployment. ===" 