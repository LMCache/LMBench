#!/bin/bash


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

VENV_DIR=~/dynamo_venv

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

echo "Activating virtual environment"
source "$VENV_DIR/bin/activate"
pip install "ai-dynamo[all]"
pip install tensorboardX

export DOCKER_SERVER=docker.io/apostab
export IMAGE_TAG=benchmark
export NAMESPACE=dynamo-cloud
export KUBE_NS=dynamo-cloud
export DYNAMO_IMAGE=apostab/dynamo-base:latest-vllm

# Clean up previous Dynamo Cloud Deployments
helm uninstall dynamo-platform -n $NAMESPACE || true

git clone https://github.com/ai-dynamo/dynamo.git
cd dynamo/
export PROJECT_ROOT=$(pwd)
cd deploy/cloud/helm
kubectl create namespace $NAMESPACE || true
kubectl config set-context --current --namespace=$NAMESPACE
./deploy.sh --crds

sleep 20

# Expected Output:
# kubectl get pods
# NAME                                                              READY   STATUS    RESTARTS   AGE
# dynamo-platform-dynamo-api-store-7db7d475b8-g4445                 1/1     Running   0          35s
# dynamo-platform-dynamo-operator-buildkitd-0                       1/1     Running   0          35s
# dynamo-platform-dynamo-operator-controller-manager-6bf7dcdqf764   2/2     Running   0          35s
# dynamo-platform-etcd-0                                            1/1     Running   0          35s
# dynamo-platform-minio-6ccff75459-hg8wj                            1/1     Running   0          35s
# dynamo-platform-nats-0                                            2/2     Running   0          35s
# dynamo-platform-nats-box-5dbf45c748-lt2nt                         1/1     Running   0          35s
# dynamo-platform-postgresql-0                                      1/1     Running   0          35s


# Utility:
free_port() {
    if [ -z "$1" ]; then
        echo "Usage: free_port <port>"
        return 1
    fi

    local port=$1
    
    echo "🧹 Cleaning up any existing containers on port $port..."
    
    # Kill any processes using the port directly
    sudo lsof -ti:$port | xargs -r sudo kill -9 2>/dev/null || true
    
    # Kill and remove containers using this port
    sudo docker ps -q --filter "publish=$port" | xargs -r sudo docker kill 2>/dev/null || true
    sudo docker ps -aq --filter "publish=$port" | xargs -r sudo docker rm -f 2>/dev/null || true
    
    # Wait a moment for port to be released
    sleep 3
    
    # Verify port is free
    if sudo lsof -i:$port >/dev/null 2>&1; then
        echo "⚠️ Port $port still in use after cleanup, waiting longer..."
        sleep 5
        sudo lsof -ti:$port | xargs -r sudo kill -9 2>/dev/null || true
        sleep 2
    fi
    
    # Final check
    if sudo lsof -i:$port >/dev/null 2>&1; then
        echo "❌ Failed to free port $port"
        echo "🔍 Processes still using port $port:"
        sudo lsof -i:$port || true
        return 1
    else
        echo "✅ Port $port is now free"
    fi
}

free_port 8080
nohup kubectl port-forward svc/dynamo-cloud-dynamo-api-store 8080:80 -n $NAMESPACE &
export DYNAMO_CLOUD=http://localhost:8080


# LLM Deployment

cd $PROJECT_ROOT/examples/llm
DYNAMO_TAG=$(dynamo build graphs.agg:Frontend | grep "Successfully built" |  awk '{ print $NF }' | sed 's/\.$//')

