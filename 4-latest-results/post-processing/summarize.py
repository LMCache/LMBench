import pandas as pd
import sys
from typing import Optional
import os
import io
import contextlib
from datetime import datetime
import numpy as np
import yaml
import json

def ProcessSummary(
    df: pd.DataFrame,
    start_time: Optional[float] = None,
    end_time: Optional[float] = None,
    pending_queries: int = 0,
    qps: Optional[float] = None,
) -> dict:
    """Process benchmark results and return as a dictionary."""
    # Check if the DataFrame is empty
    if df.empty:
        return {
            "error": "No successful requests completed",
            "message": "All sessions failed, likely due to context length errors"
        }

    try:
        if start_time is not None and end_time is not None:
            launched_queries = len(df.query(f"{start_time} <= launch_time <= {end_time}"))
            df = df.query(f"{start_time} <= finish_time <= {end_time}")
        else:
            launched_queries = len(df)

        if qps is None:
            qps = 0.0

        if start_time is None:
            start_time = df["launch_time"].min()
        if end_time is None:
            end_time = df["finish_time"].max()

        total_time = end_time - start_time
        total_requests = launched_queries + pending_queries
        finished_requests = len(df)
        request_throughput = finished_requests / total_time

        total_prompt_tokens = df["prompt_tokens"].sum()
        total_generation_tokens = df["generation_tokens"].sum()
        output_token_throughput = total_generation_tokens / total_time
        total_token_throughput = (total_prompt_tokens + total_generation_tokens) / total_time

        # TTFT stats (in milliseconds)
        ttft_ms = df["ttft"] * 1000
        mean_ttft = ttft_ms.mean()
        median_ttft = ttft_ms.median()
        p99_ttft = np.percentile(ttft_ms, 99)

        # Time per Output Token calculation (excluding first token)
        df['tpot'] = ((df['generation_time'] - df['ttft']) / (df['generation_tokens'] - 1)) * 1000
        tpot = df['tpot'].replace([float('inf'), -float('inf'), np.nan], np.nan).dropna()
        mean_tpot = tpot.mean()
        median_tpot = tpot.median()
        p99_tpot = np.percentile(tpot, 99)

        # Inter-token Latency
        df['itl'] = (df['generation_time'] / df['generation_tokens']) * 1000
        itl = df['itl'].replace([float('inf'), -float('inf'), np.nan], np.nan).dropna()
        mean_itl = itl.mean()
        median_itl = itl.median()
        p99_itl = np.percentile(itl, 99)

        return {
            "successful_requests": int(finished_requests),
            "benchmark_duration_s": round(total_time, 2),
            "total_input_tokens": int(total_prompt_tokens),
            "total_generated_tokens": int(total_generation_tokens),
            "request_throughput_req_per_s": round(request_throughput, 2),
            "output_token_throughput_tok_per_s": round(output_token_throughput, 2),
            "total_token_throughput_tok_per_s": round(total_token_throughput, 2),
            "ttft_ms": {
                "mean": round(mean_ttft, 2),
                "median": round(median_ttft, 2),
                "p99": round(p99_ttft, 2)
            },
            "tpot_ms": {
                "mean": round(mean_tpot, 2),
                "median": round(median_tpot, 2),
                "p99": round(p99_tpot, 2)
            },
            "itl_ms": {
                "mean": round(mean_itl, 2),
                "median": round(median_itl, 2),
                "p99": round(p99_itl, 2)
            }
        }

    except Exception as e:
        return {
            "error": f"Failed to process benchmark results: {str(e)}",
            "message": "This is likely due to empty metrics after filtering failed sessions"
        }

def get_infrastructure_info() -> dict:
    """Extract infrastructure information from run-bench.yaml."""
    infra_info = {}

    if os.path.exists("run-bench.yaml"):
        try:
            with open("run-bench.yaml", "r") as config_file:
                config = yaml.safe_load(config_file)
                infra_info = config.get('1-infrastructure', {})
        except Exception as e:
            print(f"Warning: Could not parse run-bench.yaml: {e}")

    return infra_info

def get_serving_baseline_info(serving_index: Optional[int] = None, spec_file_path: Optional[str] = None) -> dict:
    """Extract serving baseline information from the specific spec file."""
    serving_info = {}

    if spec_file_path and os.path.exists(spec_file_path):
        try:
            with open(spec_file_path, "r") as spec_file:
                config = yaml.safe_load(spec_file)

            if serving_index is not None and 'Serving' in config:
                serving_configs = config['Serving']
                if isinstance(serving_configs, list) and 0 <= serving_index < len(serving_configs):
                    serving_config = serving_configs[serving_index]
                    baseline_type = list(serving_config.keys())[0]
                    baseline_config = serving_config[baseline_type]

                    # Remove sensitive information
                    baseline_config_clean = {k: v for k, v in baseline_config.items() if k != 'hf_token'}

                    serving_info = {
                        "baseline_type": baseline_type,
                        "config": baseline_config_clean
                    }
        except Exception as e:
            print(f"Warning: Could not parse serving baseline info from {spec_file_path}: {e}")

    return serving_info

