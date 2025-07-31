#!/usr/bin/env python3
"""
LMBench Trace Sorter and Analyzer

This script sorts trace files chronologically and provides timing analysis.
It's designed to be idempotent and run automatically during LMBench deployments.

Usage: python sort_traces.py [trace_file_path]
If no path provided, sorts all trace files in the traces/ directory.
"""

import json
import os
import sys
import argparse
from pathlib import Path
from typing import List, Dict, Tuple, Optional
import shutil
import time


def parse_timestamp(timestamp) -> int:
    """Parse timestamp to integer, handling both string and int types."""
    if isinstance(timestamp, str):
        return int(timestamp)
    return int(timestamp)


def load_trace_entries(file_path: str) -> List[Dict]:
    """Load all entries from a JSONL trace file."""
    entries = []
    with open(file_path, 'r') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                entries.append(entry)
            except json.JSONDecodeError as e:
                print(f"⚠️  Warning: Invalid JSON on line {line_num}: {e}")
                continue
    return entries


def is_chronologically_sorted(entries: List[Dict]) -> bool:
    """Check if trace entries are already sorted chronologically."""
    if len(entries) <= 1:
        return True
    
    prev_timestamp = parse_timestamp(entries[0]['timestamp'])
    for entry in entries[1:]:
        current_timestamp = parse_timestamp(entry['timestamp'])
        if current_timestamp < prev_timestamp:
            return False
        prev_timestamp = current_timestamp
    
    return True


def detect_timestamp_format(entries: List[Dict]) -> str:
    """Detect whether timestamps are Unix nanoseconds, synthetic offsets, or other format."""
    if not entries:
        return "unknown"
    
    # Sample a few timestamps to analyze
    sample_size = min(10, len(entries))
    timestamps = [parse_timestamp(entries[i]['timestamp']) for i in range(sample_size)]
    
    # Check if they look like Unix nanoseconds (around 19 digits, starting with 17...)
    # Unix nanoseconds for 2025 would be around 1.7e18
    unix_ns_count = sum(1 for ts in timestamps if 1.6e18 <= ts <= 2.0e18)
    if unix_ns_count >= sample_size * 0.8:  # 80% look like Unix nanoseconds
        return "unix_nanoseconds"
    
    # Check if they look like synthetic offsets (smaller numbers, starting from 0 or low values)
    max_ts = max(timestamps)
    min_ts = min(timestamps)
    if min_ts == 0 and max_ts < 1e9:  # Less than 1 billion (< ~16 minutes in milliseconds)
        return "synthetic_offsets"
    
    return "unknown"


def format_timestamp(timestamp: int, format_type: str) -> str:
    """Format timestamp based on detected format."""
    if format_type == "unix_nanoseconds":
        try:
            import datetime
            dt = datetime.datetime.fromtimestamp(timestamp / 1e9)
            return dt.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]  # millisecond precision
        except:
            return f"{timestamp}ns"
    elif format_type == "synthetic_offsets":
        if timestamp < 1000:
            return f"{timestamp}ms"
        elif timestamp < 60000:
            return f"{timestamp/1000:.2f}s"
        else:
            minutes = timestamp // 60000
            seconds = (timestamp % 60000) / 1000
            return f"{minutes}m {seconds:.2f}s"
    else:
        return str(timestamp)


