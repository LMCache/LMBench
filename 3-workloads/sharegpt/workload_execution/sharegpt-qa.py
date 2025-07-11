#!/usr/bin/env python3
"""
sharegpt_benchmark.py – streamlined ShareGPT replay tool
=======================================================

Replays prompts from a ShareGPT‑style JSON file against an OpenAI‑compatible
HTTP endpoint at a fixed QPS, records latency metrics, and writes a CSV report
**sorted by launch_time** so downstream analyses have deterministic ordering.
"""

import argparse
import asyncio
import json
import logging
import time
from dataclasses import dataclass
from typing import List, Optional
import random
import openai
import pandas as pd

from utils import AsyncLoopWrapper, init_logger

logger = init_logger(__name__, logging.INFO)

# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Replay ShareGPT prompts against an OpenAI‑compatible "
                    "endpoint and collect latency statistics.")

    parser.add_argument("--sharegpt-file", default="round_robin_1000_5.json",
                        help="JSON file with ShareGPT prompts (default: %(default)s)")
    parser.add_argument("--base-url", required=True,
                        help="Base URL of the OpenAI‑compatible server")
    parser.add_argument("--model", required=True,
                        help="Model name (e.g. gpt-4o-mini)")
    parser.add_argument("--qps", type=float, required=True,
                        help="Target queries per second")
    parser.add_argument("--output", default="../../../4-latest-results/sharegpt-summary.csv",
                        help="Output CSV filename (default: %(default)s)")
    parser.add_argument("--log-interval", type=int, default=30,
                        help="Seconds between progress logs (default: %(default)s)")
    parser.add_argument("--time", type=int,
                        help="Maximum time to run the benchmark in seconds")
    parser.add_argument("--verbose", action="store_true",
                        help="Enable DEBUG logging")
    parser.add_argument("--request-with-user-id", action="store_true", default=True,
                        help="Whether to include user id in request headers")
    return parser.parse_args()

# ---------------------------------------------------------------------------
# Low‑level request handling
# ---------------------------------------------------------------------------

@dataclass
class Response:
    body: str
    ttft: float
    generation_time: float
    prompt_tokens: int
    generation_tokens: int
    launch_time: float
    finish_time: float


class RequestExecutor:
    """Wrapper over OpenAI completions API (not chat) that measures latency.
    It now accepts a list of messages so that callers can maintain proper
    conversation history. Messages are converted to a single prompt string
    before the request, preserving previous behaviour while enabling the
    chat-history abstraction requested by the user.
    """

    def __init__(self, base_url: str, api_key: str, model: str):
        # Ensure base_url ends with /v1 for vLLM
        if not base_url.endswith('/v1'):
            base_url = base_url.rstrip('/') + '/v1'
        self.client = openai.AsyncOpenAI(api_key=api_key, base_url=base_url)
        self.model = model
        self.loop = AsyncLoopWrapper.GetOrStartLoop()

    async def _async_request(self, messages: list[dict], max_tokens: int, extra_headers=None) -> Response:
        start = time.time()
        first_token: Optional[float] = None
        body = ""

        # Convert chat messages to a single prompt string
        prompt = ""
        for msg in messages:
            role = msg["role"]
            content = msg["content"]
            if role == "system":
                prompt += f"System: {content}\n"
            elif role == "user":
                prompt += f"User: {content}\n"
            elif role == "assistant":
                prompt += f"Assistant: {content}\n"
        prompt += "Assistant: "

        try:
            stream = await self.client.completions.create(
                prompt=prompt,
                model=self.model,
                temperature=0,
                stream=True,
                max_tokens=max_tokens,
                stream_options={"include_usage": True},
                extra_headers=extra_headers,
            )

            async for chunk in stream:
                if not chunk.choices:
                    continue
                delta = chunk.choices[0].text
                if delta:
                    if first_token is None:
                        first_token = time.time()
                    body += delta

            usage = chunk.usage  # type: ignore[attr-defined]
            return Response(
                body=body,
                ttft=(first_token or time.time()) - start,
                generation_time=time.time() - (first_token or start),
                prompt_tokens=usage.prompt_tokens,
                generation_tokens=usage.completion_tokens,
                launch_time=start,
                finish_time=time.time(),
            )
        except Exception as e:
            logger.error(f"Error in request: {str(e)}")
            raise

    def launch_request(self, messages: list[dict], max_tokens: int, on_finish, user_id=None) -> None:
        fut = asyncio.run_coroutine_threadsafe(
            self._async_request(messages, max_tokens, {"x-user-id": str(user_id)} if user_id is not None else None), self.loop)
        fut.add_done_callback(lambda f: on_finish(f.result()))

# ---------------------------------------------------------------------------
# Benchmark runner
# ---------------------------------------------------------------------------

