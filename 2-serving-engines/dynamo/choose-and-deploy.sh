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
kubectl create namespace $NAMESPACE
kubectl config set-context --current --namespace=$NAMESPACE
./deploy.sh --crds

nohup kubectl port-forward svc/dynamo-store 8080:80 -n $KUBE_NS & 
export DYNAMO_CLOUD=http://localhost:8080

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