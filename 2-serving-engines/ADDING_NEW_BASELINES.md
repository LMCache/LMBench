# Adding New Serving Baselines to LMBench

## Overview

Serving baselines expose an OpenAI-compatible endpoint on `localhost:30080` for benchmarking different LLM serving stacks.

**Infrastructure Types:**
- **LMCacheGKE**: Google Kubernetes Engine with GPU nodes
- **LocalMinikube**: Local Kubernetes for development/testing  
- **Local-Flat**: Direct script deployment without containers (NOTE: infrastructure that is intended to run on `Local-Flat` can technically also run on `LocalMinikube`)

## Compatibility Matrix

| Infrastructure \ Baseline | SGLang | Helm-ProductionStack | Direct-ProductionStack | Dynamo | RayServe | LLM-D |
|---------------------------|--------|---------------------|----------------------|--------|----------|-------|
| **LMCacheGKE**            | ❌     | ✅                  | ✅                   | ❌     | ❌       | ❌      |
| **LocalMinikube**         | ✔️     | ✅                  | ✅                   | ✔️     | ✔️       | ✅      |
| **Local-Flat**            | ✅     | ❌                  | ❌                   | ✅     | ✅       | ❌      |

**Note**: When adding new baselines or infrastructure, please update this compatibility matrix.

## Infrastructure vs Serving Modularity

**1-infrastructure/**: Platform setup (clusters, CRDs, cloud resources)  
**2-serving-engines/**: Inference engine deployment

- **Kubernetes/Helm**: Helm-ProductionStack, Direct-ProductionStack
- **Script-based**: SGLang, Dynamo, RayServe (Local-Flat only)

## HuggingFace Token Handling

**For Kubernetes baselines**: Use placeholders `<YOUR_HF_TOKEN>` or `<YOUR_HF_TOKEN_BASE64>` in YAML files - automatically substituted by deployment scripts.

**For Local baselines**: Scripts read directly from `HF_TOKEN` environment variable.

```bash
export HF_TOKEN="hf_your_token_here"
```

## Required Components

### 1. Setup Script (`2-serving-engines/your-baseline/setup.sh`)

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "=== Your Baseline Setup ==="

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

# 3. Install dependencies (if needed)
echo "Installing dependencies..."
# Your dependency installation logic here

echo "=== Setup complete. Ready for deployment. ==="
```

### 2. Deployment Script (`2-serving-engines/your-baseline/run-your-baseline.sh`)

```bash
#!/bin/bash
# Deploy your baseline
echo "Deploying your baseline..."
# Your deployment logic here

# CRITICAL: Block until service ready
echo "Waiting for service readiness..."
timeout 300 bash -c 'until curl -s http://localhost:30080/v1/models; do sleep 5; done'
if [ $? -eq 0 ]; then
    echo "Service ready"
else
    echo "Error: Service failed to become ready"
    exit 1
fi
```

## Integration with run-bench.py

Add 4 sections to `run-bench.py`:

**1. Validation** (~line 140):
```python
elif baseline_type == 'YourBaseline':
    # Validate modelURL and hf_token required
```

**2. Key generation** (~line 290):
```python
elif baseline_type == 'YourBaseline':
    return 'your_baseline_key'
```

**3. Setup** (~line 340):
```python
elif baseline_type == 'YourBaseline':
    MODEL_URL = baseline_config.get('modelURL')
    HF_TOKEN = baseline_config.get('hf_token')
    your_baseline_installation(baseline_config)
```

**4. Installation function**:
```python
def your_baseline_installation(baseline_config: Dict[str, Any]) -> None:
    # For baselines with setup.sh + deployment pattern:
    setup_script = Path(__file__).parent / '2-serving-engines' / 'your-baseline' / 'setup.sh'
    deploy_script = Path(__file__).parent / '2-serving-engines' / 'your-baseline' / 'run-your-baseline.sh'
    
    # Run setup (includes comprehensive cleanup)
    os.chmod(setup_script, 0o755)
    subprocess.run([str(setup_script)], check=True)
    
    # Run deployment
    os.chmod(deploy_script, 0o755)
    subprocess.run([str(deploy_script)], check=True)
```

## Update Templates

**Add to `0-bench-specs/TEMPLATE-spec.yaml`:**
```yaml
- YourBaseline:
    modelURL: meta-llama/Llama-3.1-8B-Instruct
    hf_token: <YOUR_HF_TOKEN>
    # Add baseline-specific parameters
```

**TEMPLATE-run-bench.yaml**: No changes needed.

## Comprehensive Cleanup: CRITICAL

**ALL baselines use a shared comprehensive cleanup** to prevent conflicts between different serving engines:

- **Common cleanup script**: `2-serving-engines/common/cleanup-all-baselines.sh`
- **Cleans up**: GPU processes, Helm releases, Kubernetes resources, namespaces, CRDs, Ray services, port forwarding
- **Used by**: All setup.sh scripts and choose-and-deploy.sh scripts
- **Prevents**: Kubernetes auto-recovery conflicts, resource leaks, port conflicts

**Your setup.sh MUST call the common cleanup script** before deploying to ensure a clean environment.

## Service Readiness: CRITICAL

**Workload generators start immediately after deployment** - your script MUST block until service ready:

**Option 1: Use common wait script (recommended):**
```bash
# Step 3: Wait for service readiness using common wait script
echo "Step 3: Waiting for service readiness..."
COMMON_WAIT_SCRIPT="$SCRIPT_DIR/../common/wait-for-service.sh"
if [ -f "$COMMON_WAIT_SCRIPT" ]; then
    chmod +x "$COMMON_WAIT_SCRIPT"
    bash "$COMMON_WAIT_SCRIPT" 900 "YourBaseline" "$SCRIPT_DIR"  # 15 minutes timeout
else
    echo "ERROR: Common wait script not found at $COMMON_WAIT_SCRIPT"
    echo "Falling back to basic wait..."
    bash wait.sh
fi
```

**Option 2: Manual implementation:**
```bash
timeout 300 bash -c 'until curl -s http://localhost:30080/v1/models; do sleep 5; done'
if [ $? -ne 0 ]; then exit 1; fi
```

The common wait script provides **much better observability** with:
- ✅ Multiple endpoint checks (`/v1/models`, `/health`, `/`)
- 📊 Port status monitoring
- 🔍 Process diagnostics
- 📝 Log tailing
- ⏱️ Configurable timeout (default: 10 minutes)
- 🎯 Baseline-specific naming

## Quick Start

1. Create `2-serving-engines/your-baseline/run-your-baseline.sh`
2. Implement: HF_TOKEN validation → deployment → readiness check
3. Add 4 sections to `run-bench.py` 
4. Update `TEMPLATE-spec.yaml`
5. Test: `curl http://localhost:30080/v1/models`

## Key Requirements

1. **OpenAI endpoints**: `/v1/models` and `/v1/chat/completions` on `localhost:30080`
2. **HF_TOKEN**: Validate environment variable exists
3. **Service readiness**: Block until fully available (critical!)
4. **Error handling**: Exit with error codes on failure