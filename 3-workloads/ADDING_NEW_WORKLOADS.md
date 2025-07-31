# Adding New Workload Generators to LMBench

## Overview

Workload generators simulate different load patterns against LLM serving systems. They query `localhost:30080` and integrate with the LMBench framework's metrics collection and dispatch system.

## Required Files

```
3-workloads/your-workload/
├── run_your_workload.sh    # Main entry point
└── your-workload-qa.py     # Python implementation
```

## 1. Run Script (`run_your_workload.sh`)

Must accept standard parameters and integrate with post-processing:

```bash
#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
cd "$SCRIPT_DIR"

# Standard parameters
MODEL=$1
BASE_URL=$2          # Will be localhost:30080 
KEY=$3
NAME=$4
SERVING_INDEX=$5
SPEC_FILE_PATH=$6
LMBENCH_SESSION_ID=$7
QPS_VALUES=("${@:8}")  # QPS values to test

# Run benchmark for each QPS
for qps in "${QPS_VALUES[@]}"; do
    output_file="../../4-latest-results/${KEY}_your_workload_output_${qps}.csv"
    
    python3 "${SCRIPT_DIR}/your-workload-qa.py" \
        --model "$MODEL" \
        --base-url "$BASE_URL" \
        --qps "$qps" \
        --output "$output_file"
    
    # Post-process results
    cd "$PROJECT_ROOT"
    python3 "4-latest-results/post-processing/summarize.py" \
        "${output_file#../../}" \
        NAME="$NAME" \
        KEY="$KEY" \
        WORKLOAD="your_workload" \
        QPS="$qps" \
        SERVING_INDEX="$SERVING_INDEX" \
        SPEC_FILE_PATH="$SPEC_FILE_PATH" \
        LMBENCH_SESSION_ID="$LMBENCH_SESSION_ID" \
        AUTO_UPLOAD="${LMBENCH_AUTO_UPLOAD:-false}" \
        API_URL="${LMBENCH_API_URL:-http://localhost:3001/upload}"
    cd "$SCRIPT_DIR"
done
```

## 2. Python Implementation (`your-workload-qa.py`)

Must query the endpoint and output metrics in CSV format:

```python
import argparse
import asyncio
import csv
import time
import aiohttp

class YourWorkloadBenchmark:
    def __init__(self, args):
        self.model = args.model
        self.base_url = args.base_url  # localhost:30080
        self.qps = args.qps
        self.output_file = args.output
        self.api_type = args.api_type  # "completions" or "chat"
    
    async def run_benchmark(self):
        results = []
        # Implement QPS-controlled requests to self.base_url
        # Use self.api_type to determine API endpoint:
        # - "completions": POST /v1/completions with prompt string
        # - "chat": POST /v1/chat/completions with messages array
        # Record: timestamp, request_id, latency, prompt_tokens, completion_tokens, total_tokens, error
        self.save_results(results)
    
    def save_results(self, results):
        with open(self.output_file, 'w', newline='') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=[
                'timestamp', 'request_id', 'latency', 
                'prompt_tokens', 'completion_tokens', 'total_tokens', 'error'
            ])
            writer.writeheader()
            writer.writerows(results)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--qps', type=float, required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--api-type', choices=['completions', 'chat'], 
                       default='completions', help='API type to use')
    
    args = parser.parse_args()
    benchmark = YourWorkloadBenchmark(args)
    asyncio.run(benchmark.run_benchmark())
```

## API Type Support (Only for multi-round-qa i.e. Synthetic right now)

**API Differences**:
```python
# Completions API (default)
POST /v1/completions
{
  "model": "model-name",
  "prompt": "System: You are helpful.\nUser: Hello\nAssistant: ",
  "max_tokens": 50
}

# Chat Completions API  
POST /v1/chat/completions
{
  "model": "model-name", 
  "messages": [
    {"role": "system", "content": "You are helpful."},
    {"role": "user", "content": "Hello"}
  ],
  "max_tokens": 50
}
```

