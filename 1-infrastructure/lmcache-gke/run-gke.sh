#!/bin/bash

set -x

# Check if number of GPUs argument is provided
if [ $# -lt 2 ]; then
  echo "Usage: $0 <num_gpus> <vram_size>"
  echo "  num_gpus: Number of GPUs (1, 2, 4, 8)"
  echo "  vram_size: 40 for A100 40GB or 80 for A100 80GB"
  exit 1
fi

NUM_GPUS=$1
A100_VRAM=$2

CLUSTER_NAME="lm-bench"
NODE_POOL_NAME="gpu-pool"
# Quotas are by REGIONS so WLOG we choose us-central1-a zone in us-central1 region
ZONE="us-central1-a"
GCP_PROJECT=$(gcloud config get-value project)

if [ -z "$GCP_PROJECT" ]; then
  echo "Error: No GCP project ID found. Please set your project with 'gcloud config set project <PROJECT_ID>'."
  exit 1
fi

# Check if cluster already exists and clean it up if needed
EXISTING_CLUSTER=$(gcloud container clusters list --filter="name=$CLUSTER_NAME" --format="value(name)" 2>/dev/null || true)
if [ -n "$EXISTING_CLUSTER" ]; then
  echo "Cluster $CLUSTER_NAME already exists. Starting repeated cleanup attempts..."

  # Path to cleanup script
  CLEANUP_SCRIPT="4-latest-results/post-processing/cleanup.sh"

  if [ ! -f "$CLEANUP_SCRIPT" ]; then
    echo "Cleanup script not found at $CLEANUP_SCRIPT"
    exit 1
  fi

  # Wait for the cluster to be fully deleted with a timeout
  TIMEOUT_MINUTES=15
  TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
  START_TIME=$(date +%s)

  while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_SECONDS=$((CURRENT_TIME - START_TIME))

    if [ $ELAPSED_SECONDS -gt $TIMEOUT_SECONDS ]; then
      echo "Timeout of $TIMEOUT_MINUTES minutes reached waiting for cluster deletion."
      echo "Please check the status of the cluster manually and try again."
      exit 1
    fi

    # Try running the cleanup script again in case the previous attempt failed
    echo "Attempting cleanup..."
    bash "$CLEANUP_SCRIPT"

    # Check if cluster still exists
    CLUSTER_EXISTS=$(gcloud container clusters list --filter="name=$CLUSTER_NAME" --format="value(name)" 2>/dev/null || true)
    if [ -z "$CLUSTER_EXISTS" ]; then
      echo "Cluster $CLUSTER_NAME has been successfully deleted. Proceeding with creation."
      break
    fi

    echo "Cluster still exists. Waiting 30 seconds... (${ELAPSED_SECONDS}s elapsed of ${TIMEOUT_SECONDS}s timeout)"
    sleep 30
  done
fi

# Set SPOT_FLAG based on A100_VRAM
if [ "$A100_VRAM" -eq 80 ]; then
  SPOT_FLAG="--spot"
  echo "Using spot instances for A100 80GB"
else
  SPOT_FLAG=""
  echo "Using regular (non-spot) instances for A100 40GB"
fi

# Choose machine type and accelerator based on VRAM size and number of GPUs
if [ "$A100_VRAM" -eq 80 ]; then
  # A100 80GB options (A2-UltraGPU)
  if [ "$NUM_GPUS" -eq 1 ]; then
    echo "Creating cluster with 1 A100 80GB, Stats should be 12 vCPUs, 170GB memory"
    MACHINE_TYPE="a2-ultragpu-1g" # 12 vCPUs, 170GB memory
    ACCELERATOR_TYPE="nvidia-a100-80gb"
  elif [ "$NUM_GPUS" -eq 2 ]; then
    echo "Creating cluster with 2 A100 80GB, Stats should be 24 vCPUs, 340GB memory"
    MACHINE_TYPE="a2-ultragpu-2g" # 24 vCPUs, 340GB memory
    ACCELERATOR_TYPE="nvidia-a100-80gb"
  elif [ "$NUM_GPUS" -eq 4 ]; then
    echo "Creating cluster with 4 A100 80GB, Stats should be 48 vCPUs, 680GB memory"
    MACHINE_TYPE="a2-ultragpu-4g" # 48 vCPUs, 680GB memory
    ACCELERATOR_TYPE="nvidia-a100-80gb"
  elif [ "$NUM_GPUS" -eq 8 ]; then
    echo "Creating cluster with 8 A100 80GB, Stats should be 96 vCPUs, 1360GB memory"
    MACHINE_TYPE="a2-ultragpu-8g" # 96 vCPUs, 1360GB memory
    ACCELERATOR_TYPE="nvidia-a100-80gb"
  else
    echo "Error: For A100 80GB, only 1, 2, 4, 8 GPUs are supported."
    exit 1
  fi
else
  # A100 40GB options (A2-HighGPU) - original configuration
  if [ "$NUM_GPUS" -eq 1 ]; then
    echo "Creating cluster with 1 A100 40GB, Stats should be 12 vCPUs, 85GB memory"
    MACHINE_TYPE="a2-highgpu-1g" # 12 vCPUs, 85GB memory
    ACCELERATOR_TYPE="nvidia-tesla-a100"
  elif [ "$NUM_GPUS" -eq 2 ]; then
    echo "Creating cluster with 2 A100 40GB, Stats should be 24 vCPUs, 170GB memory"
    MACHINE_TYPE="a2-highgpu-2g" # 24 vCPUs, 170GB memory
    ACCELERATOR_TYPE="nvidia-tesla-a100"
  elif [ "$NUM_GPUS" -eq 4 ]; then
    echo "Creating cluster with 4 A100 40GB, Stats should be 48 vCPUs, 340GB memory"
    MACHINE_TYPE="a2-highgpu-4g" # 48 vCPUs, 340GB memory
    ACCELERATOR_TYPE="nvidia-tesla-a100"
  elif [ "$NUM_GPUS" -eq 8 ]; then
    echo "Creating cluster with 8 A100 40GB, Stats should be 96 vCPUs, 680GB memory"
    MACHINE_TYPE="a2-highgpu-8g" # 96 vCPUs, 680GB memory
    ACCELERATOR_TYPE="nvidia-tesla-a100"
  else
    echo "Error: For A100 40GB, only 1, 2, 4, or 8 GPUs are supported."
    exit 1
  fi
fi

# Create cluster with no nodes
# the default node pool does not need that much disk space (the gpu pool does though)
gcloud beta container --project "$GCP_PROJECT" clusters create "$CLUSTER_NAME" \
  --zone "$ZONE" \
  --tier "standard" \
  --no-enable-basic-auth \
  --release-channel "regular" \
  --image-type "COS_CONTAINERD" \
  --disk-type "pd-balanced" \
  --disk-size "30" \
  --metadata disable-legacy-endpoints=true \
  --scopes "https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append" \
  --machine-type "e2-medium" \
  --num-nodes "1" \
  --logging=SYSTEM,WORKLOAD \
  --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET \
  --enable-ip-alias \
  --network "projects/$GCP_PROJECT/global/networks/default" \
  --subnetwork "projects/$GCP_PROJECT/regions/us-central1/subnetworks/default" \
  --no-enable-intra-node-visibility \
  --default-max-pods-per-node "110" \
  --enable-ip-access \
  --security-posture=standard \
  --workload-vulnerability-scanning=disabled \
  --no-enable-master-authorized-networks \
  --no-enable-google-cloud-access \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
  --enable-autoupgrade \
  --enable-autorepair \
  --max-surge-upgrade 1 \
  --max-unavailable-upgrade 0 \
  --binauthz-evaluation-mode=DISABLED \
  --enable-managed-prometheus \
  --enable-shielded-nodes \
  --node-locations "$ZONE"

echo "Checking node pools after cluster creation..."
gcloud container node-pools list --cluster "$CLUSTER_NAME" --zone "$ZONE"

# Create GPU node pool (for the serving engines)
# Loading models like Llama-3.1-70B-Instruct requires 140GB of disk space
gcloud container node-pools create gpu-pool \
  --cluster "$CLUSTER_NAME" \
  --zone "$ZONE" \
  --machine-type "$MACHINE_TYPE" \
  --accelerator type="$ACCELERATOR_TYPE",count="$NUM_GPUS" \
  --num-nodes "1" \
  --image-type=COS_CONTAINERD \
  --enable-autoupgrade \
  --enable-autorepair \
  --disk-type "pd-balanced" \
  --disk-size "220" \
  $SPOT_FLAG

echo "Checking node pools after gpu-pool creation..."
gcloud container node-pools list --cluster "$CLUSTER_NAME" --zone "$ZONE"

# CPU only node pool (for the router)
gcloud container node-pools create cpu-pool \
  --cluster "$CLUSTER_NAME" \
  --zone "$ZONE" \
  --machine-type "e2-standard-4" \
  --num-nodes "1"

echo "Checking node pools after cpu-pool creation..."
gcloud container node-pools list --cluster "$CLUSTER_NAME" --zone "$ZONE"

echo "Getting cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"

# Wait for nodes to be ready (without making things too complicated)
echo "Waiting for nodes to be ready..."
sleep 30
kubectl get nodes

echo "Labeling nodes in gpu and cpu pools..."
# Label GPU nodes
for node in $(kubectl get nodes -o name | grep gpu-pool); do
    kubectl label "$node" pool=gpu-pool
done

# Label CPU nodes
for node in $(kubectl get nodes -o name | grep cpu-pool); do
    kubectl label "$node" pool=cpu-pool
done

# Apply NVIDIA device plugin
PLUGIN_YAML_LOCAL="1-infrastructure/lmcache-gke/nvidia-device-plugin.yml"
PLUGIN_YAML_REMOTE="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.4/nvidia-device-plugin.yml"

if [ -f "$PLUGIN_YAML_LOCAL" ]; then
    echo "✅ Using local NVIDIA device plugin YAML at $PLUGIN_YAML_LOCAL"
    kubectl apply -f "$PLUGIN_YAML_LOCAL"
else
    echo "🌐 Local file not found — using remote NVIDIA device plugin YAML from GitHub"
    kubectl apply -f "$PLUGIN_YAML_REMOTE"
fi

echo "Infrastructure setup complete! 🚀"
echo "Node pools have been created and labeled with pool=gpu-pool and pool=cpu-pool."
echo "Applications should be deployed to the appropriate pools in the next phase."