class BenchmarkRunner:
    """Dispatch prompts at desired QPS and collect latency metrics."""

    def __init__(self, prompts: List[dict], executor: RequestExecutor, qps: float, time_limit: Optional[int] = None, request_with_user_id: bool = True):
        self.prompts = prompts
        self.executor = executor
        self.qps = qps
        self.time_limit = time_limit
        self.results: List[Response] = []
        self._next_idx = 0
        self.start_time = time.time()
        self.request_with_user_id = request_with_user_id

    def _on_finish(self, resp: Response):
        self.results.append(resp)

    def run(self) -> pd.DataFrame:
        logger.info("Benchmark started: %d prompts at %.2f QPS", len(self.prompts), self.qps)

        # conversation_id -> history list; each history item is {'role': str, 'content': str}
        histories: dict[int, list[dict]] = {}

        while self._next_idx < len(self.prompts):
            # Check time limit
            if self.time_limit is not None and time.time() - self.start_time > self.time_limit:
                logger.info(f"Time limit of {self.time_limit} seconds reached, stopping benchmark")
                break

            scheduled = self.start_time + self._next_idx / self.qps
            if time.time() < scheduled:
                time.sleep(0.001)
                continue

            entry = self.prompts[self._next_idx]

            conv_id = entry.get("conversation_id", self._next_idx)

            # Initialise history with a static system prompt once
            if conv_id not in histories:
                histories[conv_id] = [
                    {"role": "system", "content": "You are a helpful assistant."}
                ]

            # Append new user message
            histories[conv_id].append({"role": "user", "content": entry["input"]})

            # Trim history to keep the prompt within model context –
            # keep the system message plus the most recent 32 messages
            if len(histories[conv_id]) > 33:
                sys_msg = histories[conv_id][0]
                histories[conv_id] = [sys_msg] + histories[conv_id][-32:]

            # Build prompt string from full history
            prompt_parts = []
            for msg in histories[conv_id]:
                role = msg["role"]
                content = msg["content"]
                if role == "system":
                    prompt_parts.append(f"System: {content}\n")
                elif role == "user":
                    prompt_parts.append(f"User: {content}\n")
                else:  # assistant
                    prompt_parts.append(f"Assistant: {content}\n")
            prompt_parts.append("Assistant: ")
            prompt = "".join(prompt_parts)

            max_tokens = min(256, entry.get("output_length", 128))

            user_id = conv_id if self.request_with_user_id else None

            self.executor.launch_request(histories[conv_id].copy(), max_tokens, self._on_finish, user_id)

            self._next_idx += 1

        AsyncLoopWrapper.WaitLoop()  # wait for inflight requests
        logger.info("All requests completed")

        df = pd.DataFrame({
            "prompt_tokens": [r.prompt_tokens for r in self.results],
            "generation_tokens": [r.generation_tokens for r in self.results],
            "ttft": [r.ttft for r in self.results],
            "generation_time": [r.generation_time for r in self.results],
            "launch_time": [r.launch_time for r in self.results],
            "finish_time": [r.finish_time for r in self.results],
        })

        # Ensure deterministic ordering for downstream scripts/visualisation
        return df.sort_values("launch_time").reset_index(drop=True)

# ---------------------------------------------------------------------------
# Summary helpers
# ---------------------------------------------------------------------------

def log_summary(df: pd.DataFrame):
    duration = df["finish_time"].max() - df["launch_time"].min()
    throughput = len(df) / duration if duration > 0 else 0
    logger.info("Completed %d requests in %.2fs (%.2f QPS)", len(df), duration, throughput)
    logger.info("Average TTFT: %.3fs", df["ttft"].mean())
    logger.info("Avg generation speed per req: %.1f tokens/s", (
        df["generation_tokens"] / df["generation_time"]).mean())

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    if args.verbose:
        logger.setLevel(logging.DEBUG)

    try:
        # Load prompts
        with open(args.sharegpt_file, "r") as f:
            prompts = json.load(f)
        logger.info(f"Loaded {len(prompts)} ShareGPT entries")

        # Initialize executor
        executor = RequestExecutor(args.base_url, "EMPTY", args.model)

        # Run benchmark
        runner = BenchmarkRunner(prompts, executor, args.qps, args.time, args.request_with_user_id)
        df = runner.run()

        # Write results
        df.to_csv(args.output, index=False)
        logger.info(f"Results written to {args.output}")

        # TODO: call the summarize script here
        # Make sure to add extra arguments to the script including:
        # LIMIT
        # MIN_ROUNDS
        # START_ROUND

        # Log summary
        log_summary(df)
    finally:
        # Always stop the asyncio loop
        AsyncLoopWrapper.StopLoop()
        logger.info("Benchmark completed and asyncio loop stopped")

if __name__ == "__main__":
    main()
