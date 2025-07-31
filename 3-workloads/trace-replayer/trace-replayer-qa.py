#!/usr/bin/env python3
"""
Trace Replayer workload for LMBench.
Replays conversation traces using deterministic synthetic prompt generation.
Uses hash_ids as seeds to preserve cache locality patterns while generating valid text.
"""

import argparse
import asyncio
import csv
import json
import time
import random
import numpy as np
from typing import List, Dict, Any, Optional
import aiohttp
import sys
from pathlib import Path

class TraceDataset:
    """Dataset that loads and processes conversation trace data."""
    
    def __init__(self, trace_file: str, start_time: float = 0, duration: float = float('inf')):
        self.trace_file = trace_file
        self.start_time = start_time
        self.duration = duration
        self.requests = []
        self.actual_trace_duration = 0  # Store the actual duration of the trace
        self.load_trace()
    
    def load_trace(self):
        """Load and filter trace data with relative timestamps."""
        # First, load all entries and sort by timestamp
        all_entries = []
        with open(self.trace_file, 'r') as f:
            for line in f:
                if line.strip():
                    entry = json.loads(line)
                    # Handle both string and int timestamps
                    timestamp = int(entry['timestamp']) if isinstance(entry['timestamp'], str) else entry['timestamp']
                    entry['timestamp'] = timestamp
                    all_entries.append(entry)
        
        # Sort by timestamp to ensure chronological order
        all_entries.sort(key=lambda x: x['timestamp'])
        
        if not all_entries:
            print("No entries found in trace file")
            return
        
        # Get the earliest and latest timestamps to calculate actual trace duration
        earliest_timestamp = all_entries[0]['timestamp']
        latest_timestamp = all_entries[-1]['timestamp']
        
        # Calculate actual trace duration in seconds
        self.actual_trace_duration = (latest_timestamp - earliest_timestamp) / 1e9  # Convert nanoseconds to seconds
        
        # Handle special case: duration = -1 means use full trace duration
        if self.duration == -1:
            self.duration = self.actual_trace_duration
            print(f"Using full trace duration: {self.actual_trace_duration:.2f} seconds ({len(all_entries)} total requests)")
        
        # Convert to relative timestamps in seconds and filter by time window
        for entry in all_entries:
            relative_time = (entry['timestamp'] - earliest_timestamp) / 1e9  # Convert to seconds
            
            # Filter by time window
            if relative_time >= self.start_time and relative_time <= (self.start_time + self.duration):
                entry['relative_timestamp'] = relative_time - self.start_time  # Relative to start_time
                self.requests.append(entry)
        
        print(f"Loaded {len(self.requests)} requests from trace file {self.trace_file}")
        if len(self.requests) > 0:
            time_span = max(req['relative_timestamp'] for req in self.requests) - min(req['relative_timestamp'] for req in self.requests)
            print(f"Trace time span: {time_span:.2f} seconds (from {self.start_time}s to {self.start_time + self.duration}s of original trace)")
        else:
            print(f"⚠️  No requests found in the specified time window ({self.start_time}s to {self.start_time + self.duration}s)")
            print(f"   Original trace spans: 0s to {self.actual_trace_duration:.2f}s")
    
    def generate_synthetic_prompt(self, hash_ids: List[int], target_length: int) -> str:
        """
        Generate synthetic prompt based on hash_ids and target length.
        Uses hash_ids as deterministic seeds for reproducible generation that preserves cache locality.
        """
        # Create a deterministic seed from hash_ids
        seed = sum(hash_ids) % (2**31)
        random.seed(seed)
        np.random.seed(seed)
        
        # Vocabulary for generating realistic text
        words = [
            "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by",
            "from", "up", "about", "into", "through", "during", "before", "after", "above", "below",
            "user", "system", "data", "process", "function", "value", "result", "input", "output",
            "information", "analysis", "method", "approach", "solution", "problem", "question",
            "answer", "response", "request", "message", "content", "text", "word", "sentence",
            "document", "file", "code", "program", "script", "algorithm", "structure", "database",
            "network", "server", "client", "application", "interface", "protocol", "service",
            "configuration", "parameter", "variable", "constant", "string", "number", "array"
        ]
        
        # Generate text with target length (approximate token count)
        generated_words = []
        estimated_tokens = 0
        
        # Use hash_ids to influence word selection deterministically
        base_offset = hash_ids[0] if hash_ids else 0
        
        while estimated_tokens < target_length:
            # Select word deterministically based on hash_ids and position
            word_idx = (base_offset + len(generated_words) + sum(hash_ids)) % len(words)
            word = words[word_idx]
            generated_words.append(word)
            
            # Rough estimate: 1 word ≈ 1.3 tokens on average
            estimated_tokens = len(generated_words) * 1.3
        
        # Create coherent prompt structure with context
        text_content = " ".join(generated_words)
        
        # Add variety to prompt structures based on hash_ids
        prompt_type = sum(hash_ids) % 4
        if prompt_type == 0:
            prompt = f"Please analyze the following data and provide detailed insights: {text_content}. What are the key patterns and recommendations?"
        elif prompt_type == 1:
            prompt = f"Given this information: {text_content}, please summarize the main points and suggest next steps."
        elif prompt_type == 2:
            prompt = f"Review this content: {text_content}. Identify potential issues and propose solutions."
        else:
            prompt = f"Process the following input: {text_content}. Generate a comprehensive response with analysis."
        
        return prompt

