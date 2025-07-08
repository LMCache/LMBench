# Adding New Serving Baselines to LMBench

## Overview

Serving baselines expose an OpenAI-compatible endpoint on `localhost:30080` for benchmarking different LLM serving stacks.

**Infrastructure Types:**
- **LMCacheGKE**: Google Kubernetes Engine with GPU nodes
- **LocalMinikube**: Local Kubernetes for development/testing  
- **Local-Flat**: Direct script deployment without containers

## Compatibility Matrix

| Infrastructure \ Baseline | SGLang | Helm-ProductionStack | Direct-ProductionStack | Dynamo | RayServe |
|---------------------------|--------|---------------------|----------------------|--------|----------|
| **LMCacheGKE**            | ✅     | ✅                  | ✅                   | ❌     | ❌       |
| **LocalMinikube**         | ✅     | ✅                  | ✅                   | ❌     | ❌       |
| **Local-Flat**            | ❌     | ❌                  | ❌                   | ✅     | ✅       |

**Note**: When adding new baselines or infrastructure, please update this compatibility matrix.

## Infrastructure vs Serving Modularity

**1-infrastructure/**: Platform setup (clusters, CRDs, cloud resources)  
**2-serving-engines/**: Inference engine deployment

- **Kubernetes/Helm**: SGLang, Helm-ProductionStack, Direct-ProductionStack
- **Script-based**: Dynamo, RayServe (Local-Flat only)

## HuggingFace Token Handling

**For Kubernetes baselines**: Use placeholders `<YOUR_HF_TOKEN>` or `<YOUR_HF_TOKEN_BASE64>` in YAML files - automatically substituted by deployment scripts.

**For Local baselines**: Scripts read directly from `HF_TOKEN` environment variable.

```bash
export HF_TOKEN="hf_your_token_here"
```

## Required Components

### 1. Deployment Script (`2-serving-engines/your-baseline/run-your-baseline.sh`)

```bash
#!/bin/bash
# Validate HF_TOKEN (always required)
if [ -z "$HF_TOKEN" ]; then
    echo "Error: HF_TOKEN environment variable is not set"
    exit 1
fi

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
    script_path = Path(__file__).parent / '2-serving-engines' / 'your-baseline' / 'run-your-baseline.sh'
    os.chmod(script_path, 0o755)
    subprocess.run([str(script_path)], check=True)
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

## Service Readiness: CRITICAL

**Workload generators start immediately after deployment** - your script MUST block until service ready:

```bash
timeout 300 bash -c 'until curl -s http://localhost:30080/v1/models; do sleep 5; done'
if [ $? -ne 0 ]; then exit 1; fi
```

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