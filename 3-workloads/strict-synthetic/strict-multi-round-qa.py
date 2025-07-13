# strict-multi-round-qa.py is a variation of multi-round-qa.py that adheres strictly to time between requests per user
# Expectation: as QPS increases, TTFT will increase super-linearly
import argparse
import asyncio
import json
import time
import logging
from dataclasses import dataclass
from typing import Optional, List, Dict, Any, cast

import openai
import pandas as pd

from utils import AsyncLoopWrapper, init_logger

logger = init_logger(__name__, logging.INFO)

@dataclass
class WorkloadConfig:
    # Number of concurrent users in the system during benchmarking (call this number N)
    num_concurrent_users: int

    # Number of rounds per user (call this number R)
    num_rounds_per_user: int

    # time between requests per user (avoid math relating total QPS and number of users)
    # time between requests is enforced by having completely synthetic conversation histories, including responses
    # this means that a user does not have to receive a response to make another request
    # it is still the actual responeses from the system that are used to compute TTFT and Generation Time
    time_between_requests_per_user: int

    # Length of shared system prompt shared by all users
    shared_system_prompt_len: int

    # Length of the first question the user sends
    # The first question gets a special position because in QA contexts, it is likely the user 
    # first populates the conversation with lots of documents, text, context
    first_prompt_len: int

    # Length of the follow-up questions to be sent by the user
    # Usually (but not always), follow-up questions are shorter than the first prompt
    # R - 1 follow-up prompts are sent
    follow_up_prompts_len: int

    # Length of the answer to be returned by the model
    answer_len: int

    # Whether to include user id in request header
    # Useful for session based routing orchestration layers (e.g. vLLM Production Stack)
    enable_user_id: bool

    # Model name
    model: str

#  Strict Multi-Round QA Visualization

# 1. Overall QPS = N / time_between_requests_per_user 

# 2. With conversation history_len, question_len, answer_len, and num_rounds_per_user, 
# the token throughput should be completely predetermined and independent of serving engine delays
# this is our definition of "strictness"

# 3. By the R'th round, we want N users to be concurrently in the system, 
# at which point benchmarking begins for 2R more rounds for a total of 3R rounds
# where exactly the N'th to 2N'th users have record_stats = True
# this means the gap between users is R * time_between_requests_per_user / N

#              ┌─────────────── R1 ───────────────┐┌─────────────── R2 ───────────────┐┌─────────────── R3 ───────────────┐
#   Index      01        ...                     R  R + 1      ...                  2R  2R + 1  ...                     3R
#              ────────────────────────────────────┬───────────────────────────────────┬───────────────────────────────────
#
#  Warm-up users (record_stats = False)
#  user-1      -- -- -- -- -- -- -- -- -- -- -- 
#  user-2          -- -- -- -- -- -- -- -- -- -- --
#     ⋮
#  user-N                                        -- -- -- -- --  -- -- -- -- -- --
#
#  Benchmarked users (N < id ≤ 2N) (record_stats = True)
#  user-N+1                                         == == == ==  == == == == == == == ==
#  user-N+2                                             == == == == == == == == == ==  == ==
#     ⋮
#  user-2N                                                                             == == == == == == == == == ==  == 
#
#  New users in final R rounds (record_stats = False)
#  user-2N+1                                                                               -- -- -- -- -- -- -- -- -- -- --
#  user-2N+2                                                                                     -- -- -- -- -- -- -- -- -- 
#     ⋮
#  user-3N                                                                                           -- -- -- -- -- -- -- --



@dataclass
class UserConfig:
    # User id
    user_id: int

    # Whether or not this user will contribute to the final benchmarking statistics or they 
    # are just used as "filler" users to keep the workoad evenly distributed
    record_stats: bool

    # Shared system prompt length
    shared_system_prompt_len: int

    # First prompt length
    first_prompt_len: int

    # Follow-up prompt length
    follow_up_prompts_len: int

    # Answer length
    answer_len: int

    # Time between requests per user
    time_between_requests_per_user: int

    # Num rounds per user
    num_rounds_per_user: int

    # Whether to include user id in request header
    enable_user_id: bool

    @staticmethod
    def new_user_config(user_id: int, workload_config: WorkloadConfig) -> "UserConfig":
        return UserConfig(
            user_id=user_id,
            record_stats=(workload_config.num_concurrent_users < user_id and \
                user_id <= 2 * workload_config.num_concurrent_users),
            shared_system_prompt_len=workload_config.shared_system_prompt_len,
            first_prompt_len=workload_config.first_prompt_len,
            follow_up_prompts_len=workload_config.follow_up_prompts_len,
            answer_len=workload_config.answer_len,
            time_between_requests_per_user=workload_config.time_between_requests_per_user,
            num_rounds_per_user=workload_config.num_rounds_per_user,
            enable_user_id=workload_config.enable_user_id,
        )

