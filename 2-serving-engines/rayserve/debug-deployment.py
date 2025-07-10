import os
import sys
from ray import serve
from ray.serve.llm import LLMConfig, build_openai_app

# Check if accelerator type argument is provided
if len(sys.argv) != 2:
    print("Usage: python debug-deployment.py <accelerator_type>")
    print("Example: python debug-deployment.py H100")
    sys.exit(1)

accelerator_type = sys.argv[1]

os.environ["VLLM_USE_V1"] = "1"

# --- Define the config ---
llm_config = LLMConfig(
    model_loading_config=dict(
        model_id="meta-llama/Llama-3.1-8B-Instruct",
        model_source="meta-llama/Llama-3.1-8B-Instruct",
    ),
    deployment_config=dict(
        autoscaling_config=dict(
            min_replicas=1,
            max_replicas=1,
        )
    ),
    accelerator_type=accelerator_type,
    engine_kwargs=dict(
        tensor_parallel_size=1,
    )
)



# --- Start the server ---
serve.start(http_options={"port": 30080})
app = build_openai_app({"llm_configs": [llm_config]})
serve.run(app, blocking=True) 