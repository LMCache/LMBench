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
        print(f"📁 Loading trace file: {self.trace_file}")
        load_start_time = time.time()
        
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
        
        load_time = time.time() - load_start_time
        print(f"⏱️  Loaded {len(all_entries)} entries from trace in {load_time:.3f}s")
        
        # Sort by timestamp to ensure chronological order
        sort_start = time.time()
        all_entries.sort(key=lambda x: x['timestamp'])
        sort_time = time.time() - sort_start
        print(f"🔄 Sorted entries by timestamp in {sort_time:.3f}s")
        
        if not all_entries:
            print("❌ No entries found in trace file")
            return
        
        # Get the earliest and latest timestamps to calculate actual trace duration
        earliest_timestamp = all_entries[0]['timestamp']
        latest_timestamp = all_entries[-1]['timestamp']
        
        # Calculate actual trace duration in seconds
        self.actual_trace_duration = (latest_timestamp - earliest_timestamp) / 1e9  # Convert nanoseconds to seconds
        
        print(f"📈 Original trace spans {self.actual_trace_duration:.2f} seconds ({len(all_entries)} requests)")
        print(f"📅 Trace timestamp range: {earliest_timestamp} to {latest_timestamp}")
        
        # Handle special case: duration = -1 means use full trace duration
        if self.duration == -1:
            self.duration = self.actual_trace_duration
            print(f"🎯 Using full trace duration: {self.actual_trace_duration:.2f} seconds ({len(all_entries)} total requests)")
        
        # Calculate time window
        end_time = self.start_time + self.duration
        print(f"⏰ Filtering to time window: {self.start_time:.2f}s to {end_time:.2f}s")
        
        # Convert to relative timestamps in seconds and filter by time window
        filter_start = time.time()
        for entry in all_entries:
            relative_time = (entry['timestamp'] - earliest_timestamp) / 1e9  # Convert to seconds
            
            # Filter by time window
            if relative_time >= self.start_time and relative_time <= (self.start_time + self.duration):
                entry['relative_timestamp'] = relative_time - self.start_time  # Relative to start_time
                self.requests.append(entry)
        
        filter_time = time.time() - filter_start
        print(f"🔍 Filtered to {len(self.requests)} requests in time window ({filter_time:.3f}s)")
        
        if len(self.requests) > 0:
            time_span = max(req['relative_timestamp'] for req in self.requests) - min(req['relative_timestamp'] for req in self.requests)
            avg_input_len = sum(req['input_length'] for req in self.requests) / len(self.requests)
            avg_output_len = sum(req['output_length'] for req in self.requests) / len(self.requests)
            
            print(f"✅ Trace loading complete!")
            print(f"📊 Loaded trace statistics:")
            print(f"   • Requests in window: {len(self.requests)}")
            print(f"   • Time span: {time_span:.2f} seconds")
            print(f"   • Average input length: {avg_input_len:.0f} tokens")
            print(f"   • Average output length: {avg_output_len:.0f} tokens")
            print(f"   • Request density: {len(self.requests)/time_span:.1f} req/s" if time_span > 0 else "   • Request density: ∞ req/s")
        else:
            print(f"⚠️  No requests found in the specified time window ({self.start_time}s to {self.start_time + self.duration}s)")
            print(f"   Original trace spans: 0s to {self.actual_trace_duration:.2f}s")
            print(f"💡 Try adjusting START_TIME or DURATION parameters, or use DURATION: full")
    
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
        
        print(f"🎬 Starting timed replay of {len(self.dataset.requests)} requests with time_scale={self.time_scale}")
        
        # Progress tracking
        total_requests = len(self.dataset.requests)
        completed_requests = 0
        successful_requests = 0
        failed_requests = 0
        start_time = time.time()
        
        # Progress reporting intervals
        progress_intervals = [0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99]
        reported_intervals = set()
        
        tasks = []
        
        async def schedule_request(entry, request_index):
            nonlocal completed_requests, successful_requests, failed_requests
            
            # Use the pre-calculated relative timestamp
            delay = entry['relative_timestamp'] * self.time_scale
            
            if delay > 0:
                await asyncio.sleep(delay)
            
            # Log first few requests for visibility
            if request_index < 5:
                print(f"📤 Request {request_index + 1}: input_len={entry['input_length']}, output_len={entry['output_length']}, delay={delay:.3f}s")
            
            # Generate synthetic prompt using hash_ids and input_length from trace
            prompt = self.dataset.generate_synthetic_prompt(
                entry['hash_ids'], 
                entry['input_length']
            )
            
            # Send request and track timing
            request_start = time.time()
            result = await self.send_request(
                prompt, 
                entry['output_length'],  # Use exact output_length from trace
                entry['relative_timestamp']
            )
            request_end = time.time()
            
            # Update counters
            completed_requests += 1
            if result.get('error'):
                failed_requests += 1
                if failed_requests <= 3:  # Show first few errors
                    print(f"❌ Request {request_index + 1} failed: {result['error']}")
            else:
                successful_requests += 1
            
            # Progress reporting
            progress = completed_requests / total_requests
            for interval in progress_intervals:
                if progress >= interval and interval not in reported_intervals:
                    reported_intervals.add(interval)
                    elapsed = time.time() - start_time
                    rate = completed_requests / elapsed if elapsed > 0 else 0
                    print(f"🔄 Progress: {progress*100:.0f}% ({completed_requests}/{total_requests}) | "
                          f"Success: {successful_requests} | Failed: {failed_requests} | "
                          f"Rate: {rate:.1f} req/s | Elapsed: {elapsed:.1f}s")
                    break
            
            return result
        
        # Schedule all requests with their index for logging
        for index, entry in enumerate(self.dataset.requests):
            task = asyncio.create_task(schedule_request(entry, index))
            tasks.append(task)
        
        # Wait for all requests to complete
        print(f"⏱️  Scheduling {len(tasks)} requests...")
        results = await asyncio.gather(*tasks, return_exceptions=True)
        total_time = time.time() - start_time
        
        # Process results and show final summary
        successful = 0
        failed = 0
        total_latency = 0
        total_tokens_generated = 0
        
        for result in results:
            if isinstance(result, Exception):
                failed += 1
                print(f"❌ Exception during request: {result}")
            elif result.get('error'):
                failed += 1
            else:
                successful += 1
                total_latency += result.get('latency', 0)
                total_tokens_generated += result.get('completion_tokens', 0)
        
        # Final statistics
        print(f"\n🎯 Timed Replay Complete!")
        print(f"📊 Final Statistics:")
        print(f"   • Total requests: {len(results)}")
        print(f"   • Successful: {successful}")
        print(f"   • Failed: {failed}")
        print(f"   • Success rate: {(successful/len(results)*100):.1f}%" if results else "0%")
        print(f"   • Total time: {total_time:.2f}s")
        print(f"   • Average rate: {len(results)/total_time:.1f} req/s" if total_time > 0 else "∞ req/s")
        if successful > 0:
            print(f"   • Average latency: {total_latency/successful:.3f}s")
            print(f"   • Total tokens generated: {total_tokens_generated}")
            print(f"   • Token generation rate: {total_tokens_generated/total_time:.1f} tokens/s" if total_time > 0 else "∞ tokens/s")
        
        self.results.extend([r for r in results if not isinstance(r, Exception)])
    
    async def run_qps_replay(self):
        """Run replay at a fixed QPS rate."""
        if not self.dataset.requests:
            print("No requests to replay!")
            return
        
        print(f"📊 Starting QPS-controlled replay at {self.qps} QPS")
        print(f"📋 Will process {len(self.dataset.requests)} requests from trace")
        
        # Calculate interval between requests
        interval = 1.0 / self.qps if self.qps > 0 else 0
        print(f"⏱️  Request interval: {interval:.3f}s between requests")
        
        # Progress tracking
        total_requests = len(self.dataset.requests)
        completed_requests = 0
        successful_requests = 0
        failed_requests = 0
        start_time = time.time()
        
        # Progress reporting intervals
        progress_intervals = [0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99]
        reported_intervals = set()
        
        for i, entry in enumerate(self.dataset.requests):
            # Log first few requests for visibility
            if i < 5:
                print(f"📤 Request {i + 1}: input_len={entry['input_length']}, output_len={entry['output_length']}")
            
            # Generate synthetic prompt using hash_ids and input_length from trace
            prompt = self.dataset.generate_synthetic_prompt(
                entry['hash_ids'], 
                entry['input_length']
            )
            
            # Send request and track timing
            request_start = time.time()
            result = await self.send_request(
                prompt, 
                entry['output_length'],  # Use exact output_length from trace
                time.time()
            )
            request_end = time.time()
            
            # Update counters
            completed_requests += 1
            if result.get('error'):
                failed_requests += 1
                if failed_requests <= 3:  # Show first few errors
                    print(f"❌ Request {i + 1} failed: {result['error']}")
            else:
                successful_requests += 1
            
            self.results.append(result)
            
            # Progress reporting
            progress = completed_requests / total_requests
            for interval_threshold in progress_intervals:
                if progress >= interval_threshold and interval_threshold not in reported_intervals:
                    reported_intervals.add(interval_threshold)
                    elapsed = time.time() - start_time
                    actual_rate = completed_requests / elapsed if elapsed > 0 else 0
                    print(f"🔄 Progress: {progress*100:.0f}% ({completed_requests}/{total_requests}) | "
                          f"Success: {successful_requests} | Failed: {failed_requests} | "
                          f"Target: {self.qps:.1f} req/s | Actual: {actual_rate:.1f} req/s | Elapsed: {elapsed:.1f}s")
                    break
            
            # Rate limiting
            if interval > 0 and i < len(self.dataset.requests) - 1:
                await asyncio.sleep(interval)
        
        # Final statistics
        total_time = time.time() - start_time
        total_latency = sum(r.get('latency', 0) for r in self.results if not r.get('error'))
        total_tokens_generated = sum(r.get('completion_tokens', 0) for r in self.results if not r.get('error'))
        
        print(f"\n🎯 QPS Replay Complete!")
        print(f"📊 Final Statistics:")
        print(f"   • Total requests: {len(self.results)}")
        print(f"   • Successful: {successful_requests}")
        print(f"   • Failed: {failed_requests}")
        print(f"   • Success rate: {(successful_requests/len(self.results)*100):.1f}%" if self.results else "0%")
        print(f"   • Total time: {total_time:.2f}s")
        print(f"   • Target QPS: {self.qps:.1f} req/s")
        print(f"   • Actual rate: {len(self.results)/total_time:.1f} req/s" if total_time > 0 else "∞ req/s")
        if successful_requests > 0:
            print(f"   • Average latency: {total_latency/successful_requests:.3f}s")
            print(f"   • Total tokens generated: {total_tokens_generated}")
            print(f"   • Token generation rate: {total_tokens_generated/total_time:.1f} tokens/s" if total_time > 0 else "∞ tokens/s")
        
        print(f"QPS replay completed. Successful requests: {successful_requests}/{len(self.results)}")
    
    async def run_benchmark(self):
        """Run the benchmark."""
        if self.preserve_timing:
            await self.run_timed_replay()
        else:
            await self.run_qps_replay()
        
        # Save results
        if self.results:
            print(f"\n💾 Saving results to {self.output_file}...")
            with open(self.output_file, 'w', newline='') as csvfile:
                # Use field names expected by post-processing scripts
                fieldnames = ['launch_time', 'finish_time', 'ttft', 'generation_time', 'prompt_tokens', 'generation_tokens', 'total_tokens', 'error']
                writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
                writer.writeheader()
                for result in self.results:
                    # Convert result format to match expected fields
                    converted_result = {
                        'launch_time': result.get('timestamp', 0),  # Use timestamp as launch_time
                        'finish_time': result.get('timestamp', 0) + result.get('latency', 0),  # launch_time + latency
                        'ttft': result.get('latency', 0) * 0.1,  # Estimate TTFT as 10% of total latency
                        'generation_time': result.get('latency', 0) * 0.9,  # Estimate generation time as 90% of total latency
                        'prompt_tokens': result.get('prompt_tokens', 0),
                        'generation_tokens': result.get('completion_tokens', 0),  # Rename completion_tokens to generation_tokens
                        'total_tokens': result.get('total_tokens', 0),
                        'error': result.get('error', '')
                    }
                    writer.writerow(converted_result)
            print(f"✅ Results saved successfully!")
            print(f"📈 Total requests processed: {len(self.results)}")
            print(f"📊 Average latency: {sum(r.get('latency', 0) for r in self.results) / len(self.results):.2f}s")
        else:
            print("⚠️ No results to save!")
        
        print("\n" + "=" * 60)
        print("🎉 TraceReplayer Benchmark Complete!")
        print("=" * 60)