class ChatHistory:
    def __init__(self):
        self.history = []
    
    def on_query(self, query: str):
        if len(self.history) == 0 or len(self.history) == 1:
            self.history.append({"role": "user", "content": query})
        else:
            assert self.history[-1]["role"] == "assistant", "Expect system response"
            self.history.append({"role": "user", "content": query})

    # in strict-multi-round-qa, the response should be synthetically generated and
    # on_response() should be called before on_query() after the first query
    def on_response(self, response: str):
        assert len(self.history) > 0, "Expect user query"
        assert self.history[-1]["role"] == "user", "Expect user query"
        self.history.append({"role": "assistant", "content": response})

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
    def __init__(self, base_url: str, model: str, api_type: str = "completions"):
        # For vLLM server, we don't need an API key, but the client requires one
        # Ensure base_url ends with /v1 for vLLM
        if not base_url.endswith('/v1'):
            base_url = base_url.rstrip('/') + '/v1'
        self.client = openai.AsyncOpenAI(
            api_key="vllm_xxxxxxxxxxxxx",  # Dummy API key for vLLM server
            base_url=base_url
        )
        self.model = model
        self.api_type = api_type  # "completions" or "chat"
        logging.info(f"Initialized OpenAI client with base_url={base_url}, model={model}, api_type={api_type}")
        self.loop = AsyncLoopWrapper.GetOrStartLoop()
        self.request_history = []

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

            if self.api_type == "chat":
                # Use chat completions API directly with messages
                # Cast to proper message format for OpenAI client
                chat_messages = cast(List[Any], messages)
                response = await self.client.chat.completions.create(
                    model=self.model,
                    messages=chat_messages,
                    stream=True,
                    max_tokens=max_tokens,
                    temperature=0.0,
                    stream_options={"include_usage": True},
                    extra_headers=extra_headers,
                )

                # Process the streaming response for chat completions
                last_chunk = None
                async for chunk in response:
                    last_chunk = chunk
                    if not chunk.choices:
                        continue

                    # Handle content for chat completions
                    if chunk.choices[0].delta and chunk.choices[0].delta.content is not None:
                        if first_token_time is None and chunk.choices[0].delta.content != "":
                            first_token_time = time.time()
                        words += chunk.choices[0].delta.content

                # Handle token counts if available
                if last_chunk and hasattr(last_chunk, 'usage') and last_chunk.usage is not None:
                    tokens_out = last_chunk.usage.completion_tokens
                    tokens_prefill = last_chunk.usage.prompt_tokens

                # If we didn't get token counts from streaming, try to get them from the final response
                if tokens_out == 0 or tokens_prefill == 0:
                    print("No token counts from streaming, getting final response")
                    print(f"{tokens_out}, {tokens_prefill}")
                    try:
                        final_response = await self.client.chat.completions.create(
                            model=self.model,
                            messages=chat_messages,
                            stream=False,
                        )
                        if hasattr(final_response, 'usage') and final_response.usage is not None:
                            tokens_out = final_response.usage.completion_tokens
                            tokens_prefill = final_response.usage.prompt_tokens
                    except Exception as e:
                        logging.warning(f"Failed to get token counts from final response: {e}")

            else:  # self.api_type == "completions"
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

                # Make the request using completions API
                response = await self.client.completions.create(
                    prompt=prompt,
                    model=self.model,
                    stream=True,
                    max_tokens=max_tokens,
                    temperature=0.0,
                    stream_options={"include_usage": True},
                    extra_headers=extra_headers,
                )

                # Process the streaming response for completions
                last_chunk = None
                async for chunk in response:
                    last_chunk = chunk
                    if not chunk.choices:
                        continue

                    # Handle content for completions
                    if chunk.choices[0].text is not None:
                        if first_token_time is None and chunk.choices[0].text != "":
                            first_token_time = time.time()
                        words += chunk.choices[0].text

                # Handle token counts if available
                if last_chunk and hasattr(last_chunk, 'usage') and last_chunk.usage is not None:
                    tokens_out = last_chunk.usage.completion_tokens
                    tokens_prefill = last_chunk.usage.prompt_tokens

                # If we didn't get token counts from streaming, try to get them from the final response
                if tokens_out == 0 or tokens_prefill == 0:
                    print("No token counts from streaming, getting final response")
                    print(f"{tokens_out}, {tokens_prefill}")
                    try:
                        final_response = await self.client.completions.create(
                            prompt=prompt,
                            model=self.model,
                            stream=False,
                        )
                        if hasattr(final_response, 'usage') and final_response.usage is not None:
                            tokens_out = final_response.usage.completion_tokens
                            tokens_prefill = final_response.usage.prompt_tokens
                    except Exception as e:
                        logging.warning(f"Failed to get token counts from final response: {e}")

            # Calculate timing metrics
            ttft = first_token_time - start_time if first_token_time else 0
            generation_time = time.time() - first_token_time if first_token_time else 0

            return Response(
                body=words,
                ttft=ttft,
                generation_time=generation_time,
                prompt_tokens=tokens_prefill,
                generation_tokens=tokens_out,
                launch_time=start_time,
                finish_time=time.time(),
            )
        
        except Exception as e:
            logging.error(f"Error in _async_launch_request: {str(e)}")
            logging.error(f"Request details - model: {self.model}, messages: {messages}")
            raise

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
        self.record_stats = user_config.record_stats
        self.last_request_time = None
        self.chat_history = ChatHistory()
        self.question_id = 0
        self.unfinished_requests = 0 # this can be a number greater than 1 because answers are synthetic ("strictness")
        self.last_unfinished_log = 0

        self.prompt_lengths = []
        self.generation_lengths = []
        self.ttfts = []
        self.generation_times = []
        self.launch_times = []
        self.finish_times = []

        self.finished = False
    
    # the callback for the request executor
    def _update_result(self, response: Response):
        self.unfinished_requests -= 1
        self.prompt_lengths.append(response.prompt_tokens)
        self.generation_lengths.append(response.generation_tokens)
        self.ttfts.append(response.ttft)
        self.generation_times.append(response.generation_time)
        self.launch_times.append(response.launch_time)
        self.finish_times.append(response.finish_time)
    
    def _gen_dummy_text(self, length):
        return " ".join(["hi"] * length)
    
    def _synthetic_conversation_build(self):
        if len(self.chat_history) == 0:
            shared_system_prompt = self._gen_dummy_text(self.user_config.shared_system_prompt_len)
            self.chat_history.on_query(f"System Prompt: {shared_system_prompt}")
            first_prompt = self._gen_dummy_text(self.user_config.first_prompt_len)
            # write a long story ensures that the model will saturate the entire answer length
            # will be cut off by the generation tokens that we pass in
            self.chat_history.on_query(f"{self.user_config.user_id}: {first_prompt}, write a very long story please.")
        else:
            system_answer = self._gen_dummy_text(self.user_config.answer_len)
            self.chat_history.on_response(f"System Answer: {system_answer}")
            follow_up_prompt = self._gen_dummy_text(self.user_config.follow_up_prompts_len)
            self.chat_history.on_query(f"{self.user_config.user_id}: {follow_up_prompt}, write a very long story please.")
        self.question_id += 1
        logger.debug(
            f"built conversation history for user {self.user_config.user_id}, "
            f"question_id: {self.question_id}, "
        )

    def _launch_new_request(self, timestamp: float, request_executor: RequestExecutor):
        self._synthetic_conversation_build()
        request_executor.launch_request(
            chat_history=self.chat_history,
            max_tokens=self.user_config.answer_len,
            finish_callback=self._update_result,
            extra_headers={"x-user-id": str(self.user_config.user_id)},
        )
        self.unfinished_requests += 1
        self.last_request_time = timestamp

    def step(self, timestamp: float, request_executor: RequestExecutor):
        if self.question_id >= self.user_config.num_rounds_per_user and \
            self.unfinished_requests == 0:
            self.finished = True
            return
        
        # In the strict multi-round-qa, we always send requests when the gap between requests is reached ("strictness")
        if self.question_id < self.user_config.num_rounds_per_user and \
            (self.last_request_time is None or \
            timestamp - self.last_request_time > self.user_config.time_between_requests_per_user):
            self._launch_new_request(timestamp, request_executor)

    # the summary for this user that will be aggregated by the UserSessionManager for final statistics
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
        df["record_stats"] = self.record_stats  # Mark whether this user's stats should be included in benchmarks
        return df

