import os
import sys
from ray import serve
from ray.serve.llm import LLMConfig, build_openai_app

# Check if accelerator type argument is provided
if len(sys.argv) != 2:
    print("Usage: python comparison-baseline.py <accelerator_type>")
    print("Example: python comparison-baseline.py H100")
    sys.exit(1)

accelerator_type = sys.argv[1]

os.environ["VLLM_USE_V1"] = "1"


# --- Define the config ---
llm_config = LLMConfig(
    model_loading_config=dict(
        model_id="Qwen/Qwen3-32B",
        model_source="Qwen/Qwen3-32B",
    ),
    deployment_config=dict(
        autoscaling_config=dict(
            min_replicas=4,
            max_replicas=4,
        )
    ),
    accelerator_type=accelerator_type,
    engine_kwargs=dict(
        tensor_parallel_size=2,
        max_model_len=26000,
    )
)



# --- Start the server ---
serve.start(http_options={"port": 30080})
app = build_openai_app({"llm_configs": [llm_config]})
serve.run(app, blocking=True)