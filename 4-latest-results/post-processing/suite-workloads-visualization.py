#!/usr/bin/env python3

import os
import json
import sys
import glob
from collections import defaultdict
import matplotlib.pyplot as plt
import numpy as np

def load_suite_results(suite_name):
    """Load all JSON results for a given benchmark suite."""
    suite_dir = f"4-latest-results/{suite_name}"

    if not os.path.exists(suite_dir):
        print(f"Error: Suite directory {suite_dir} does not exist")
        return {}

    json_files = glob.glob(f"{suite_dir}/*.json")

    # Filter out comparison files (we only want the raw result files)
    json_files = [f for f in json_files if not f.endswith('_comparison.json')]

    if not json_files:
        print(f"Warning: No JSON result files found in {suite_dir}")
        return {}

    results = {}
    for json_file in json_files:
        try:
            with open(json_file, 'r') as f:
                data = json.load(f)

            # Extract filename without path and extension
            filename = os.path.basename(json_file).replace('.json', '')
            results[filename] = data

        except Exception as e:
            print(f"Warning: Could not load {json_file}: {e}")

    return results

def group_by_workload(results):
    """Group results by workload type."""
    workload_groups = defaultdict(list)

    for filename, data in results.items():
        workload = data.get('workload', {}).get('WORKLOAD', 'unknown')
        workload_groups[workload].append((filename, data))

    return workload_groups

def extract_key_from_filename(filename):
    """Extract the baseline key from filename (first part before workload)."""
    # Filename format: {baseline_key}_{workload}_{qps}_{timestamp}
    parts = filename.split('_')
    if len(parts) >= 2:
        # Handle cases where baseline_key might contain underscores
        # We'll take everything before the workload type
        workload_types = ['synthetic', 'sharegpt', 'agentic', 'mooncake', 'random']

        # Check for exact workload type matches first
        for i, part in enumerate(parts):
            if part in workload_types:
                return '_'.join(parts[:i])

        # Check for vllm workload patterns (vllm_dataset or vllm_dataset_path)
        for i, part in enumerate(parts):
            if part == 'vllm' and i + 1 < len(parts):
                # This is a vllm workload, return everything before 'vllm'
                return '_'.join(parts[:i])

        # Fallback: assume first part is the key
        return parts[0]
    return 'unknown'

def create_workload_comparison(workload_name, workload_results, suite_name):
    """Create comparison JSON and plot for a specific workload."""

    # Group by QPS and baseline key
    qps_data = defaultdict(lambda: defaultdict(dict))

    for filename, data in workload_results:
        baseline_key = extract_key_from_filename(filename)
        qps = data.get('workload', {}).get('QPS', 0)

        # Extract TTFT, ITL, and TPOT means
        results = data.get('results', {})
        ttft_mean = results.get('ttft_ms', {}).get('mean', 0)
        itl_mean = results.get('itl_ms', {}).get('mean', 0)
        tpot_mean = results.get('tpot_ms', {}).get('mean', 0)

        qps_data[qps][baseline_key] = {
            "TTFT": round(ttft_mean, 2),
            "ITL": round(itl_mean, 2),
            "TPOT": round(tpot_mean, 2)
        }

    # Convert to list format sorted by QPS
    comparison_data = []
    for qps in sorted(qps_data.keys()):
        qps_entry = {"qps": qps}
        qps_entry.update(qps_data[qps])
        comparison_data.append(qps_entry)

    # Save comparison JSON
    suite_dir = f"4-latest-results/{suite_name}"
    comparison_file = f"{suite_dir}/{workload_name}_comparison.json"

    with open(comparison_file, 'w') as f:
        json.dump(comparison_data, f, indent=2)

    print(f"Created comparison file: {comparison_file}")

    # Create plot
    create_workload_plot(comparison_data, workload_name, suite_name)