class UserSessionManager:

    def __init__(self, workload_config: WorkloadConfig):
        self.workload_config = workload_config
        self.sessions = []

        self.user_id = 0
        self.last_user_join = 0
        self.session_summaries = []
        self.start_time = None

        self.gap_between_users = workload_config.num_rounds_per_user * \
            workload_config.time_between_requests_per_user / workload_config.num_concurrent_users

    def _create_user_session(self):
        self.user_id += 1
        user_config = UserConfig.new_user_config(self.user_id, self.workload_config)
        user_session = UserSession(user_config)
        self.sessions.append(user_session)
        return user_session
    
    def _remove_finished_sessions(self):
        sessions_to_remove = [s for s in self.sessions if s.finished]

        if len(sessions_to_remove) > 0:
            logger.info(
                f"Removing {len(sessions_to_remove)} finished sessions, now "
                f"active users: {len(self.sessions) - len(sessions_to_remove)}"
            )
            for session in sessions_to_remove:
                # Only record stats for users that are in the benchmarking window
                if session.record_stats:
                    self.session_summaries.append(session.summary())
        self.sessions = [s for s in self.sessions if not s.finished]

    def step(self, timestamp: float, executor: RequestExecutor) -> bool:
        """
        Returns:
            bool: True if the benchmark is not finished, False otherwise
        """
        if self.start_time is None:
            self.start_time = timestamp

        if len(self.sessions) < self.workload_config.num_concurrent_users:
            if timestamp - self.last_user_join > self.gap_between_users:
                new_session = self._create_user_session()
                if new_session is not None:
                    self.last_user_join = timestamp
                    logger.info(
                        f"Joined a new user {self.user_id}, "
                        f"now active users: {len(self.sessions)}"
                    )

        for session in self.sessions:
            session.step(timestamp, executor)

        self._remove_finished_sessions()

        if len(self.session_summaries) >= self.workload_config.num_concurrent_users:
            return False
        return True

    def summary(self) -> pd.DataFrame:
        # we will throw an error if the session summaries are empty (intended, as something went wrong)
        return pd.concat(self.session_summaries)

