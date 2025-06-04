#!/bin/bash
set -e

# Replace all hf_token values with <YOUR_HF_TOKEN> in all .yaml files
find . -type f -name "*.yaml" -exec sed -i 's/^\(\s*-*\s*hf_token:\s*\).*/\1<YOUR_HF_TOKEN>/' {} \;

# Clean up GKE cluster (if applicable)

# Set cluster name from argument
CLUSTER_NAME="lm-bench"

# Get cluster zone
ZONE=$(gcloud container clusters list --filter="name=$CLUSTER_NAME" --format="value(location)" 2>/dev/null || true)

if [ -z "$ZONE" ]; then
  echo "Cluster $CLUSTER_NAME not found — skipping cluster cleanup."
else
  echo "Starting cleanup for GKE cluster: $CLUSTER_NAME in zone: $ZONE"

  # Check cluster status
  CLUSTER_STATUS=$(gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --format="value(status)" 2>/dev/null || true)

  if [ "$CLUSTER_STATUS" == "RUNNING" ]; then
    # Try connecting to cluster
    gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" || true

    # Delete custom namespaces
    echo "Deleting custom namespaces..."
    kubectl get ns --no-headers | awk '{print $1}' | grep -vE '^(default|kube-system|kube-public)' | xargs -r kubectl delete ns --wait --timeout=60s || true

    # Delete workloads + objects
    echo "Deleting workloads and cluster objects..."
    kubectl delete deployments,statefulsets,daemonsets,services,ingresses,configmaps,secrets,persistentvolumeclaims,jobs,cronjobs --all --all-namespaces || true
    kubectl delete persistentvolumes --all || true

    # Delete node pools
    echo "Checking for node pools..."
    NODE_POOLS=$(gcloud container node-pools list --cluster "$CLUSTER_NAME" --zone "$ZONE" --format="value(name)" 2>/dev/null || true)
    for NODE_POOL in $NODE_POOLS; do
      echo "Deleting node pool: $NODE_POOL"
      gcloud container node-pools delete "$NODE_POOL" --cluster "$CLUSTER_NAME" --zone "$ZONE" --quiet || true
    done
  else
    echo "Cluster $CLUSTER_NAME is not running or already being deleted."
  fi

  # Delete cluster
  echo "Deleting GKE cluster..."
  gcloud container clusters delete "$CLUSTER_NAME" --zone "$ZONE" --quiet || true

  # Wait for cluster to disappear
  echo "Waiting for cluster deletion..."
  # Add timeout of 20 minutes (1200 seconds)
  TIMEOUT=1200
  START_TIME=$(date +%s)
  while gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" >/dev/null 2>&1; do
    # Check if we've reached the timeout
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
      echo "❌ Timeout reached! Cluster not deleted after 20 minutes."
      echo "Please check the status of cluster $CLUSTER_NAME in zone $ZONE manually."
      break
    fi

    echo "Still deleting... waiting 10s (${ELAPSED_TIME}s elapsed out of ${TIMEOUT}s timeout)"
    sleep 10
  done
  echo "Cluster $CLUSTER_NAME deleted."
fi

# Delete orphan persistent disks
echo "Deleting orphan persistent disks..."
DISK_NAMES=$(gcloud compute disks list --filter="name~'$CLUSTER_NAME' AND status=READY" --format="value(name)" 2>/dev/null || true)
for DISK_NAME in $DISK_NAMES; do
  echo "Deleting disk: $DISK_NAME"
  gcloud compute disks delete "$DISK_NAME" --quiet || true
done

echo "✅ Cleanup of GKE cluster $CLUSTER_NAME completed successfully!"