def create_workload_plot(comparison_data, workload_name, suite_name):
    """Create a plot for workload comparison."""
    if not comparison_data:
        print(f"Warning: No data to plot for {workload_name}")
        return

    # Extract all unique baseline keys
    baseline_keys = set()
    for entry in comparison_data:
        for key in entry.keys():
            if key != 'qps':
                baseline_keys.add(key)

    baseline_keys = sorted(list(baseline_keys))

    if not baseline_keys:
        print(f"Warning: No baseline keys found for {workload_name}")
        return

    # Prepare data for plotting
    qps_values = [entry['qps'] for entry in comparison_data]

    # Set up the plot with 3 subplots
    fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(20, 6))

    # Define colors and markers
    colors = plt.cm.tab10(np.linspace(0, 1, len(baseline_keys)))

    # Plot TTFT
    for i, baseline_key in enumerate(baseline_keys):
        ttft_values = []
        for entry in comparison_data:
            if baseline_key in entry:
                ttft_values.append(entry[baseline_key]['TTFT'])
            else:
                ttft_values.append(None)

        # Filter out None values
        valid_qps = [qps for qps, ttft in zip(qps_values, ttft_values) if ttft is not None]
        valid_ttft = [ttft for ttft in ttft_values if ttft is not None]

        if valid_ttft:
            ax1.plot(valid_qps, valid_ttft, 's-', color=colors[i], label=baseline_key, markersize=8)

    ax1.set_xlabel('QPS')
    ax1.set_ylabel('TTFT (ms)')
    ax1.set_title(f'{workload_name.title()} - Time to First Token')
    ax1.legend()
    ax1.grid(True, alpha=0.3)

    # Plot ITL
    for i, baseline_key in enumerate(baseline_keys):
        itl_values = []
        for entry in comparison_data:
            if baseline_key in entry:
                itl_values.append(entry[baseline_key]['ITL'])
            else:
                itl_values.append(None)

        # Filter out None values
        valid_qps = [qps for qps, itl in zip(qps_values, itl_values) if itl is not None]
        valid_itl = [itl for itl in itl_values if itl is not None]

        if valid_itl:
            ax2.plot(valid_qps, valid_itl, 'o-', color=colors[i], label=baseline_key, markersize=8)

    ax2.set_xlabel('QPS')
    ax2.set_ylabel('ITL (ms)')
    ax2.set_title(f'{workload_name.title()} - Inter-token Latency')
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    # Plot TPOT
    for i, baseline_key in enumerate(baseline_keys):
        tpot_values = []
        for entry in comparison_data:
            if baseline_key in entry:
                tpot_values.append(entry[baseline_key]['TPOT'])
            else:
                tpot_values.append(None)

        # Filter out None values
        valid_qps = [qps for qps, tpot in zip(qps_values, tpot_values) if tpot is not None]
        valid_tpot = [tpot for tpot in tpot_values if tpot is not None]

        if valid_tpot:
            ax3.plot(valid_qps, valid_tpot, '^-', color=colors[i], label=baseline_key, markersize=8)

    ax3.set_xlabel('QPS')
    ax3.set_ylabel('TPOT (ms)')
    ax3.set_title(f'{workload_name.title()} - Time Per Output Token')
    ax3.legend()
    ax3.grid(True, alpha=0.3)

    plt.tight_layout()

    # Save plot
    suite_dir = f"4-latest-results/{suite_name}"
    plot_file = f"{suite_dir}/{workload_name}_comparison.png"
    plt.savefig(plot_file, dpi=300, bbox_inches='tight')
    plt.close()

    print(f"Created plot: {plot_file}")

def main():
    if len(sys.argv) != 2:
        print("Usage: python suite-workloads-visualization.py <suite_name>")
        print("Example: python suite-workloads-visualization.py layerwise-benchmark")
        sys.exit(1)

    suite_name = sys.argv[1]

    print(f"Processing benchmark suite: {suite_name}")

    # Load all results for the suite
    results = load_suite_results(suite_name)

    if not results:
        print("No results found to process")
        sys.exit(1)

    # Group by workload
    workload_groups = group_by_workload(results)

    print(f"Found workloads: {list(workload_groups.keys())}")

    # Create comparison files and plots for each workload
    for workload_name, workload_results in workload_groups.items():
        print(f"\nProcessing workload: {workload_name}")
        create_workload_comparison(workload_name, workload_results, suite_name)

    print(f"\nCompleted processing suite: {suite_name}")

if __name__ == "__main__":
    main()