def parse_arguments():
    parser = argparse.ArgumentParser(description="Parse benchmark configurations.")

    parser.add_argument(
        "--num-concurrent-users",
        type=int,
        required=True,
        help="Number of concurrent users in the system during benchmarking",
    )
    parser.add_argument(
        "--num-rounds-per-user",
        type=int,
        required=True,
        help="Number of rounds per user",
    )
    parser.add_argument(
        "--time-between-requests-per-user",
        type=int,
        required=True,
        help="Time between requests per user (in seconds)",
    )

    parser.add_argument(
        "--shared-system-prompt-len",
        type=int,
        required=True,
        help="Length of the shared system prompt shared by all users (tokens)",
    )

    parser.add_argument(
        "--first-prompt-len",
        type=int,
        required=True,
        help="Length of the first prompt the user sends (tokens)",
    )
    
    parser.add_argument(
        "--follow-up-prompts-len",
        type=int,
        required=True,
        help="Length of the follow-up prompts the user sends (tokens)",
    )

    parser.add_argument(
        "--answer-len",
        type=int,
        required=True,
        help="Length of the answer to be returned by the model (tokens)",
    )

    parser.add_argument(
        "--request-with-user-id",
        action="store_true",
        default=True,
        help="Whether to include user id in request headers",
    )

    parser.add_argument(
        "--model",
        type=str,
        required=True,
        help="Model name",
    )

    parser.add_argument(
        "--base-url",
        type=str,
        required=True,
        help="Base URL of the serving engine endpoint",
    )

    parser.add_argument(
        "--output",
        type=str,
        default="summary.csv",
        help="The output file name (ended with csv or txt) "
        "for the summary csv and txt",
    )

    parser.add_argument(
        "--api-type",
        type=str,
        default="completions",
        choices=["completions", "chat"],
        help="API type to use: completions or chat (default: completions)",
    )

    args = parser.parse_args()
    return args

def main():
    args = parse_arguments()
    step_interval = 0.05 # arbitrarily small granularity of iteration of the busy loop

    executor = RequestExecutor(
        base_url=args.base_url, model=args.model, api_type=args.api_type
    )

    workload_config = WorkloadConfig(
        num_concurrent_users=args.num_concurrent_users,
        num_rounds_per_user=args.num_rounds_per_user,
        time_between_requests_per_user=args.time_between_requests_per_user,
        shared_system_prompt_len=args.shared_system_prompt_len,
        first_prompt_len=args.first_prompt_len,
        follow_up_prompts_len=args.follow_up_prompts_len,
        answer_len=args.answer_len,
        enable_user_id=args.request_with_user_id,
        model=args.model,
    )

    manager = UserSessionManager(workload_config)

    try:
        while True:
            if not manager.step(time.time(), executor):
                break
            time.sleep(step_interval)

    except KeyboardInterrupt:
        logger.info("Interrupted, stopping the benchmark")

    AsyncLoopWrapper.StopLoop()
    summary = manager.summary()
    summary.to_csv(args.output, index=False)

if __name__ == "__main__":
    main()