def process_output(filename: str, **kwargs):
    try:
        df = pd.read_csv(filename)

        # Extract parameters
        name = kwargs.get('NAME', 'unknown')
        baseline_key = kwargs.get('KEY', 'unknown')
        workload = kwargs.get('WORKLOAD', 'unknown')
        qps = kwargs.get('QPS', 'unknown')
        serving_index = kwargs.get('SERVING_INDEX')
        spec_file_path = kwargs.get('SPEC_FILE_PATH')

        # For agentic workload, calculate QPS from the data instead of using passed QPS
        if workload == 'agentic' and not df.empty:
            # Calculate QPS as total_requests / total_duration
            start_time = df["launch_time"].min()
            end_time = df["finish_time"].max()
            total_duration = end_time - start_time
            total_requests = len(df)
            calculated_qps = round(total_requests / total_duration, 2) if total_duration > 0 else 0
            qps = calculated_qps
            print(f"Calculated QPS for agentic workload: {qps}")

        # For vllm_benchmark workload, use REQUEST_RATE as QPS (target QPS is what matters)
        if workload == 'vllm_benchmark':
            # Use REQUEST_RATE as the QPS (this is the target QPS from the benchmark)
            request_rate = kwargs.get('REQUEST_RATE', 'unknown')
            qps = request_rate
            print(f"Using REQUEST_RATE as QPS for vllm_benchmark workload: {qps}")

        # Create timestamp
        timestamp = datetime.now().strftime("%Y%m%d-%H%M")

        # Generate filename: {name}/{baseline_key}_{workload}_{qps}_{timestamp}.json
        json_filename = f"{baseline_key}_{workload}_{qps}_{timestamp}.json"
        suite_dir = f"4-latest-results/{name}"
        json_path = f"{suite_dir}/{json_filename}"

        # Create the suite directory if it doesn't exist
        os.makedirs(suite_dir, exist_ok=True)

        # Process benchmark results
        results = ProcessSummary(df, pending_queries=0)

        # Read infrastructure info from run-bench.yaml
        infra_info = get_infrastructure_info()

        # Read benchmark name from the specific spec file
        bench_name = name
        if spec_file_path and os.path.exists(spec_file_path):
            try:
                with open(spec_file_path, "r") as spec_file:
                    config = yaml.safe_load(spec_file)
                    bench_name = config.get('Name', name)
            except Exception as e:
                print(f"Warning: Could not parse spec file {spec_file_path}: {e}")

        # Get serving baseline info from the specific spec file
        serving_info = get_serving_baseline_info(serving_index, spec_file_path)

        # Create workload info (exclude sensitive and internal parameters)
        workload_info = {k: v for k, v in kwargs.items()
                        if k not in ['NAME', 'KEY', 'SERVING_INDEX', 'SPEC_FILE_PATH']}

        # Add calculated QPS to workload info for agentic workloads
        if workload == 'agentic':
            workload_info['QPS'] = qps

        # Add QPS info to workload info for vllm_benchmark workloads
        if workload == 'vllm_benchmark':
            workload_info['QPS'] = qps  # This is the target QPS (REQUEST_RATE)

        # Create the final JSON structure
        output_data = {
            "name": bench_name,
            "timestamp": timestamp,
            "results": results,
            "infra": infra_info,
            "serving": serving_info,
            "workload": workload_info
        }

        # Write JSON file
        with open(json_path, "w") as f:
            json.dump(output_data, f, indent=2)

        print(f"Performance summary saved to {json_path}")

        # Save a copy to ~/srv/runner-db/
        runner_db_path = os.path.expanduser("~/srv/runner-db/")
        os.makedirs(runner_db_path, exist_ok=True)
        runner_db_file = os.path.join(runner_db_path, json_filename)

        with open(json_path, "r") as src, open(runner_db_file, "w") as dst:
            dst.write(src.read())
        print(f"Results saved to ~/srv/runner-db/{json_filename}")

    except Exception as e:
        print(f"ERROR: Failed to process benchmark results: {str(e)}")
        print("The benchmarking script may have failed due to context length errors.")
        print("Check the logs for more details.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python summarize.py <path_to_csv> [key=value ...]")
        sys.exit(1)

    filename = sys.argv[1]
    raw_kwargs = sys.argv[2:]

    def parse_value(val):
        try:
            return eval(val, {}, {})
        except:
            return val

    kwargs = {}
    for arg in raw_kwargs:
        if "=" in arg:
            key, val = arg.split("=", 1)
            kwargs[key] = parse_value(val)

    process_output(filename, **kwargs)
