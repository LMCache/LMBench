from ray import serve
import logging
import os
import json
import time
import random

# Configure logging
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("ray_openai_api")

# Simulated LLM responses for different prompts
SIMULATED_RESPONSES = {
    "hello": "Hello! I'm a simulated LLM response from the KubeRay API. How can I assist you today?",
    "how are you": "I'm functioning well, thank you for asking! I'm a simulated LLM running on KubeRay.",
    "tell me a joke": "Why don't scientists trust atoms? Because they make up everything!",
    "what is ray": "Ray is an open-source unified framework for scaling AI and Python applications. Ray includes Ray Core, Ray Train, Ray Serve, Ray Tune, and Ray RLlib. It's designed to make distributed computing simpler and more efficient.",
    "what is kuberay": "KubeRay is a Kubernetes operator that helps manage Ray clusters on Kubernetes. It provides custom resources like RayCluster, RayJob, and RayService to simplify deploying and scaling Ray applications in Kubernetes environments.",
    "what can you do": "I'm a simulated LLM API that can respond to messages with predefined answers. In a real deployment, I would be connected to an actual LLM like Llama-3.1-8B-Instruct to provide more dynamic and comprehensive responses based on a wide range of inputs."
}

DEFAULT_RESPONSE = "This is a simulated response from the KubeRay API. In a real deployment, this would be generated by the LLM based on your specific query."

def get_simulated_response(message):
    # Convert message to lowercase for case-insensitive matching
    message_lower = message.lower()

    # Check for exact matches first
    for key, response in SIMULATED_RESPONSES.items():
        if key in message_lower:
            return response

    # If no exact match, return the default response
    return DEFAULT_RESPONSE

@serve.deployment(route_prefix="/v1")
class OpenAICompatibleAPI:
    def __init__(self):
        logger.info("Initializing OpenAI-compatible API")
        self.model_id = os.environ.get("MODEL_URL", "meta-llama/Llama-3.1-8B-Instruct")
        logger.info(f"Using model ID: {self.model_id}")

    async def __call__(self, request):
        url_path = request.url.path
        logger.info(f"Received request at path: {url_path}")

        # Handle different endpoints
        if url_path == "/v1/chat/completions":
            return await self.handle_chat_completions(request)
        elif url_path == "/v1/completions":
            return await self.handle_completions(request)
        elif url_path == "/v1/models":
            return await self.handle_models()
        else:
            logger.warning(f"Unsupported endpoint: {url_path}")
            return {"error": f"Unsupported endpoint: {url_path}"}, 404

    async def handle_chat_completions(self, request):
        try:
            # Get the data from request
            data = await request.json()
            logger.info(f"Chat completion request: {data}")

            # Extract the latest user message
            user_message = ""
            for message in data.get('messages', []):
                if message.get('role') == 'user':
                    user_message = message.get('content', '')

            # Get a simulated response based on the user's message
            response_content = get_simulated_response(user_message)

            # Add some simulated thinking delay (0.5-2 seconds)
            thinking_time = random.uniform(0.5, 2.0)
            time.sleep(thinking_time)

            # Mock response for testing
            response = {
                "id": f"chatcmpl-{int(time.time()*1000)}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": self.model_id,
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": response_content
                        },
                        "finish_reason": "stop"
                    }
                ],
                "usage": {
                    "prompt_tokens": len(user_message.split()) * 2,
                    "completion_tokens": len(response_content.split()) * 2,
                    "total_tokens": (len(user_message.split()) + len(response_content.split())) * 2
                }
            }

            logger.info(f"Returning chat completion response for {data.get('messages', [])}")
            return response
        except Exception as e:
            logger.error(f"Error handling chat completion: {str(e)}")
            return {"error": str(e)}, 500

    async def handle_completions(self, request):
        try:
            # Get the data from request
            data = await request.json()
            logger.info(f"Completion request: {data}")

            # Extract the prompt
            prompt = data.get('prompt', '')

            # Get a simulated response based on the prompt
            response_text = get_simulated_response(prompt)

            # Add some simulated thinking delay (0.5-2 seconds)
            thinking_time = random.uniform(0.5, 2.0)
            time.sleep(thinking_time)

            # Mock response for testing
            response = {
                "id": f"cmpl-{int(time.time()*1000)}",
                "object": "text_completion",
                "created": int(time.time()),
                "model": self.model_id,
                "choices": [
                    {
                        "text": response_text,
                        "index": 0,
                        "finish_reason": "stop"
                    }
                ],
                "usage": {
                    "prompt_tokens": len(prompt.split()) * 2,
                    "completion_tokens": len(response_text.split()) * 2,
                    "total_tokens": (len(prompt.split()) + len(response_text.split())) * 2
                }
            }

            logger.info(f"Returning completion response for {prompt}")
            return response
        except Exception as e:
            logger.error(f"Error handling completion: {str(e)}")
            return {"error": str(e)}, 500

    async def handle_models(self):
        try:
            # Mock response with available models
            response = {
                "object": "list",
                "data": [
                    {
                        "id": self.model_id,
                        "object": "model",
                        "created": int(time.time()),
                        "owned_by": "organization-owner"
                    }
                ]
            }
            logger.info("Returning models list")
            return response
        except Exception as e:
            logger.error(f"Error handling models list: {str(e)}")
            return {"error": str(e)}, 500

# Initialize the deployment
deployment = OpenAICompatibleAPI.bind()