def analyze_timing_gaps(entries: List[Dict]) -> Dict:
    """Analyze timing gaps between consecutive requests."""
    if len(entries) <= 1:
        return {
            'total_requests': len(entries),
            'max_gap_seconds': 0.0,
            'max_gap_nanoseconds': 0,
            'min_gap_seconds': 0.0,
            'min_gap_nanoseconds': 0,
            'avg_gap_seconds': 0.0,
            'total_duration_seconds': 0.0,
            'unique_timestamps': len(set(parse_timestamp(e['timestamp']) for e in entries)),
            'timestamp_format': 'unknown'
        }
    
    # Sort entries by timestamp for analysis
    sorted_entries = sorted(entries, key=lambda x: parse_timestamp(x['timestamp']))
    
    # Detect timestamp format
    timestamp_format = detect_timestamp_format(sorted_entries)
    
    gaps = []
    unique_timestamps = set()
    
    for i in range(len(sorted_entries) - 1):
        current_ts = parse_timestamp(sorted_entries[i]['timestamp'])
        next_ts = parse_timestamp(sorted_entries[i + 1]['timestamp'])
        unique_timestamps.add(current_ts)
        unique_timestamps.add(next_ts)
        
        gap = next_ts - current_ts
        gaps.append(gap)
    
    if not gaps:
        return {
            'total_requests': len(entries),
            'max_gap_seconds': 0.0,
            'max_gap_nanoseconds': 0,
            'min_gap_seconds': 0.0,
            'min_gap_nanoseconds': 0,
            'avg_gap_seconds': 0.0,
            'total_duration_seconds': 0.0,
            'unique_timestamps': len(unique_timestamps),
            'timestamp_format': timestamp_format
        }
    
    max_gap = max(gaps)
    min_gap = min(gaps)
    avg_gap = sum(gaps) / len(gaps)
    
    first_ts = parse_timestamp(sorted_entries[0]['timestamp'])
    last_ts = parse_timestamp(sorted_entries[-1]['timestamp'])
    total_duration = last_ts - first_ts
    
    # Convert to seconds based on timestamp format
    if timestamp_format == "unix_nanoseconds":
        # Timestamps are in nanoseconds
        gap_to_seconds = lambda x: x / 1e9
    elif timestamp_format == "synthetic_offsets":
        # Timestamps are in milliseconds
        gap_to_seconds = lambda x: x / 1e3
    else:
        # Unknown format, assume nanoseconds for backward compatibility
        gap_to_seconds = lambda x: x / 1e9
    
    return {
        'total_requests': len(entries),
        'max_gap_seconds': gap_to_seconds(max_gap),
        'max_gap_nanoseconds': max_gap,
        'min_gap_seconds': gap_to_seconds(min_gap),
        'min_gap_nanoseconds': min_gap,
        'avg_gap_seconds': gap_to_seconds(avg_gap),
        'total_duration_seconds': gap_to_seconds(total_duration),
        'unique_timestamps': len(unique_timestamps),
        'timestamp_format': timestamp_format,
        'first_timestamp': first_ts,
        'last_timestamp': last_ts
    }


def sort_trace_file(file_path: str, backup: bool = False) -> Tuple[bool, Dict]:
    """
    Sort a trace file chronologically.
    
    Returns:
        (was_sorted, timing_analysis): Tuple indicating if sorting was needed and timing stats
    """
    print(f"📁 Processing: {file_path}")
    
    # Load entries
    try:
        entries = load_trace_entries(file_path)
    except Exception as e:
        print(f"❌ Error loading {file_path}: {e}")
        return False, {}
    
    if not entries:
        print(f"⚠️  Warning: {file_path} is empty or contains no valid entries")
        return False, {}
    
    print(f"📊 Loaded {len(entries)} entries")
    
    # Analyze timing before sorting
    timing_analysis = analyze_timing_gaps(entries)
    
    # Check if already sorted
    if is_chronologically_sorted(entries):
        print(f"✅ {file_path} is already chronologically sorted")
        return False, timing_analysis
    
    print(f"🔄 Sorting {file_path} chronologically...")
    
    # Create backup if requested
    if backup:
        backup_path = f"{file_path}.backup.{int(time.time())}"
        shutil.copy2(file_path, backup_path)
        print(f"💾 Backup created: {backup_path}")
    
    # Sort entries by timestamp
    sorted_entries = sorted(entries, key=lambda x: parse_timestamp(x['timestamp']))
    
    # Write sorted entries back to file
    try:
        with open(file_path, 'w') as f:
            for entry in sorted_entries:
                f.write(json.dumps(entry) + '\n')
        print(f"✅ Successfully sorted {file_path}")
        return True, timing_analysis
    except Exception as e:
        print(f"❌ Error writing sorted file {file_path}: {e}")
        return False, timing_analysis