## 3. Integration with Dispatch System

### Add to `0-bench-specs/*.yaml` (Spec Files)
Define your workload in the spec file's `Workload` section:

```yaml
Workload:
  YourWorkload:
    - QPS: [1.0, 2.0, 5.0]
      # Add workload-specific parameters
      PARAM1: value1
      PARAM2: value2
```

### Add to `run-bench.py` (3 modifications needed)

1. **Add to supported workloads list** (~line 625):
```python
supported_workloads = ['ShareGPT', 'LMCacheSynthetic', 'Agentic', 'TraceReplayer', 'Random', 'VLLMBenchmark', 'YourWorkload']
```

2. **Add dispatch logic** in `run_workload()` function (~line 650):
```python
if 'YourWorkload' in workload_cfg:
    your_workload_config = workload_cfg['YourWorkload']
    if isinstance(your_workload_config, list):
        for config in your_workload_config:
            run_your_workload(config)
    else:
        run_your_workload(your_workload_config)
```

3. **Add workload function** (after existing run_* functions):
```python
def run_your_workload(your_workload_config: Dict[str, Any]) -> None:
    """Run your workload with the specified configuration."""
    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID

    # Get benchmark name from current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    # Extract parameters from config
    qps_values = your_workload_config.get('QPS', [1.0])
    param1 = your_workload_config.get('PARAM1')
    param2 = your_workload_config.get('PARAM2')

    # Path to your workload script
    workload_script_path = Path(__file__).parent / '3-workloads' / 'your-workload' / 'run_your_workload.sh'
    if not workload_script_path.exists():
        raise FileNotFoundError(f"Your workload script not found at {workload_script_path}")

    os.chmod(workload_script_path, 0o755)

    # Build command
    cmd = [str(workload_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080"])
    cmd.extend([KEY])
    cmd.extend([str(param1)])
    cmd.extend([str(param2)])
    cmd.extend([str(benchmark_name)])
    cmd.extend([str(CURRENT_SERVING_INDEX)])
    cmd.extend([str(CURRENT_SPEC_FILE_PATH)])
    cmd.extend([str(LMBENCH_SESSION_ID)])
    cmd.extend([str(qps) for qps in qps_values])

    # Execute the workload
    print(f"Running your workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Your workload completed successfully")
    else:
        raise RuntimeError("Failed to run your workload")
```

### Add to `run-bench.yaml` (Optional)
`run-bench.yaml` only specifies which spec files to run - no workload configuration needed:

```yaml
0-bench-specs:
  - your-spec-file.yaml  # Must contain your workload definition
```

## Key Requirements

1. **Endpoint**: Always query `localhost:30080` (integrates with 2-serving-engines)
2. **Metrics**: Output CSV with required columns for 4-latest-results/post-processing
3. **QPS**: Support variable QPS rates passed as arguments
4. **Dispatch**: Integrate with run-bench.py → run-bench.yaml → 0-bench-specs chain

## 4. Update Template Files for Discoverability

### Add to `0-bench-specs/TEMPLATE-spec.yaml`
Add your workload as an example in the `Workload` section so others can discover it:

```yaml
Workload:
  # ... existing workloads ...

  YourWorkload:
    # Document your workload with examples
    - QPS: [1.0, 2.0, 5.0]
      PARAM1: value1  # Description of what this parameter does
      PARAM2: value2  # Another parameter description
      
    # Include common configuration examples:
    # Example for high throughput scenario
    - QPS: [10.0, 20.0]
      PARAM1: optimized_value
      PARAM2: high_perf_value
```

### TEMPLATE-run-bench.yaml
No changes needed - this file only specifies which spec files to run and infrastructure configuration.

## Testing

```bash
# Test standalone
./run_your_workload.sh model_name http://localhost:30080 test_key \
    suite_name 0 spec_file.yaml session_id 1.0 2.0

# Test via dispatch
python run-bench.py  # with your workload in run-bench.yaml
```