class TraceReplayerBenchmark:
    def __init__(self, args):
        self.model = args.model
        self.base_url = args.base_url
        self.trace_file = args.trace_file
        self.start_time = args.start_time
        self.duration = args.duration
        self.preserve_timing = args.preserve_timing
        self.time_scale = args.time_scale
        self.qps = args.qps
        self.api_type = args.api_type
        self.output_file = args.output
        
        # Load dataset
        self.dataset = TraceDataset(
            trace_file=self.trace_file,
            start_time=self.start_time,
            duration=self.duration
        )
        
        # Track results
        self.results = []
        self.request_id = 0
    
    async def send_request(self, prompt: str, max_tokens: int, timestamp: float) -> Dict[str, Any]:
        """Send a single request to the API."""
        self.request_id += 1
        request_start_time = time.time()
        
        # Prepare request based on API type
        if self.api_type == "chat":
            url = f"{self.base_url}/v1/chat/completions"
            payload = {
                "model": self.model,
                "messages": [
                    {"role": "user", "content": prompt}
                ],
                "max_tokens": max_tokens,
                "temperature": 0.0
            }
        else:  # completions
            url = f"{self.base_url}/v1/completions"
            payload = {
                "model": self.model,
                "prompt": prompt,
                "max_tokens": max_tokens,
                "temperature": 0.0
            }
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(url, json=payload) as response:
                    request_end_time = time.time()
                    latency = request_end_time - request_start_time
                    
                    if response.status == 200:
                        data = await response.json()
                        
                        # Extract token counts
                        usage = data.get("usage", {})
                        prompt_tokens = usage.get("prompt_tokens", 0)
                        completion_tokens = usage.get("completion_tokens", 0)
                        total_tokens = prompt_tokens + completion_tokens
                        
                        return {
                            'timestamp': timestamp,
                            'request_id': self.request_id,
                            'latency': latency,
                            'prompt_tokens': prompt_tokens,
                            'completion_tokens': completion_tokens,
                            'total_tokens': total_tokens,
                            'error': None
                        }
                    else:
                        error_text = await response.text()
                        return {
                            'timestamp': timestamp,
                            'request_id': self.request_id,
                            'latency': latency,
                            'prompt_tokens': 0,
                            'completion_tokens': 0,
                            'total_tokens': 0,
                            'error': f"HTTP {response.status}: {error_text}"
                        }
        
        except Exception as e:
            request_end_time = time.time()
            latency = request_end_time - request_start_time
            return {
                'timestamp': timestamp,
                'request_id': self.request_id,
                'latency': latency,
                'prompt_tokens': 0,
                'completion_tokens': 0,
                'total_tokens': 0,
                'error': str(e)
            }
    
    async def run_timed_replay(self):
        """Run replay preserving original timing."""
        if not self.dataset.requests:
            print("No requests to replay!")
            return
        
        print(f"Starting timed replay of {len(self.dataset.requests)} requests with time_scale={self.time_scale}")
        
        tasks = []
        
        async def schedule_request(entry):
            # Use the pre-calculated relative timestamp
            delay = entry['relative_timestamp'] * self.time_scale
            
            if delay > 0:
                await asyncio.sleep(delay)
            
            # Generate synthetic prompt using hash_ids and input_length from trace
            prompt = self.dataset.generate_synthetic_prompt(
                entry['hash_ids'], 
                entry['input_length']
            )
            
            return await self.send_request(
                prompt, 
                entry['output_length'],  # Use exact output_length from trace
                entry['relative_timestamp']
            )
        
        # Schedule all requests
        for entry in self.dataset.requests:
            task = asyncio.create_task(schedule_request(entry))
            tasks.append(task)
        
        # Wait for all requests to complete
        start_time = time.time()
        results = await asyncio.gather(*tasks, return_exceptions=True)
        total_time = time.time() - start_time
        
        # Process results
        successful = 0
        for result in results:
            if isinstance(result, dict) and not result.get('error'):
                successful += 1
            self.results.append(result if isinstance(result, dict) else {
                'timestamp': time.time(),
                'request_id': len(self.results) + 1,
                'latency': 0,
                'prompt_tokens': 0,
                'completion_tokens': 0,
                'total_tokens': 0,
                'error': str(result)
            })
        
        print(f"Timed replay completed in {total_time:.2f}s")
        print(f"Successful requests: {successful}/{len(results)}")
    
    async def run_qps_replay(self):
        """Run replay with controlled QPS."""
        if not self.dataset.requests:
            print("No requests to replay!")
            return
        
        print(f"Starting QPS-controlled replay at {self.qps} QPS")
        
        interval = 1.0 / self.qps if self.qps > 0 else 0
        
        for i, entry in enumerate(self.dataset.requests):
            # Generate synthetic prompt using hash_ids and input_length from trace
            prompt = self.dataset.generate_synthetic_prompt(
                entry['hash_ids'], 
                entry['input_length']
            )
            
            # Send request
            result = await self.send_request(
                prompt, 
                entry['output_length'],  # Use exact output_length from trace
                time.time()
            )
            self.results.append(result)
            
            # Rate limiting
            if interval > 0 and i < len(self.dataset.requests) - 1:
                await asyncio.sleep(interval)
        
        successful = sum(1 for r in self.results if not r.get('error'))
        print(f"QPS replay completed. Successful requests: {successful}/{len(self.results)}")
    
    async def run_benchmark(self):
        """Run the benchmark."""
        if self.preserve_timing:
            await self.run_timed_replay()
        else:
            await self.run_qps_replay()
        
        # Save results
        self.save_results()
    
    def save_results(self):
        """Save results in LMBench CSV format."""
        with open(self.output_file, 'w', newline='') as csvfile:
            fieldnames = ['timestamp', 'request_id', 'latency', 'prompt_tokens', 'completion_tokens', 'total_tokens', 'error']
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            
            for result in self.results:
                writer.writerow(result)
        
        print(f"Results saved to {self.output_file}")

