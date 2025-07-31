#!/bin/bash

echo "Preparing trace data..."

# Ensure traces directory exists
mkdir -p traces/

# Download additional trace files if needed
if [ ! -f "traces/mooncake_trace.jsonl" ]; then
    echo "Downloading mooncake_trace.jsonl..."
    wget https://raw.githubusercontent.com/kobe0938/mooncake-trace-replayer/main/mooncake_trace.jsonl -O traces/mooncake_trace.jsonl
fi

# Check for main trace file
if [ ! -f "traces/gmi_trace.jsonl" ]; then
    echo "Warning: gmi_trace.jsonl not found in traces/ directory"
    echo "Please ensure trace files are placed in the traces/ directory"
fi

echo "Trace data preparation complete"
echo "Available trace files:"
echo "  In traces/ directory:"
ls -la traces/*.jsonl 2>/dev/null || echo "    No .jsonl files found in traces/"
echo "  In current directory:"
ls -la *.jsonl 2>/dev/null || echo "    No .jsonl files found in current directory"
