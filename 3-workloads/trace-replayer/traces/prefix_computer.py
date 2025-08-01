#!/usr/bin/env python3

import json

def common_prefix_length(a, b):
    """Returns the length of the common prefix between two lists."""
    min_len = min(len(a), len(b))
    for i in range(min_len):
        if a[i] != b[i]:
            return i
    return min_len

def parse_trace(filename):
    with open(filename, 'r') as f:
        requests = [json.loads(line.strip()) for line in f]
    
    hash_lists = [r["hash_ids"] for r in requests]
    n = len(hash_lists)
    total_prefix_reuse = 0
    comparisons = 0

    for i in range(n):
        for j in range(i + 1, n):
            reuse = common_prefix_length(hash_lists[i], hash_lists[j])
            total_prefix_reuse += reuse
            comparisons += 1
            print(f"Request {i} and {j}: prefix reuse = {reuse}")

    print(f"\nTotal prefix reuse across {comparisons} pairs: {total_prefix_reuse}")
    print(f"Average prefix reuse: {total_prefix_reuse / comparisons:.2f}")

if __name__ == "__main__":
    parse_trace("gmi_trace.jsonl")
