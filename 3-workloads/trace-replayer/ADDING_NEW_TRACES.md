# Adding New Traces to TraceReplayer

## Overview

The TraceReplayer workload can replay any conversation trace that follows the required JSONL format. This document explains how to add new traces for benchmarking.

## Required Trace Format

Each trace must be a JSONL (JSON Lines) file where each line contains a single JSON object representing one request with the following **required fields**:

```json
{
  "timestamp": "1753780607550317897",
  "input_length": 2101,
  "output_length": 84,
  "hash_ids": [2843241808, 137021281, 3846380862, ...]
}
```

### Field Requirements

| Field | Type | Description | Notes |
|-------|------|-------------|-------|
| `timestamp` | string or number | Absolute timestamp | Can be in any unit (ns, ms, s) - will be converted to relative timing |
| `input_length` | number | Target input prompt length in tokens | Used for deterministic prompt generation |
| `output_length` | number | Target output completion length in tokens | Passed to API as `max_tokens` |
| `hash_ids` | array of numbers | Hash IDs for deterministic generation | Used as seeds to preserve cache locality patterns |

### Important Notes

1. **Timestamps don't need to start at 0** - TraceReplayer automatically calculates relative timestamps from the earliest entry
2. **Traces don't need to be sorted** - TraceReplayer sorts them chronologically during loading  
3. **Hash IDs preserve cache locality** - Same hash_ids → similar prompts, maintaining realistic caching patterns
4. **Deterministic generation** - Same hash_ids + input_length always produces the same synthetic prompt

## Adding a New Trace

### Step 1: Prepare Your Trace File

1. **Convert to JSONL format** with required fields
2. **Place in the traces directory**:
   ```bash
   cp your_trace.jsonl 3-workloads/trace-replayer/traces/
   ```

### Step 2: Validate the Format

Use this Python script to validate your trace:

```python
import json

def validate_trace(filepath):
    """Validate trace file format."""
    required_fields = {"timestamp", "input_length", "output_length", "hash_ids"}
    
    with open(filepath, 'r') as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                missing = required_fields - set(entry.keys())
                if missing:
                    print(f"Line {line_num}: Missing fields {missing}")
                    return False
                    
                # Validate types
                if not isinstance(entry['input_length'], int):
                    print(f"Line {line_num}: input_length must be integer")
                    return False
                if not isinstance(entry['output_length'], int):
                    print(f"Line {line_num}: output_length must be integer") 
                    return False
                if not isinstance(entry['hash_ids'], list):
                    print(f"Line {line_num}: hash_ids must be array")
                    return False
                    
            except json.JSONDecodeError as e:
                print(f"Line {line_num}: Invalid JSON - {e}")
                return False
    
    print("✅ Trace format is valid!")
    return True

# Usage
validate_trace("your_trace.jsonl")
```

### Step 3: Update Spec File

Add your trace to a benchmark spec file:

```yaml
# In 0-bench-specs/your-spec.yaml
Workload:
  TraceReplayer:
    # Your new trace
    - TRACE_FILE: traces/your_trace.jsonl
      START_TIME: 0
      DURATION: 120
      PRESERVE_TIMING: true
      SPEED_UP: 1.0  # 1.0 = real-time, 2.0 = 2x faster, 10.0 = 10x faster
```

## Example Trace Conversion

### From CSV to JSONL

If you have a CSV trace, convert it like this:

```python
import csv
import json

def csv_to_jsonl(csv_file, jsonl_file):
    """Convert CSV trace to JSONL format."""
    with open(csv_file, 'r') as csv_f, open(jsonl_file, 'w') as jsonl_f:
        reader = csv.DictReader(csv_f)
        for row in reader:
            # Adapt field names as needed
            entry = {
                "timestamp": row['timestamp'],
                "input_length": int(row['input_tokens']),
                "output_length": int(row['output_tokens']),
                "hash_ids": json.loads(row['hash_ids'])  # If stored as JSON string
            }
            jsonl_f.write(json.dumps(entry) + '\n')

csv_to_jsonl("input.csv", "output.jsonl")
```

### From Log Files

If you have log files, extract the relevant fields:

