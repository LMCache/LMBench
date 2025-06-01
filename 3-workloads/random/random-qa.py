#!/usr/bin/env python3

import argparse
import asyncio
import json
import logging
import time
import random
import string
from dataclasses import dataclass
from typing import Optional, List, Dict

import openai
import pandas as pd

from utils import AsyncLoopWrapper, init_logger

logger = init_logger(__name__, logging.INFO)


@dataclass
class WorkloadConfig:
    # Max number of users in the system concurrently
    num_users: int

    # Length of random prompt
    prompt_len: int

    # Length of the answer in one round
    answer_len: int

    # Number of rounds in the conversation
    num_rounds: int

    # Overall QPS
    qps: int

    # Model name
    model: str

    # Whether to include user id in request header
    enable_user_id: bool


@dataclass
class UserConfig:
    # User id
    user_id: int

    # Random prompt length
    prompt_len: int

    # Answer length
    answer_len: int

    # Gap between two requests
    gap_between_requests: int

    # Num rounds
    num_rounds: int

    # Whether to include user id in request header
    enable_user_id: bool

    @staticmethod
    def new_user_config(user_id: int, workload_config: WorkloadConfig) -> "UserConfig":
        return UserConfig(
            user_id=user_id,
            prompt_len=workload_config.prompt_len,
            answer_len=workload_config.answer_len,
            gap_between_requests=workload_config.num_users / workload_config.qps,
            num_rounds=workload_config.num_rounds,
            enable_user_id=workload_config.enable_user_id,
        )


class ChatHistory:

    def __init__(self):
        self.history = []

    def on_user_query(self, query: str):
        # For random workload, each query is independent (no shared history)
        self.history = [{"role": "user", "content": query}]

    def on_system_response(self, response: str):
        # We don't maintain history for random workload to avoid shared prefixes
        pass

    def get_messages_for_openai(self):
        return self.history

    def __len__(self):
        return len(self.history)


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

    def __init__(self, base_url: str, model: str):
        self.base_url = base_url
        self.model = model
        self.loop = AsyncLoopWrapper.GetOrStartLoop()
        self.client = openai.AsyncOpenAI(
            base_url=base_url,
            api_key="dummy-key",
        )

    async def _async_launch_request(self, messages: List[Dict[str, str]], max_tokens: int,
                                    extra_headers: Optional[Dict[str, str]] = None):
        try:
            logging.info(f"Sending request to model {self.model} with messages: {messages}")

            # Initialize response tracking variables
            words = ""
            tokens_out = 0
            tokens_prefill = 0
            start_time = time.time()
            first_token_time = None

            # Make the request
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=messages,
                stream=True,
                max_tokens=max_tokens,
                temperature=0.0,
                stream_options={"include_usage": True},
                extra_headers=extra_headers,
            )

            # Process the streaming response
            async for chunk in response:
                if not chunk.choices:
                    continue

                # Handle content
                if chunk.choices[0].delta.content is not None:
                    if first_token_time is None and chunk.choices[0].delta.content != "":
                        first_token_time = time.time()
                    words += chunk.choices[0].delta.content

            # Handle token counts if available
            if hasattr(chunk, 'usage') and chunk.usage is not None:
                tokens_out = chunk.usage.completion_tokens
                tokens_prefill = chunk.usage.prompt_tokens

            end_time = time.time()
            ttft = first_token_time - start_time if first_token_time else 0
            generation_time = end_time - (first_token_time or start_time)

            return Response(
                body=words,
                ttft=ttft,
                generation_time=generation_time,
                prompt_tokens=tokens_prefill,
                generation_tokens=tokens_out,
                launch_time=start_time,
                finish_time=end_time,
            )

        except Exception as e:
            logger.error(f"Error in request: {e}")
            return Response(
                body="",
                ttft=0,
                generation_time=0,
                prompt_tokens=0,
                generation_tokens=0,
                launch_time=time.time(),
                finish_time=time.time(),
            )

    def launch_request(
        self,
        chat_history: ChatHistory,
        max_tokens: int,
        finish_callback,
        extra_headers=None,
    ):
        """
        finish_callback: Callable[[Response], None]
        """
        messages = chat_history.get_messages_for_openai()
        real_callback = lambda x: finish_callback(x.result())
        future = asyncio.run_coroutine_threadsafe(
            self._async_launch_request(messages, max_tokens, extra_headers), self.loop
        )
        future.add_done_callback(real_callback)