def main():
    parser = argparse.ArgumentParser(description="Trace Replayer for LMBench")
    
    # LMBench standard parameters
    parser.add_argument('--model', required=True, help='Model name')
    parser.add_argument('--base-url', required=True, help='Base URL for API')
    parser.add_argument('--output', required=True, help='Output CSV file')
    parser.add_argument('--qps', type=float, default=1.0, help='Queries per second (for QPS mode)')
    parser.add_argument('--api-type', choices=['completions', 'chat'], default='completions',
                       help='API type to use')
    
    # Trace replayer specific parameters  
    parser.add_argument('--trace-file', default='traces/gmi_trace.jsonl', 
                       help='Path to trace file in JSONL format')
    parser.add_argument('--start-time', type=float, default=0, 
                       help='Start time in seconds (relative to trace start)')
    parser.add_argument('--duration', type=float, default=60, 
                       help='Duration to replay in seconds (-1 for full trace duration)')
    
    # Timing options
    parser.add_argument('--preserve-timing', action='store_true',
                       help='Preserve original timestamps from trace')
    parser.add_argument('--speed-up', type=float, default=None,
                       help='Speed up factor (1.0 = real-time, 2.0 = 2x faster, 10.0 = 10x faster)')
    parser.add_argument('--time-scale', type=float, default=1.0,
                       help='Legacy time scale factor (1.0 = real-time, 0.5 = 2x faster) - use --speed-up instead')
    
    args = parser.parse_args()
    
    # Handle SPEED_UP vs TIME_SCALE conversion
    if args.speed_up is not None:
        # Convert SPEED_UP to internal time_scale: time_scale = 1.0 / speed_up
        args.time_scale = 1.0 / args.speed_up
        print(f"Using SPEED_UP: {args.speed_up}x (internal time_scale: {args.time_scale})")
    else:
        print(f"Using TIME_SCALE: {args.time_scale} (consider using --speed-up for more intuitive control)")
    
    # Run benchmark
    benchmark = TraceReplayerBenchmark(args)
    asyncio.run(benchmark.run_benchmark())

if __name__ == "__main__":
    main() 