def format_duration(seconds: float) -> str:
    """Format duration in human-readable format."""
    if seconds < 1e-6:
        return f"{seconds * 1e9:.1f}ns"
    elif seconds < 1e-3:
        return f"{seconds * 1e6:.1f}μs"
    elif seconds < 1:
        return f"{seconds * 1e3:.1f}ms"
    elif seconds < 60:
        return f"{seconds:.2f}s"
    elif seconds < 3600:
        minutes = int(seconds // 60)
        secs = seconds % 60
        return f"{minutes}m {secs:.1f}s"
    else:
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = seconds % 60
        return f"{hours}h {minutes}m {secs:.1f}s"


def print_timing_analysis(file_path: str, analysis: Dict):
    """Print timing analysis in a readable format."""
    print(f"\n📈 Timing Analysis for {file_path}:")
    print(f"   • Total requests: {analysis['total_requests']:,}")
    print(f"   • Unique timestamps: {analysis['unique_timestamps']:,}")
    
    # Show timestamp format information
    timestamp_format = analysis.get('timestamp_format', 'unknown')
    print(f"   • Timestamp format: {timestamp_format}")
    
    if timestamp_format == "unix_nanoseconds":
        print(f"   • Real-world time span (Unix nanoseconds)")
        if 'first_timestamp' in analysis and 'last_timestamp' in analysis:
            first_formatted = format_timestamp(analysis['first_timestamp'], timestamp_format)
            last_formatted = format_timestamp(analysis['last_timestamp'], timestamp_format)
            print(f"     From: {first_formatted}")
            print(f"     To:   {last_formatted}")
    elif timestamp_format == "synthetic_offsets":
        print(f"   • Synthetic/simulated timing (millisecond offsets)")
        if 'first_timestamp' in analysis and 'last_timestamp' in analysis:
            first_formatted = format_timestamp(analysis['first_timestamp'], timestamp_format)
            last_formatted = format_timestamp(analysis['last_timestamp'], timestamp_format)
            print(f"     From: {first_formatted}")
            print(f"     To:   {last_formatted}")
    
    print(f"   • Total duration: {format_duration(analysis['total_duration_seconds'])}")
    
    if analysis['total_requests'] > 1:
        print(f"   • Max gap between requests: {format_duration(analysis['max_gap_seconds'])}")
        print(f"   • Min gap between requests: {format_duration(analysis['min_gap_seconds'])}")
        print(f"   • Avg gap between requests: {format_duration(analysis['avg_gap_seconds'])}")
        
        if analysis['unique_timestamps'] == 1:
            print(f"   ⚠️  All requests have identical timestamps!")
        elif analysis['unique_timestamps'] < analysis['total_requests']:
            duplicate_count = analysis['total_requests'] - analysis['unique_timestamps']
            if timestamp_format == "synthetic_offsets":
                print(f"   ℹ️  {duplicate_count} requests share timestamps (normal for synthetic traces)")
            else:
                print(f"   ⚠️  {duplicate_count} requests have duplicate timestamps")


def main():
    parser = argparse.ArgumentParser(
        description="Sort LMBench trace files chronologically and analyze timing gaps"
    )
    parser.add_argument(
        'trace_files', 
        nargs='*', 
        help='Trace files to sort. If none provided, sorts all .jsonl files in traces/ directory'
    )
    parser.add_argument(
        '--backup', 
        action='store_true', 
        help='Create backup files before sorting'
    )
    parser.add_argument(
        '--traces-dir', 
        default='traces', 
        help='Directory containing trace files (default: traces)'
    )
    
    args = parser.parse_args()
    
    print("🚀 LMBench Trace Sorter and Analyzer")
    print("=" * 50)
    
    # Determine which files to process
    if args.trace_files:
        trace_files = args.trace_files
    else:
        # Find all .jsonl files in traces directory
        traces_dir = Path(args.traces_dir)
        if not traces_dir.exists():
            print(f"❌ Traces directory not found: {traces_dir}")
            sys.exit(1)
        
        trace_files = list(traces_dir.glob("*.jsonl"))
        if not trace_files:
            print(f"⚠️  No .jsonl files found in {traces_dir}")
            sys.exit(0)
        
        trace_files = [str(f) for f in trace_files]
    
    print(f"📂 Processing {len(trace_files)} trace file(s)")
    
    # Process each file
    total_sorted = 0
    all_analyses = []
    
    for file_path in trace_files:
        if not os.path.exists(file_path):
            print(f"❌ File not found: {file_path}")
            continue
        
        was_sorted, analysis = sort_trace_file(file_path, backup=args.backup)
        if was_sorted:
            total_sorted += 1
        
        if analysis:
            print_timing_analysis(file_path, analysis)
            all_analyses.append((file_path, analysis))
    
    # Summary
    print(f"\n{'=' * 50}")
    print(f"🎉 Processing Complete!")
    print(f"   • Files processed: {len(trace_files)}")
    print(f"   • Files that needed sorting: {total_sorted}")
    print(f"   • Files already sorted: {len(trace_files) - total_sorted}")
    
    # Find the file with the longest gap
    if all_analyses:
        max_gap_file, max_gap_analysis = max(
            all_analyses, 
            key=lambda x: x[1]['max_gap_seconds']
        )
        print(f"\n🏆 Longest gap between requests:")
        print(f"   • File: {max_gap_file}")
        print(f"   • Gap: {format_duration(max_gap_analysis['max_gap_seconds'])}")


if __name__ == "__main__":
    main() 