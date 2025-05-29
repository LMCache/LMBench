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

def get_serving_baseline_info(serving_index: Optional[int] = None) -> dict:
    """Extract serving baseline information from bench-spec.yaml."""
    serving_info = {}

    if os.path.exists("bench-spec.yaml"):
        try:
            with open("bench-spec.yaml", "r") as spec_file:
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
            print(f"Warning: Could not parse serving baseline info: {e}")

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

        # Create timestamp
        timestamp = datetime.now().strftime("%Y%m%d-%H%M")

        # Generate filename: {NAME}_{BASELINE/KEY}_WKLD_QPS_TIME.json
        json_filename = f"{name}_{baseline_key}_{workload}_{qps}_{timestamp}.json"
        json_path = f"4-latest-results/{json_filename}"

        # Process benchmark results
        results = ProcessSummary(df, pending_queries=0)

        # Read bench-spec.yaml for infrastructure and name info
        infra_info = {}
        bench_name = name
        if os.path.exists("bench-spec.yaml"):
            try:
                with open("bench-spec.yaml", "r") as spec_file:
                    config = yaml.safe_load(spec_file)
                    bench_name = config.get('Name', name)
                    infra_info = config.get('Infrastructure', {})
            except Exception as e:
                print(f"Warning: Could not parse bench-spec.yaml: {e}")

        # Get serving baseline info
        serving_info = get_serving_baseline_info(serving_index)

        # Create workload info (exclude sensitive and internal parameters)
        workload_info = {k: v for k, v in kwargs.items()
                        if k not in ['NAME', 'KEY', 'SERVING_INDEX']}

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