```python
import json
import re

def logs_to_jsonl(log_file, jsonl_file):
    """Extract trace data from log files."""
    with open(log_file, 'r') as log_f, open(jsonl_file, 'w') as jsonl_f:
        for line in log_f:
            # Parse your log format (example)
            match = re.search(r'timestamp=(\d+) input_len=(\d+) output_len=(\d+) hash=\[([^\]]+)\]', line)
            if match:
                timestamp, input_len, output_len, hash_str = match.groups()
                hash_ids = [int(x.strip()) for x in hash_str.split(',')]
                
                entry = {
                    "timestamp": timestamp,
                    "input_length": int(input_len),
                    "output_length": int(output_len),
                    "hash_ids": hash_ids
                }
                jsonl_f.write(json.dumps(entry) + '\n')
```

## Timing Control: QPS vs SPEED_UP

TraceReplayer supports **two mutually exclusive modes**:

### Mode 1: Timed Replay (`PRESERVE_TIMING: true`)
- **Uses original timestamps** from the trace
- **Controls speed** with `SPEED_UP`:
  - `1.0` = real-time replay
  - `2.0` = 2x faster than original
  - `10.0` = 10x faster than original
  - `0.5` = 2x slower than original
- **Ignores** `QPS` parameter

### Mode 2: QPS-Controlled (`PRESERVE_TIMING: false`)
- **Ignores original timestamps** completely
- **Uses fixed request rate** with `QPS`
- **Ignores** `SPEED_UP` parameter

## Configuration Examples

### Real-time Replay (Timed Mode)

Replay exactly as recorded:

```yaml
- TRACE_FILE: traces/production_trace.jsonl
  START_TIME: 0
  DURATION: 300  # 5 minutes
  PRESERVE_TIMING: true     # Use original timestamps
  SPEED_UP: 1.0            # Real-time speed
  # QPS is ignored in this mode
```

### Accelerated Replay (Timed Mode)

Replay 10x faster:

```yaml
- TRACE_FILE: traces/production_trace.jsonl
  START_TIME: 0
  DURATION: 300
  PRESERVE_TIMING: true     # Use original timestamps
  SPEED_UP: 10.0           # 10x faster than original
  # QPS is ignored in this mode
```

### QPS-Controlled Testing

Ignore original timing, use fixed QPS:

```yaml
- TRACE_FILE: traces/production_trace.jsonl
  START_TIME: 0
  DURATION: 180
  PRESERVE_TIMING: false    # Ignore original timestamps
  QPS: [1.0, 5.0, 10.0]    # Test multiple rates
  # SPEED_UP is ignored in this mode
```

### Time Window Replay (Timed Mode)

Replay specific portion of trace:

```yaml
- TRACE_FILE: traces/long_trace.jsonl
  START_TIME: 600    # Start 10 minutes in (relative to trace start)
  DURATION: 300      # Replay 5 minutes worth
  PRESERVE_TIMING: true      # Use original timestamps
  SPEED_UP: 1.0             # Real-time speed
  # QPS is ignored in this mode
```

## Best Practices

1. **Validate before use** - Always validate trace format first
2. **Start small** - Test with short durations initially
3. **Check timing** - Verify relative timestamps make sense
4. **Document source** - Note where the trace originated
5. **Test both modes** - Verify both timed and QPS replay work
6. **Monitor resources** - Large traces can be memory-intensive

## Available Traces

Current traces in `traces/` directory:

- `gmi_trace.jsonl` - Default GMI anonymized trace (1933 requests)
- `mooncake_trace.jsonl` - Alternative conversation trace

## Troubleshooting

### Common Issues

**Timestamps not relative:**
- TraceReplayer automatically handles this - no action needed

**Trace not sorted:**
- TraceReplayer sorts automatically - no action needed

**Missing hash_ids:**
- Generate synthetic hash_ids if needed:
  ```python
  import random
  entry['hash_ids'] = [random.randint(0, 2**32-1) for _ in range(50)]
  ```

**Large traces:**
- Consider filtering by time window or sampling for testing

**Invalid JSON:**
- Use `json.loads()` to validate each line before writing

For more help, see the main LMBench documentation or `3-workloads/ADDING_NEW_WORKLOADS.md`. 