class UserSession:

    def __init__(self, user_config: UserConfig):
        self.user_config = user_config
        self.last_request_time = None
        self.chat_history = ChatHistory()
        self.question_id = 0

        self.has_unfinished_request = False
        self.last_unfinished_log = 0

        self.prompt_lengths = []
        self.generation_lengths = []
        self.ttfts = []
        self.generation_times = []
        self.launch_times = []
        self.finish_times = []

        self.finished = False

    def _update_result(self, response: Response):
        self.prompt_lengths.append(response.prompt_tokens)
        self.generation_lengths.append(response.generation_tokens)
        self.ttfts.append(response.ttft)
        self.generation_times.append(response.generation_time)
        self.launch_times.append(response.launch_time)
        self.finish_times.append(response.finish_time)

    def _generate_random_text(self, target_words: int) -> str:
        """Generate random text with approximately target_words words."""
        words = []
        for _ in range(target_words):
            # Generate random words of varying lengths
            word_length = random.randint(3, 12)
            word = ''.join(random.choices(string.ascii_lowercase, k=word_length))
            words.append(word)
        return ' '.join(words)

    def _build_random_prompt(self):
        """Build a completely random prompt with no shared prefix."""
        self.question_id += 1

        # Generate random content with exact prompt length
        random_content = self._generate_random_text(self.user_config.prompt_len)

        # Create a unique prompt with no shared prefix
        prompt = f"Question {self.question_id} for user {self.user_config.user_id}: {random_content}. Please provide a detailed response."

        return prompt

    def _launch_new_request(self, timestamp: float, request_executor: RequestExecutor):
        prompt = self._build_random_prompt()

        # Each request is completely independent - no shared history
        self.chat_history.on_user_query(prompt)

        logger.debug(
            f"User {self.user_config.user_id} issues random request {self.question_id}"
        )

        max_tokens = self.user_config.answer_len
        request_executor.launch_request(
            self.chat_history,
            max_tokens,
            self._on_request_finished,
            extra_headers={"x-user-id": str(self.user_config.user_id)},
        )
        self.has_unfinished_request = True
        self.last_request_time = timestamp

    def _on_request_finished(self, response: Response):
        self.chat_history.on_system_response(response.body)
        self.has_unfinished_request = False
        logger.debug(
            f"User {self.user_config.user_id} finished random request. "
            f"Prompt tokens: {response.prompt_tokens}, "
            f"generation tokens: {response.generation_tokens}"
        )
        self._update_result(response)

    def set_internal_state(self, offset: float, timestamp: float):
        """Tell the session is the 'offset' seconds after the start"""
        assert len(self.chat_history) == 0, (
            "Internal state should be set " "before the first request"
        )

        num_passed_questions = int(offset / self.user_config.gap_between_requests) + 1

        passed_time = (num_passed_questions - 1) * self.user_config.gap_between_requests

        self.last_request_time = timestamp - offset + passed_time
        self.question_id = num_passed_questions
        logger.debug(
            f"Set internal state for user {self.user_config.user_id}, "
            f"question_id: {self.question_id}, "
            f"last_request_time: {self.last_request_time}"
        )

    def step(self, timestamp: float, request_executor: RequestExecutor):
        if (
            self.question_id >= self.user_config.num_rounds
            and not self.has_unfinished_request
        ):
            self.finished = True
            return

        if self.last_request_time is None:
            self._launch_new_request(timestamp, request_executor)
            return

        if timestamp - self.last_request_time > self.user_config.gap_between_requests:
            if self.has_unfinished_request:
                if timestamp - self.last_unfinished_log > 10:
                    logger.warning(
                        f"User {self.user_config.user_id} has an unfinished "
                        "request and unable to fit the QPS requirement."
                    )
                    self.last_unfinished_log = timestamp
                return

            self._launch_new_request(timestamp, request_executor)
            return

    def summary(self) -> pd.DataFrame:
        df = pd.DataFrame()
        df["prompt_tokens"] = self.prompt_lengths
        df["generation_tokens"] = self.generation_lengths
        df["ttft"] = self.ttfts
        df["generation_time"] = self.generation_times
        df["user_id"] = self.user_config.user_id
        df["question_id"] = range(1, len(self.prompt_lengths) + 1)
        df["launch_time"] = self.launch_times
        df["finish_time"] = self.finish_times
        return df


