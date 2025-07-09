# Common Baseline Cleanup

## Overview

This directory contains shared scripts used by all LMBench serving baselines to ensure clean deployment environments.

## cleanup-all-baselines.sh

**Purpose**: Comprehensive cleanup of ALL baselines to prevent conflicts between different serving engines.

**Used by**: All setup.sh scripts and choose-and-deploy.sh scripts before deployment.

**What it cleans up**:
1. **GPU Processes**: Kills all processes using GPU memory
2. **Port 30080**: Kills all processes using the benchmark port
3. **Ray Services**: Stops all Ray services (for RayServe baseline)
4. **Helm Releases**: Uninstalls all Helm releases (for Helm-ProductionStack baseline)
5. **Kubernetes Resources**: Deletes all deployments, services, pods, etc. in default namespace
6. **Namespaces**: Deletes all application namespaces (keeps system namespaces)
7. **CRDs**: Removes Custom Resource Definitions (Istio, etc.)
8. **Stuck Resources**: Force deletes any stuck terminating pods
9. **Process Cleanup**: Kills remaining python/serving processes
10. **Port Forwarding**: Kills any remaining kubectl port-forward processes

**Why this is critical**:
- Kubernetes has auto-recovery that restarts pods even after killing GPU processes
- Different baselines use different deployment methods (Helm, direct K8s, scripts)
- Resource conflicts can cause deployment failures
- Port conflicts prevent services from binding to localhost:30080

**Usage**:
```bash
# Called automatically by all setup.sh scripts
bash /path/to/cleanup-all-baselines.sh
```

## Integration

All baselines now follow this pattern:

1. **setup.sh**: Calls cleanup-all-baselines.sh → validates environment → installs dependencies
2. **deployment script**: Deploys the baseline → waits for service readiness
3. **run-bench.py**: Calls setup.sh → calls deployment script

This ensures complete isolation between baseline runs and prevents interference from previous deployments. 