#!/bin/bash

git clone https://github.com/ai-dynamo/dynamo.git
cd dynamo

# Set environment variables
export NAMESPACE=dynamo-playground
export RELEASE_NAME=dynamo-platform
export PROJECT_ROOT=$(pwd)

kubectl create namespace ${NAMESPACE}

# Navigate to dependencies directory
cd $PROJECT_ROOT/deploy/helm/dependencies

# Add and update NATS Helm repository
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update

# Install NATS with custom values
helm install --namespace ${NAMESPACE} ${RELEASE_NAME}-nats nats/nats \
    --values nats-values.yaml

# Install etcd using Bitnami chart
helm install --namespace ${NAMESPACE} ${RELEASE_NAME}-etcd \
    oci://registry-1.docker.io/bitnamicharts/etcd \
    --values etcd-values.yaml

# Build the Dynamo Base Image

cd $PROJECT_ROOT
./container/build.sh
docker tag dynamo:latest-vllm apostab/dynamo-base:latest-vllm

docker login apostab

docker login -u "$DOCKER_USERNAME" -p "$DOCKER_PASSWORD"

docker push apostab/dynamo-base:latest-vllm