class UserSessionManager:

    def __init__(self, workload_config: WorkloadConfig, init_user_id=0):
        self.workload_config = workload_config
        self.sessions = []

        gap_between_requests_per_user = workload_config.num_users / workload_config.qps
        session_alive_time = gap_between_requests_per_user * (
            workload_config.num_rounds - 1
        )
        self.gap_between_users = session_alive_time / (workload_config.num_users + 0)
        self.ramp_up_time = workload_config.num_users * self.gap_between_users

        logger.info(
            f"Gap between users: {self.gap_between_users} secs.\n"
            f"Gap between user reqs: {gap_between_requests_per_user} secs.\n"
            f"Expected length of user session: {session_alive_time} secs."
        )

        self.user_id = init_user_id
        self.last_user_join = 0
        self.session_summaries = []
        self.start_time = None

        self.need_ramp_up = True

    def _create_user_session(self):
        user_config = UserConfig.new_user_config(self.user_id, self.workload_config)
        self.user_id += 1
        return UserSession(user_config)

    def _ramp_up(self, timestamp: float, ramp_up_time: float):
        for i in range(self.workload_config.num_users):
            new_session = self._create_user_session()
            offset = ramp_up_time - i * self.gap_between_users
            if offset < 0:
                break
            new_session.set_internal_state(offset, timestamp)
            self.sessions.append(new_session)
        self.need_ramp_up = False

    def step(self, timestamp: float, request_executor: RequestExecutor):
        if self.start_time is None:
            self.start_time = timestamp

        if self.need_ramp_up:
            self._ramp_up(timestamp, self.ramp_up_time)

        for session in self.sessions:
            session.step(timestamp, request_executor)

        # Remove finished sessions
        finished_sessions = [s for s in self.sessions if s.finished]
        for session in finished_sessions:
            self.session_summaries.append(session.summary())
            self.sessions.remove(session)

    def summary(self, start_time: float, end_time: float) -> pd.DataFrame:
        all_summaries = self.session_summaries.copy()
        for session in self.sessions:
            all_summaries.append(session.summary())

        if not all_summaries:
            return pd.DataFrame()

        combined_df = pd.concat(all_summaries, ignore_index=True)

        # Filter by time range
        combined_df = combined_df[
            (combined_df["launch_time"] >= start_time) &
            (combined_df["launch_time"] <= end_time)
        ]

        logger.info(f"Summary from {start_time} to {end_time}: {len(combined_df)} requests")
        if len(combined_df) > 0:
            logger.info(f"Average TTFT: {combined_df['ttft'].mean():.3f}s")
            logger.info(f"Average generation time: {combined_df['generation_time'].mean():.3f}s")
            logger.info(f"Average prompt tokens: {combined_df['prompt_tokens'].mean():.1f}")
            logger.info(f"Average generation tokens: {combined_df['generation_tokens'].mean():.1f}")

        return combined_df


def parse_arguments():
    parser = argparse.ArgumentParser(description="Parse random workload benchmark configurations.")

    parser.add_argument(
        "--num-users",
        type=int,
        required=True,
        help="Max number of users in the system concurrently",
    )
    parser.add_argument(
        "--prompt-len",
        type=int,
        required=True,
        help="Length of random prompts (in words)",
    )
    parser.add_argument(
        "--answer-len",
        type=int,
        required=True,
        help="Length of the answer in one round (max tokens)",
    )
    parser.add_argument(
        "--num-rounds",
        type=int,
        required=True,
        help="Number of rounds in the conversation",
    )
    parser.add_argument("--qps", type=float, required=True, help="Overall QPS")
    parser.add_argument("--model", type=str, required=True, help="Model name")
    parser.add_argument(
        "--base-url",
        type=str,
        required=True,
        help="Base URL of the serving engine endpoint",
    )
    parser.add_argument(
        "--time",
        type=int,
        required=False,
        help="The time to run the simulation in seconds",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="summary.csv",
        help="The output file name (ended with csv) for the summary",
    )
    parser.add_argument(
        "--init-user-id", type=int, default=0, help="The initial user id to start with"
    )
    parser.add_argument(
        "--request-with-user-id",
        action="store_true",
        default=True,
        help="Whether to include user id in request headers",
    )
    parser.add_argument(
        "--log-interval",
        type=int,
        default=30,
        help="The time between two summary loggings in seconds",
    )

    return parser.parse_args()


def main():
    args = parse_arguments()
    step_interval = 0.1

    executor = RequestExecutor(
        base_url=args.base_url, model=args.model
    )

    workload_config = WorkloadConfig(
        num_users=args.num_users,
        prompt_len=args.prompt_len,
        answer_len=args.answer_len,
        num_rounds=args.num_rounds,
        qps=args.qps,
        model=args.model,
        enable_user_id=args.request_with_user_id,
    )

    manager = UserSessionManager(
        workload_config, init_user_id=args.init_user_id
    )

    num_steps = 0
    start_time = time.time()
    last_summary_time = start_time
    try:
        while True:
            num_steps += 1
            manager.step(time.time(), executor)
            time.sleep(step_interval)

            if time.time() - last_summary_time > args.log_interval:
                manager.summary(last_summary_time, time.time())
                last_summary_time = time.time()

            if args.time is not None and time.time() - start_time > args.time:
                break

    except KeyboardInterrupt:
        logger.info("Interrupted, waiting for the final result")

    AsyncLoopWrapper.StopLoop()

    logger.info(f"Finished benchmarking, dumping summary to {args.output}")
    summary = manager.summary(0, time.time())
    summary.to_csv(args.output, index=False)


if __name__ == "__main__":
    main()