def main():
    """Main function to run the trace replayer benchmark."""
    print("🚀 LMBench TraceReplayer Starting...")
    print("=" * 60)
    
    parser = argparse.ArgumentParser(description='TraceReplayer workload for LMBench')
    parser.add_argument('--model', default='meta-llama/Llama-3.1-8B-Instruct',
                       help='Model name/identifier')
    parser.add_argument('--base-url', default='http://localhost:30080',
                       help='Base URL for the API server')
    parser.add_argument('--output', default='trace_results.csv',
                       help='Output CSV file for results')
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
    
    # Display configuration
    print("📋 Configuration:")
    print(f"   • Model: {args.model}")
    print(f"   • Base URL: {args.base_url}")
    print(f"   • API Type: {args.api_type}")
    print(f"   • Trace File: {args.trace_file}")
    print(f"   • Start Time: {args.start_time}s")
    print(f"   • Duration: {'Full trace' if args.duration == -1 else f'{args.duration}s'}")
    print(f"   • Preserve Timing: {args.preserve_timing}")
    
    # Handle SPEED_UP vs TIME_SCALE conversion
    if args.speed_up is not None:
        # Convert SPEED_UP to internal time_scale: time_scale = 1.0 / speed_up
        args.time_scale = 1.0 / args.speed_up
        print(f"   • Speed Up: {args.speed_up}x (internal time_scale: {args.time_scale})")
    else:
        print(f"   • TIME_SCALE: {args.time_scale} (consider using --speed-up for more intuitive control)")
    
    if not args.preserve_timing:
        print(f"   • QPS Mode: {args.qps} req/s")
    
    print(f"   • Output File: {args.output}")
    print("=" * 60)
    
    # Run benchmark
    benchmark = TraceReplayerBenchmark(args)
    asyncio.run(benchmark.run_benchmark())

if __name__ == "__main__":
    main() 