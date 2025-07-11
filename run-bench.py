#!/usr/bin/env python3

import yaml
import os
import subprocess
import time
import uuid
from pathlib import Path
from typing import Dict, Any, Union, Optional
import sys

GLOBAL_ARGS = None # MIGHT be set in parse_args()

# Global variables passed between stages in the pipeline
MODEL_URL = None # MUST be set in setup_baseline()
HF_TOKEN = None # MUST be set in setup_baseline()
KEY = None # MUST be set in run_workload()
CURRENT_SERVING_INDEX = None # Track which serving baseline we're currently running
CURRENT_SERVING_CONFIG = None # Track the current serving configuration
CURRENT_SPEC_CONFIG = None # Track the current spec configuration
CURRENT_SPEC_FILE_PATH = None # Track the current spec file path
LMBENCH_SESSION_ID = None # MUST be set in main() - unique identifier for this benchmarking session

def read_run_bench_config() -> Dict[str, Any]:
    """Read and parse the run-bench.yaml file."""
    with open('run-bench.yaml', 'r') as f:
        config = yaml.safe_load(f)

        if '0-bench-specs' not in config:
            raise ValueError("0-bench-specs field is missing in run-bench.yaml")

        spec_files = config['0-bench-specs']
        if not isinstance(spec_files, list):
            raise ValueError("0-bench-specs must be a list of spec files")

        if len(spec_files) == 0:
            raise ValueError("At least one spec file must be specified in 0-bench-specs")

        # Validate infrastructure configuration
        if '1-infrastructure' not in config:
            raise ValueError("1-infrastructure field is missing in run-bench.yaml")

        infrastructure_config = config['1-infrastructure']
        if not isinstance(infrastructure_config, dict):
            raise ValueError("1-infrastructure must be a dictionary")

        location = infrastructure_config.get('Location')
        if not location:
            raise ValueError("Location must be specified in 1-infrastructure")

        if location not in ['NoBench', 'LocalMinikube', 'LMCacheGKE', 'Local-Flat']:
            raise ValueError(f"Unsupported infrastructure location: {location}")

        if location == 'LMCacheGKE':
            if 'numClusterGPUs' not in infrastructure_config:
                raise ValueError("numClusterGPUs must be specified for LMCacheGKE")
            if not isinstance(infrastructure_config['numClusterGPUs'], int):
                raise ValueError("numClusterGPUs must be an integer")

        print(f"Validated run-bench.yaml with infrastructure location: {location}")
        return config

def substitute_hf_token_in_config(config: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively substitute <YOUR_HF_TOKEN> with the HF_TOKEN environment variable."""
    hf_token = os.environ.get('HF_TOKEN')
    if not hf_token:
        print("Warning: HF_TOKEN environment variable must be set!")
        sys.exit(1)

    def recursive_substitute(obj: Any) -> Any:
        if isinstance(obj, dict):
            return {k: recursive_substitute(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [recursive_substitute(item) for item in obj]
        elif isinstance(obj, str) and obj == '<YOUR_HF_TOKEN>':
            return hf_token
        else:
            return obj

    return recursive_substitute(config)

def read_and_process_spec_file(spec_file_path: str) -> Dict[str, Any]:
    """Read a single spec file and process HF_TOKEN substitution."""
    full_path = Path('0-bench-specs') / spec_file_path

    if not full_path.exists():
        raise FileNotFoundError(f"Spec file not found: {full_path}")

    with open(full_path, 'r') as f:
        config = yaml.safe_load(f)

    # Substitute HF_TOKEN
    config = substitute_hf_token_in_config(config)

    # Validate the config using the existing validation logic
    return validate_single_spec_config(config, str(full_path))

def validate_single_spec_config(config: Dict[str, Any], file_path: str) -> Dict[str, Any]:
    """Validate a single spec configuration using the existing validation logic."""
    # Validate Name field
    if 'Name' not in config:
        raise ValueError(f"Name field is missing in {file_path}")

    # Validate that Serving is a list of baselines
    if 'Serving' not in config:
        raise ValueError(f"Serving configuration is missing in {file_path}")

    serving_configs = config['Serving']
    if not isinstance(serving_configs, list):
        raise ValueError(f"Serving configuration must be a list of baseline configurations in {file_path}")

    if len(serving_configs) == 0:
        raise ValueError(f"At least one serving baseline must be specified in {file_path}")

    # Validate each serving baseline configuration
    for i, serving_config in enumerate(serving_configs):
        if not isinstance(serving_config, dict) or len(serving_config) != 1:
            raise ValueError(f"Serving baseline {i} must be a dict with exactly one key (the baseline type) in {file_path}")

        baseline_type = list(serving_config.keys())[0]
        baseline_config = serving_config[baseline_type]

        print(f"Validating serving baseline {i}: {baseline_type} in {file_path}")

        if baseline_type == 'SGLang':
            script_name = baseline_config.get('scriptName')
            model_url = baseline_config.get('modelURL')
            api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
            if not script_name:
                raise ValueError(f"scriptName must be specified for SGLang baseline {i} in {file_path}")
            if not model_url:
                raise ValueError(f"modelURL must be specified for SGLang baseline {i} in {file_path}")
            if api_type not in ['completions', 'chat']:
                raise ValueError(f"apiType must be 'completions' or 'chat' for SGLang baseline {i} in {file_path}, got: {api_type}")
        elif baseline_type == 'RayServe':
            script_name = baseline_config.get('scriptName')
            accelerator_type = baseline_config.get('acceleratorType')
            model_url = baseline_config.get('modelURL')
            api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
            if not script_name:
                raise ValueError(f"scriptName must be specified for RayServe baseline {i} in {file_path}")
            if not accelerator_type:
                raise ValueError(f"acceleratorType must be specified for RayServe baseline {i} in {file_path}")
            if not model_url:
                raise ValueError(f"modelURL must be specified for RayServe baseline {i} in {file_path}")
            if api_type not in ['completions', 'chat']:
                raise ValueError(f"apiType must be 'completions' or 'chat' for RayServe baseline {i} in {file_path}, got: {api_type}")
        elif baseline_type == 'Helm-ProductionStack':
            helm_config = baseline_config.get('helmConfigSelection', '')
            hf_token = baseline_config.get('hf_token')
            model_url = baseline_config.get('modelURL')
            api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
            if not helm_config:
                raise ValueError(f"helmConfigSelection must be specified for Helm-ProductionStack baseline {i} in {file_path}")
            if not hf_token:
                raise ValueError(f"hf_token must be specified for Helm-ProductionStack baseline {i} in {file_path}")
            if not model_url:
                raise ValueError(f"modelURL must be specified for Helm-ProductionStack baseline {i} in {file_path}")
            if api_type not in ['completions', 'chat']:
                raise ValueError(f"apiType must be 'completions' or 'chat' for Helm-ProductionStack baseline {i} in {file_path}, got: {api_type}")
        elif baseline_type == 'Direct-ProductionStack':
            model_url = baseline_config.get('modelURL')
            hf_token = baseline_config.get('hf_token')
            api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
            if not model_url:
                raise ValueError(f"modelURL must be specified for Direct-ProductionStack baseline {i} in {file_path}")
            if not hf_token:
                raise ValueError(f"hf_token must be specified for Direct-ProductionStack baseline {i} in {file_path}")
            if api_type not in ['completions', 'chat']:
                raise ValueError(f"apiType must be 'completions' or 'chat' for Direct-ProductionStack baseline {i} in {file_path}, got: {api_type}")
        elif baseline_type == 'LLM-D':
            config_selection = baseline_config.get('configSelection')
            model_url = baseline_config.get('modelURL')
            hf_token = baseline_config.get('hf_token')
            api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
            if not config_selection:
                raise ValueError(f"configSelection must be specified for LLM-D baseline {i} in {file_path}")
            if not model_url:
                raise ValueError(f"modelURL must be specified for LLM-D baseline {i} in {file_path}")
            if not hf_token:
                raise ValueError(f"hf_token must be specified for LLM-D baseline {i} in {file_path}")
            if api_type not in ['completions', 'chat']:
                raise ValueError(f"apiType must be 'completions' or 'chat' for LLM-D baseline {i} in {file_path}, got: {api_type}")
        elif baseline_type == 'Dynamo':
            config_selection = baseline_config.get('configSelection')
            model_url = baseline_config.get('modelURL')
            api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
            if not config_selection:
                raise ValueError(f"configSelection must be specified for Dynamo baseline {i} in {file_path}")
            if not model_url:
                raise ValueError(f"modelURL must be specified for Dynamo baseline {i} in {file_path}")
            if api_type not in ['completions', 'chat']:
                raise ValueError(f"apiType must be 'completions' or 'chat' for Dynamo baseline {i} in {file_path}, got: {api_type}")
        else:
            raise ValueError(f"Unsupported baseline type: {baseline_type} in baseline {i} in {file_path}")

    # Note: Infrastructure validation is now handled at the run-bench.yaml level
    # Individual spec files no longer need to specify infrastructure

    print(f"Validated all serving baselines in {file_path}")
    return config

# 1. Infrastructure Setup
def setup_infrastructure(config: Dict[str, Any]) -> None:
    """Set up the infrastructure based on the configuration."""
    if 'Infrastructure' not in config:
        raise ValueError("Infrastructure configuration is missing in bench-spec.yaml")

    location = config['Infrastructure'].get('Location')
    if not location:
        raise ValueError("Infrastructure Location is not specified in bench-spec.yaml")
    if location == 'NoBench':
        print("Not running any benchmarks!")
        sys.exit(0)
    elif location == 'LocalMinikube':
        minikube_installation(config)
    elif location == 'LMCacheGKE':
        start_gke_cluster(config)
    else:
        raise ValueError(f"Unsupported infrastructure location: {location}")

def minikube_installation(config: Dict[str, Any]) -> None:
    script_path = Path(__file__).parent / '1-infrastructure' / 'local-minikube' / 'install-local-minikube.sh'

    if not script_path.exists():
        raise FileNotFoundError(f"Installation script not found at {script_path}")

    # Make the script executable if it isn't already
    os.chmod(script_path, 0o755)

    # Execute the installation script
    print("Setting up local minikube environment...")
    # This is blocking
    result = subprocess.run([str(script_path)], check=True)

    if result.returncode == 0:
        print("Local minikube environment setup completed successfully")
    else:
        raise RuntimeError("Failed to set up local minikube environment")

def start_gke_cluster(config: Dict[str, Any]) -> None:
    script_path = Path(__file__).parent / '1-infrastructure' / 'lmcache-gke' / 'run-gke.sh'
    if not script_path.exists():
        raise FileNotFoundError(f"GKE cluster setup script not found at {script_path}")

    # add execution permission
    os.chmod(script_path, 0o755)

    # Execute the script
    num_gpus = config['Infrastructure'].get('numClusterGPUs')
    a100_vram = config['Infrastructure'].get('A100_VRAM', "40")
    if not num_gpus:
        raise ValueError("numClusterGPUs must be specified in bench-spec.yaml for GKE cluster setup")
    result = subprocess.run([str(script_path), str(num_gpus), str(a100_vram)], check=True)

    if result.returncode == 0:
        print("GKE cluster setup completed successfully")
    else:
        raise RuntimeError("Failed to set up GKE cluster")

def setup_infrastructure_from_run_bench_config(infrastructure_config: Dict[str, Any]) -> None:
    """Set up the infrastructure based on the run-bench.yaml configuration."""
    location = infrastructure_config.get('Location')
    if not location:
        raise ValueError("Infrastructure Location is not specified in run-bench.yaml")

    if location == 'NoBench':
        print("Not running any benchmarks!")
        sys.exit(0)
    elif location == 'LocalMinikube':
        minikube_installation_from_infrastructure_config(infrastructure_config)
    elif location == 'LMCacheGKE':
        start_gke_cluster_from_infrastructure_config(infrastructure_config)
    elif location == 'Local-Flat':
        print("Using Local-Flat infrastructure - no setup required")
    else:
        raise ValueError(f"Unsupported infrastructure location: {location}")

def minikube_installation_from_infrastructure_config(infrastructure_config: Dict[str, Any]) -> None:
    """Set up minikube using infrastructure config from run-bench.yaml."""
    script_path = Path(__file__).parent / '1-infrastructure' / 'local-minikube' / 'install-local-minikube.sh'

    if not script_path.exists():
        raise FileNotFoundError(f"Installation script not found at {script_path}")

    # Make the script executable if it isn't already
    os.chmod(script_path, 0o755)

    # Execute the installation script
    print("Setting up local minikube environment...")
    # This is blocking
    result = subprocess.run([str(script_path)], check=True)

    if result.returncode == 0:
        print("Local minikube environment setup completed successfully")
    else:
        raise RuntimeError("Failed to set up local minikube environment")

def start_gke_cluster_from_infrastructure_config(infrastructure_config: Dict[str, Any]) -> None:
    """Set up GKE cluster using infrastructure config from run-bench.yaml."""
    script_path = Path(__file__).parent / '1-infrastructure' / 'lmcache-gke' / 'run-gke.sh'
    if not script_path.exists():
        raise FileNotFoundError(f"GKE cluster setup script not found at {script_path}")

    # add execution permission
    os.chmod(script_path, 0o755)

    # Execute the script
    num_gpus = infrastructure_config.get('numClusterGPUs')
    a100_vram = infrastructure_config.get('A100_VRAM', "40")
    if not num_gpus:
        raise ValueError("numClusterGPUs must be specified in run-bench.yaml for GKE cluster setup")
    result = subprocess.run([str(script_path), str(num_gpus), str(a100_vram)], check=True)

    if result.returncode == 0:
        print("GKE cluster setup completed successfully")
    else:
        raise RuntimeError("Failed to set up GKE cluster")

# 2. Baseline Setup
def generate_baseline_key(serving_config: Dict[str, Any]) -> str:
    """Generate a baseline key based on the serving configuration."""
    baseline_type = list(serving_config.keys())[0]
    baseline_config = serving_config[baseline_type]

    if baseline_type == 'SGLang':
        script_name = baseline_config.get('scriptName', '')
        return f"sglang_{script_name.replace('.sh', '').replace('-', '_')}"
    elif baseline_type == 'RayServe':
        script_name = baseline_config.get('scriptName', '')
        accelerator_type = baseline_config.get('acceleratorType', '')
        return f"rayserve_{script_name.replace('.py', '').replace('-', '_')}_{accelerator_type.lower()}"
    elif baseline_type == 'Helm-ProductionStack':
        # helm_{config_name} based on helmConfigSelection
        helm_config = baseline_config.get('helmConfigSelection', '')
        return f"helm_{helm_config.replace('/', '_').replace('.yaml', '')}"
    elif baseline_type == 'Direct-ProductionStack':
        # Convert kubernetesConfigSelection filepath where "/" becomes "_"
        k8s_config = baseline_config.get('kubernetesConfigSelection', '')
        return k8s_config.replace('/', '_').replace('.yaml', '')
    elif baseline_type == 'LLM-D':
        # llmd_{config_name} based on configSelection
        config_selection = baseline_config.get('configSelection', '')
        return f"llmd_{config_selection.replace('/', '_').replace('.yaml', '')}"
    elif baseline_type == 'Dynamo':
        # dynamo_{config_name} based on configSelection
        config_selection = baseline_config.get('configSelection', '')
        return f"dynamo_{config_selection.replace('/', '_').replace('.yaml', '')}"
    else:
        raise ValueError(f"Unsupported baseline type: {baseline_type}")

def setup_single_baseline(serving_config: Dict[str, Any], global_config: Dict[str, Any], serving_index: int) -> None:
    """Set up a single baseline (cluster of serving engines) based on the configuration."""
    global MODEL_URL, HF_TOKEN, KEY, CURRENT_SERVING_INDEX, CURRENT_SERVING_CONFIG, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH

    # Store current serving info for later use
    CURRENT_SERVING_INDEX = serving_index
    CURRENT_SERVING_CONFIG = serving_config

    baseline_type = list(serving_config.keys())[0]
    baseline_config = serving_config[baseline_type]

    # Generate the proper KEY
    KEY = generate_baseline_key(serving_config)

    print(f"\n=== Setting up serving baseline {serving_index}: {baseline_type} (key: {KEY}) ===")

    if baseline_type == 'SGLang':
        model_url = baseline_config.get('modelURL')
        if not model_url:
            raise ValueError(f"modelURL must be specified for SGLang baseline {serving_index}")
        MODEL_URL = model_url
        # HF_TOKEN is read directly from environment variable by the script
        HF_TOKEN = os.environ.get('HF_TOKEN')
        if not HF_TOKEN:
            raise ValueError("HF_TOKEN environment variable is not set")
        sglang_installation(baseline_config)

    elif baseline_type == 'RayServe':
        model_url = baseline_config.get('modelURL')
        if not model_url:
            raise ValueError(f"modelURL must be specified for RayServe baseline {serving_index}")
        MODEL_URL = model_url
        # HF_TOKEN is read directly from environment variable by the script
        HF_TOKEN = os.environ.get('HF_TOKEN')
        if not HF_TOKEN:
            raise ValueError("HF_TOKEN environment variable is not set")
        rayserve_installation(baseline_config)

    elif baseline_type == 'Helm-ProductionStack':
        model_url = baseline_config.get('modelURL')
        hf_token = baseline_config.get('hf_token')
        if not model_url:
            raise ValueError(f"modelURL must be specified for Helm-ProductionStack baseline {serving_index}")
        if not hf_token:
            raise ValueError(f"hf_token must be specified for Helm-ProductionStack baseline {serving_index}")
        MODEL_URL = model_url
        HF_TOKEN = hf_token
        helm_installation_with_config(baseline_config, global_config)

    elif baseline_type == 'Direct-ProductionStack':
        model_url = baseline_config.get('modelURL')
        hf_token = baseline_config.get('hf_token')
        if not model_url:
            raise ValueError(f"modelURL must be specified for Direct-ProductionStack baseline {serving_index}")
        if not hf_token:
            raise ValueError(f"hf_token must be specified for Direct-ProductionStack baseline {serving_index}")
        MODEL_URL = model_url
        HF_TOKEN = hf_token
        kubernetes_application(baseline_config, global_config)

    elif baseline_type == 'LLM-D':
        model_url = baseline_config.get('modelURL')
        hf_token = baseline_config.get('hf_token')
        if not model_url:
            raise ValueError(f"modelURL must be specified for LLM-D baseline {serving_index}")
        if not hf_token:
            raise ValueError(f"hf_token must be specified for LLM-D baseline {serving_index}")
        MODEL_URL = model_url
        HF_TOKEN = hf_token
        llmd_installation(baseline_config)

    elif baseline_type == 'Dynamo':
        config_selection = baseline_config.get('configSelection')
        model_url = baseline_config.get('modelURL')
        api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility
        if not config_selection:
            raise ValueError(f"configSelection must be specified for Dynamo baseline {serving_index}")
        if not model_url:
            raise ValueError(f"modelURL must be specified for Dynamo baseline {serving_index}")
        if api_type not in ['completions', 'chat']:
            raise ValueError(f"apiType must be 'completions' or 'chat' for Dynamo baseline {serving_index}, got: {api_type}")
        MODEL_URL = model_url
        # HF_TOKEN is read directly from environment variable by the script
        HF_TOKEN = os.environ.get('HF_TOKEN')
        if not HF_TOKEN:
            raise ValueError("HF_TOKEN environment variable is not set")
        dynamo_installation(baseline_config)

    else:
        raise ValueError(f"Unsupported baseline type: {baseline_type}")

def setup_baseline(config: Dict[str, Any]) -> None:
    """Legacy function - now redirects to setup_single_baseline for backward compatibility."""
    # This function is kept for backward compatibility but should not be used in the new pipeline
    raise RuntimeError("setup_baseline() should not be called in the new multi-baseline pipeline")

def sglang_installation(sglang_config: Dict[str, Any]) -> None:
    """
    Deploy SGLang using the unified choose-and-deploy.sh entrypoint
    """
    script_name = sglang_config.get('scriptName')
    if not script_name:
        raise ValueError("scriptName must be specified for SGLang")
    
    # Script reads HF_TOKEN directly from environment variable
    if not os.environ.get('HF_TOKEN'):
        raise ValueError("HF_TOKEN environment variable is not set")

    # Use choose-and-deploy.sh as the single entrypoint (includes setup + deployment + wait)
    script_path = Path(__file__).parent / '2-serving-engines' / 'sglang' / 'choose-and-deploy.sh'
    if not script_path.exists():
        raise FileNotFoundError(f"SGLang choose-and-deploy script not found: {script_path}")
    
    os.chmod(script_path, 0o755)
    print(f"Running SGLang choose-and-deploy script with {script_name} (includes setup + deployment + wait)")
    
    # CRITICAL: Block until service ready (choose-and-deploy.sh handles this internally)
    subprocess.run([str(script_path), script_name], check=True)
    
    print("SGLang deployment completed successfully")

def rayserve_installation(rayserve_config: Dict[str, Any]) -> None:
    """
    Deploy RayServe using the unified choose-and-deploy.sh entrypoint
    """
    script_name = rayserve_config.get('scriptName')
    accelerator_type = rayserve_config.get('acceleratorType')
    if not script_name:
        raise ValueError("scriptName must be specified for RayServe")
    if not accelerator_type:
        raise ValueError("acceleratorType must be specified for RayServe")
    
    # Script reads HF_TOKEN directly from environment variable
    if not os.environ.get('HF_TOKEN'):
        raise ValueError("HF_TOKEN environment variable is not set")

    # Use choose-and-deploy.sh as the single entrypoint (includes setup + deployment + wait)
    script_path = Path(__file__).parent / '2-serving-engines' / 'rayserve' / 'choose-and-deploy.sh'
    if not script_path.exists():
        raise FileNotFoundError(f"RayServe choose-and-deploy script not found: {script_path}")
    
    os.chmod(script_path, 0o755)
    print(f"Running RayServe choose-and-deploy script with {script_name} and {accelerator_type} (includes setup + deployment + wait)")
    
    # CRITICAL: Block until service ready (choose-and-deploy.sh handles this internally)
    subprocess.run([str(script_path), script_name, accelerator_type], check=True)
    
    print("RayServe deployment completed successfully")

def llmd_installation(llmd_config: Dict[str, Any]) -> None:
    """
    Deploy LLM-D using the configured script for LocalMinikube deployment
    """
    config_selection = llmd_config.get('configSelection')
    if not config_selection:
        raise ValueError("configSelection must be specified for LLM-D")
    
    # Ensure HF_TOKEN environment variable is set for the script
    global HF_TOKEN
    if not HF_TOKEN:
        raise ValueError("HF_TOKEN is not set when trying to deploy LLM-D baseline")
    os.environ['HF_TOKEN'] = HF_TOKEN

    # Run the LLM-D choose-and-deploy script with config selection
    # NOTE: choose-and-deploy.sh already calls setup.sh internally, so no need to call setup.sh separately
    script_path = Path(__file__).parent / '2-serving-engines' / 'llm-d' / 'choose-and-deploy.sh'
    if not script_path.exists():
        raise FileNotFoundError(f"LLM-D script not found: {script_path}")
    
    os.chmod(script_path, 0o755)
    print(f"Running LLM-D script with config: {config_selection} (includes comprehensive cleanup)")
    
    # CRITICAL: Block until service ready
    print("Deploying LLM-D and waiting for service readiness...")
    subprocess.run([str(script_path), config_selection], check=True)
    
    # The choose-and-deploy.sh script already includes wait.sh, so service should be ready
    # Additional verification that the service is accessible
    import time
    time.sleep(5)  # Give the service a moment after deployment completion
    timeout = 60  # Short timeout since choose-and-deploy.sh already waited
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            import requests
            response = requests.get('http://localhost:30080/v1/models', timeout=5)
            if response.status_code == 200:
                print("LLM-D service is ready and accessible")
                return
        except:
            pass
        time.sleep(5)
    
    raise RuntimeError("LLM-D service failed to become accessible within timeout")

def dynamo_installation(dynamo_config: Dict[str, Any]) -> None:
    """
    Deploy Dynamo using the unified choose-and-deploy.sh entrypoint
    """
    config_selection = dynamo_config.get('configSelection')
    if not config_selection:
        raise ValueError("configSelection must be specified for Dynamo")
    
    # Script reads HF_TOKEN directly from environment variable
    if not os.environ.get('HF_TOKEN'):
        raise ValueError("HF_TOKEN environment variable is not set")

    # Use choose-and-deploy.sh as the single entrypoint (includes setup + deployment + wait)
    script_path = Path(__file__).parent / '2-serving-engines' / 'dynamo' / 'choose-and-deploy.sh'
    if not script_path.exists():
        raise FileNotFoundError(f"Dynamo choose-and-deploy script not found: {script_path}")
    
    os.chmod(script_path, 0o755)
    print("Running Dynamo choose-and-deploy script (includes setup + deployment + wait)")
    
    # CRITICAL: Block until service ready (choose-and-deploy.sh handles this internally)
    subprocess.run([str(script_path), config_selection], check=True)
    
    print("Dynamo deployment completed successfully")

# Note: The old complex SGLang YAML overriding function has been removed 
# as we now use simple script-based deployment for Local-Flat infrastructure

def helm_installation_with_config(prodstack_config: Dict[str, Any], global_config: Dict[str, Any]) -> None:
    """
    Deploy the router and serving engines through production stack helm installation using config file selection
    """
    # Get the helm config file name
    helm_config_filename = prodstack_config.get('helmConfigSelection')
    if not helm_config_filename:
        raise ValueError("helmConfigSelection must be specified in bench-spec.yaml for Helm-ProductionStack baseline")

    # Ensure HF_TOKEN environment variable is set for the script
    global HF_TOKEN, CURRENT_SPEC_CONFIG, LMBENCH_SESSION_ID
    if not HF_TOKEN:
        raise ValueError("HF_TOKEN is not set when trying to deploy Helm-ProductionStack baseline")
    os.environ['HF_TOKEN'] = HF_TOKEN

    # Set environment variables for log collection
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'
    os.environ['LMBENCH_BENCHMARK_NAME'] = benchmark_name
    os.environ['LMBENCH_SESSION_ID'] = LMBENCH_SESSION_ID or 'unknown'

    # Execute the choose-and-deploy script
    deploy_script_path = Path(__file__).parent / '2-serving-engines' / 'helm-production-stack' / 'choose-and-deploy.sh'
    os.chmod(deploy_script_path, 0o755)

    # Determine if we should skip node affinity based on Infrastructure.Location or command-line flag
    skip_node_affinity = (GLOBAL_ARGS and GLOBAL_ARGS.skip_node_affinity) or (global_config.get('Infrastructure', {}).get('Location') != 'LMCacheGKE')

    cmd = [str(deploy_script_path), str(helm_config_filename)]
    if skip_node_affinity:
        cmd.append("--skip-node-affinity")

    result = subprocess.run(cmd, check=True)
    if result.returncode == 0:
        print("Helm deployment completed successfully")
    else:
        raise RuntimeError("Failed to deploy Helm")

def kubernetes_application(direct_production_stack_config: Dict[str, Any], global_config: Dict[str, Any]) -> None:
    """
    Apply pre-made kubernetes configurations from direct-production-stack
    """
    # Get the kubernetes config file name
    k8s_config_filename = direct_production_stack_config.get('kubernetesConfigSelection')
    if not k8s_config_filename:
        raise ValueError("kubernetesConfigSelection must be specified in bench-spec.yaml for Direct-ProductionStack baseline")

    # Ensure HF_TOKEN environment variable is set for the script
    global HF_TOKEN, CURRENT_SPEC_CONFIG, LMBENCH_SESSION_ID
    if not HF_TOKEN:
        raise ValueError("HF_TOKEN is not set when trying to deploy Direct-ProductionStack baseline")
    os.environ['HF_TOKEN'] = HF_TOKEN

    # Set environment variables for log collection
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'
    os.environ['LMBENCH_BENCHMARK_NAME'] = benchmark_name
    os.environ['LMBENCH_SESSION_ID'] = LMBENCH_SESSION_ID or 'unknown'

    # Execute the choose-and-deploy script
    deploy_script_path = Path(__file__).parent / '2-serving-engines' / 'direct-production-stack' / 'choose-and-deploy.sh'
    os.chmod(deploy_script_path, 0o755)

    # Determine if we should skip node affinity based on Infrastructure.Location or command-line flag
    skip_node_affinity = (GLOBAL_ARGS and GLOBAL_ARGS.skip_node_affinity) or (global_config.get('Infrastructure', {}).get('Location') != 'LMCacheGKE')

    cmd = [str(deploy_script_path), str(k8s_config_filename)]
    if skip_node_affinity:
        cmd.append("--skip-node-affinity")

    result = subprocess.run(cmd, check=True)
    if result.returncode == 0:
        print("Kubernetes deployment completed successfully")
    else:
        raise RuntimeError("Failed to deploy Kubernetes")

    # The patching of deployments to the appropriate node pools is now handled directly
    # in the choose-and-deploy.sh script before waiting for pods to be ready



# 3. Run the specified workload
def run_workload(config: Dict[str, Any]) -> None:
    """Run the specified workload based on the configuration."""
    if 'Workload' not in config:
        raise ValueError("Workload configuration is missing in bench-spec.yaml")

    global MODEL_URL
    if not MODEL_URL:
        raise ValueError("MODEL_URL is not set when trying to run the workload. It should have been set up regardless of what baseline was used!")

    global HF_TOKEN
    if not HF_TOKEN:
        raise ValueError("HF_TOKEN is not set when trying to run the workload. It should have been set up regardless of what baseline was used!")

    global KEY
    if not KEY:
        raise ValueError("KEY is not set when trying to run the workload. It should have been set up regardless of what baseline was used!")

    # export HF_TOKEN
    os.environ['HF_TOKEN'] = HF_TOKEN

    workload_cfg = config['Workload']

    supported_workloads = ['ShareGPT', 'LMCacheSynthetic', 'Agentic', 'Mooncake', 'Random', 'VLLMBenchmark']
    for workload in workload_cfg:
        if workload not in supported_workloads:
            raise ValueError(f"Unsupported workload type: {workload}")

    # Multiple workloads can be run
    if 'ShareGPT' in workload_cfg:
        sharegpt_config = workload_cfg['ShareGPT']
        if isinstance(sharegpt_config, list):
            for config in sharegpt_config:
                run_sharegpt(config)
        else:
            run_sharegpt(sharegpt_config)

    if 'LMCacheSynthetic' in workload_cfg:
        lmcache_synthetic_config = workload_cfg['LMCacheSynthetic']
        if isinstance(lmcache_synthetic_config, list):
            for config in lmcache_synthetic_config:
                run_synthetic(config)
        else:
            run_synthetic(lmcache_synthetic_config)

    if 'Mooncake' in workload_cfg:
        mooncake_config = workload_cfg['Mooncake']
        if isinstance(mooncake_config, list):
            for config in mooncake_config:
                run_mooncake(config)
        else:
            run_mooncake(mooncake_config)

    if 'Agentic' in workload_cfg:
        agentic_config = workload_cfg['Agentic']
        if isinstance(agentic_config, list):
            for config in agentic_config:
                run_agentic(config)
        else:
            run_agentic(agentic_config)

    if 'Random' in workload_cfg:
        random_config = workload_cfg['Random']
        if isinstance(random_config, list):
            for config in random_config:
                run_random(config)
        else:
            run_random(random_config)

    if 'VLLMBenchmark' in workload_cfg:
        vllm_benchmark_config = workload_cfg['VLLMBenchmark']
        if isinstance(vllm_benchmark_config, list):
            for config in vllm_benchmark_config:
                run_vllm_benchmark(config)
        else:
            run_vllm_benchmark(vllm_benchmark_config)

def run_sharegpt(sharegpt_config: Dict[str, Any]) -> None:
    """Run the ShareGPT workload with the specified configuration."""
    sharegpt_data_generation(sharegpt_config)
    sharegpt_run_workload(sharegpt_config)

def sharegpt_data_generation(sharegpt_config: Dict[str, Any]) -> None:
    # Function level attribute to ensure we only generate data once
    if not hasattr(sharegpt_data_generation, 'data_generated'):
        sharegpt_data_generation.data_generated = False

    if sharegpt_data_generation.data_generated:
        print("ShareGPT data already generated, skipping...")
        return

    # Get ShareGPT specific parameters with defaults
    limit = sharegpt_config.get('LIMIT')
    min_rounds = sharegpt_config.get('MIN_ROUNDS')
    start_round = sharegpt_config.get('START_ROUND')

    # Construct the command with parameters
    data_gen_script_path = Path(__file__).parent / '3-workloads' / 'sharegpt' / 'data_generation' / 'prepare_sharegpt_data.sh'

    if not data_gen_script_path.exists():
        raise FileNotFoundError(f"ShareGPT script not found at {data_gen_script_path}")

    # Make the script executable
    os.chmod(data_gen_script_path, 0o755)

    global MODEL_URL
    cmd = [str(data_gen_script_path)]
    if limit is not None:
        cmd.extend(['-l', str(limit)])
    if min_rounds is not None:
        cmd.extend(['-m', str(min_rounds)])
    if start_round is not None:
        cmd.extend(['-s', str(start_round)])
    cmd.extend(['--model-url', str(MODEL_URL)])

    # Execute data generation script
    print(f"Generating and processing ShareGPT data with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("ShareGPT data generation completed successfully into 4-latest-results/sharegpt-data.json")
        sharegpt_data_generation.data_generated = True
    else:
        raise RuntimeError("Failed to generate ShareGPT data")

def sharegpt_run_workload(sharegpt_config: Dict[str, Any]) -> None:
    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'sharegpt' / 'workload_execution' / 'run-sharegpt.sh'

    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"ShareGPT script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID, KEY

    # Validate required globals
    if not KEY:
        raise ValueError("KEY is not set for ShareGPT workload")
    if not MODEL_URL:
        raise ValueError("MODEL_URL is not set for ShareGPT workload")

    # Read the benchmark name from the current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
    limit = sharegpt_config.get('LIMIT')
    min_rounds = sharegpt_config.get('MIN_ROUNDS')
    start_round = sharegpt_config.get('START_ROUND')
    qps_values = sharegpt_config.get('QPS')
    if not qps_values:
        raise ValueError("QPS values are required for ShareGPT workload")
    cmd.extend([str(limit)])
    cmd.extend([str(min_rounds)])
    cmd.extend([str(start_round)])
    cmd.extend([str(benchmark_name)])
    cmd.extend([str(CURRENT_SERVING_INDEX)])
    cmd.extend([str(CURRENT_SPEC_FILE_PATH)]) # Pass the spec file path
    cmd.extend([str(LMBENCH_SESSION_ID)]) # Pass the session ID
    cmd.extend([str(qps) for qps in qps_values])

    # Execute the workload
    print(f"Running ShareGPT workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("ShareGPT workloads completed successfully")
    else:
        raise RuntimeError("Failed to run ShareGPT workload")

def synthetic_sharegpt_data_generation() -> None:
    """Generate ShareGPT data for synthetic workload."""
    print("Generating ShareGPT data for synthetic workload...")
    data_gen_script_path = Path(__file__).parent / '3-workloads' / 'synthetic' / 'prepare_synthetic_sharegpt.sh'
    os.chmod(data_gen_script_path, 0o755)
    global MODEL_URL
    result = subprocess.run([str(data_gen_script_path), str(MODEL_URL)], check=True)

    if result.returncode == 0:
        print("ShareGPT data generation completed successfully into 4-latest-results/sharegpt-data.json")
    else:
        raise RuntimeError("Failed to generate ShareGPT data")

def run_synthetic(synthetic_config: Dict[str, Any]) -> None:
    """Run the synthetic workload with the specified configuration."""

    # function level attribute of share_gpt_generated so we only generate data once
    if not hasattr(run_synthetic, 'share_gpt_generated'):
        run_synthetic.share_gpt_generated = False

    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID, CURRENT_SERVING_CONFIG

    # Read the benchmark name from the current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    # Get apiType from the current serving configuration
    api_type = 'completions'  # Default value
    if CURRENT_SERVING_CONFIG:
        baseline_type = list(CURRENT_SERVING_CONFIG.keys())[0]
        baseline_config = CURRENT_SERVING_CONFIG[baseline_type]
        api_type = baseline_config.get('apiType', 'completions')  # Default to completions for backward compatibility

    qps_values = synthetic_config.get('QPS')
    NUM_USERS_WARMUP = synthetic_config.get('NUM_USERS_WARMUP')
    NUM_USERS = synthetic_config.get('NUM_USERS')
    NUM_ROUNDS = synthetic_config.get('NUM_ROUNDS')
    SYSTEM_PROMPT = synthetic_config.get('SYSTEM_PROMPT')
    CHAT_HISTORY = synthetic_config.get('CHAT_HISTORY')
    ANSWER_LEN = synthetic_config.get('ANSWER_LEN')
    USE_SHAREGPT = synthetic_config.get('USE_SHAREGPT', False)
    if USE_SHAREGPT and (not run_synthetic.share_gpt_generated):
        synthetic_sharegpt_data_generation()
        run_synthetic.share_gpt_generated = True

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'synthetic' / 'run_synthetic.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"Synthetic script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results

    """
    Updated script signature:
    MODEL=$1
    BASE_URL=$2
    KEY=$3
    NUM_USERS_WARMUP=$4
    NUM_USERS=$5
    NUM_ROUNDS=$6
    SYSTEM_PROMPT=$7
    CHAT_HISTORY=$8
    ANSWER_LEN=$9
    USE_SHAREGPT=${10}
    NAME=${11}
    SERVING_INDEX=${12}
    SPEC_FILE_PATH=${13}
    LMBENCH_SESSION_ID=${14}
    API_TYPE=${15}
    [qps_values...]
    """
    cmd.extend([str(NUM_USERS_WARMUP)])
    cmd.extend([str(NUM_USERS)])
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(SYSTEM_PROMPT)])
    cmd.extend([str(CHAT_HISTORY)])
    cmd.extend([str(ANSWER_LEN)])
    cmd.extend([str(USE_SHAREGPT)])
    cmd.extend([str(benchmark_name)])
    cmd.extend([str(CURRENT_SERVING_INDEX)])
    cmd.extend([str(CURRENT_SPEC_FILE_PATH)]) # Pass the spec file path
    cmd.extend([str(LMBENCH_SESSION_ID)]) # Pass the session ID
    cmd.extend([str(api_type)]) # Pass the API type
    cmd.extend([str(qps) for qps in qps_values])

    # Execute the workload
    print(f"Running synthetic workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Synthetic workloads completed successfully")
    else:
        raise RuntimeError("Failed to run synthetic workload")

def run_mooncake(mooncake_config: Dict[str, Any]) -> None:
    """Run the Mooncake workload with the specified configuration."""
    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID

    # Read the benchmark name from the current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    qps_values = mooncake_config.get('QPS')
    NUM_ROUNDS = mooncake_config.get('NUM_ROUNDS')
    SYSTEM_PROMPT = mooncake_config.get('SYSTEM_PROMPT')
    CHAT_HISTORY = mooncake_config.get('CHAT_HISTORY')
    ANSWER_LEN = mooncake_config.get('ANSWER_LEN')

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'mooncake' / 'run_mooncake.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"Mooncake script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(SYSTEM_PROMPT)])
    cmd.extend([str(CHAT_HISTORY)])
    cmd.extend([str(ANSWER_LEN)])
    cmd.extend([str(benchmark_name)])
    cmd.extend([str(CURRENT_SERVING_INDEX)])
    cmd.extend([str(CURRENT_SPEC_FILE_PATH)]) # Pass the spec file path
    cmd.extend([str(LMBENCH_SESSION_ID)]) # Pass the session ID

    # Execute the workload
    print(f"Running Mooncake workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Mooncake workloads completed successfully")
    else:
        raise RuntimeError("Failed to run Mooncake workload")

def run_agentic(agentic_config: Dict[str, Any]) -> None:
    """Run the Agentic workload with the specified configuration."""
    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID

    # Read the benchmark name from the current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    NEW_USER_INTERVALS = agentic_config.get('NEW_USER_INTERVALS')
    NUM_USERS_WARMUP = agentic_config.get('NUM_USERS_WARMUP')
    NUM_AGENTS = agentic_config.get('NUM_AGENTS')
    NUM_ROUNDS = agentic_config.get('NUM_ROUNDS')
    SYSTEM_PROMPT = agentic_config.get('SYSTEM_PROMPT')
    CHAT_HISTORY = agentic_config.get('CHAT_HISTORY')
    ANSWER_LEN = agentic_config.get('ANSWER_LEN')

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'agentic' / 'run_agentic.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"Agentic script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
    cmd.extend([str(NUM_USERS_WARMUP)])
    cmd.extend([str(NUM_AGENTS)])
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(SYSTEM_PROMPT)])
    cmd.extend([str(CHAT_HISTORY)])
    cmd.extend([str(ANSWER_LEN)])
    cmd.extend([str(benchmark_name)])
    cmd.extend([str(CURRENT_SERVING_INDEX)])
    cmd.extend([str(CURRENT_SPEC_FILE_PATH)]) # Pass the spec file path
    cmd.extend([str(LMBENCH_SESSION_ID)]) # Pass the session ID
    cmd.extend([str(interval) for interval in NEW_USER_INTERVALS])

    # Execute the workload
    print(f"Running Agentic workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Agentic workloads completed successfully")
    else:
        raise RuntimeError("Failed to run Agentic workload")

def run_random(random_config: Dict[str, Any]) -> None:
    """Run the Random workload with the specified configuration."""
    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID

    # Read the benchmark name from the current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    qps_values = random_config.get('QPS')
    NUM_USERS = random_config.get('NUM_USERS')
    NUM_ROUNDS = random_config.get('NUM_ROUNDS')
    PROMPT_LEN = random_config.get('PROMPT_LEN')
    ANSWER_LEN = random_config.get('ANSWER_LEN')

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'random' / 'run-random.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"Random script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results

    """
    Script signature:
    MODEL=$1
    BASE_URL=$2
    KEY=$3
    NUM_USERS=$4
    NUM_ROUNDS=$5
    PROMPT_LEN=$6
    ANSWER_LEN=$7
    NAME=$8
    SERVING_INDEX=$9
    SPEC_FILE_PATH=${10}
    LMBENCH_SESSION_ID=${11}
    [qps_values...]
    """
    cmd.extend([str(NUM_USERS)])
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(PROMPT_LEN)])
    cmd.extend([str(ANSWER_LEN)])
    cmd.extend([str(benchmark_name)])
    cmd.extend([str(CURRENT_SERVING_INDEX)])
    cmd.extend([str(CURRENT_SPEC_FILE_PATH)]) # Pass the spec file path
    cmd.extend([str(LMBENCH_SESSION_ID)]) # Pass the session ID
    cmd.extend([str(qps) for qps in qps_values])

    # Execute the workload
    print(f"Running Random workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Random workloads completed successfully")
    else:
        raise RuntimeError("Failed to run Random workload")

def run_vllm_benchmark(vllm_benchmark_config: Dict[str, Any]) -> None:
    """Run the VLLMBenchmark workload with the specified configuration."""
    global MODEL_URL, CURRENT_SERVING_INDEX, CURRENT_SPEC_CONFIG, CURRENT_SPEC_FILE_PATH, LMBENCH_SESSION_ID

    # Read the benchmark name from the current spec config
    benchmark_name = CURRENT_SPEC_CONFIG.get('Name', 'unknown') if CURRENT_SPEC_CONFIG else 'unknown'

    # Get VLLMBenchmark specific parameters
    backend = vllm_benchmark_config.get('BACKEND', 'vllm')
    dataset_name = vllm_benchmark_config.get('DATASET_NAME', 'sharegpt')
    dataset_path = vllm_benchmark_config.get('DATASET_PATH')
    num_prompts = vllm_benchmark_config.get('NUM_PROMPTS', 1000)
    request_rates = vllm_benchmark_config.get('REQUEST_RATES', [1.0])

    # Optional parameters that can be passed as additional arguments
    additional_args = []

    # Add optional parameters if specified
    if 'TEMPERATURE' in vllm_benchmark_config:
        additional_args.extend(['--temperature', str(vllm_benchmark_config['TEMPERATURE'])])
    if 'TOP_P' in vllm_benchmark_config:
        additional_args.extend(['--top-p', str(vllm_benchmark_config['TOP_P'])])
    if 'TOP_K' in vllm_benchmark_config:
        additional_args.extend(['--top-k', str(vllm_benchmark_config['TOP_K'])])
    if 'BURSTINESS' in vllm_benchmark_config:
        additional_args.extend(['--burstiness', str(vllm_benchmark_config['BURSTINESS'])])
    if 'SEED' in vllm_benchmark_config:
        additional_args.extend(['--seed', str(vllm_benchmark_config['SEED'])])
    if 'DISABLE_TQDM' in vllm_benchmark_config and vllm_benchmark_config['DISABLE_TQDM']:
        additional_args.append('--disable-tqdm')
    if 'IGNORE_EOS' in vllm_benchmark_config and vllm_benchmark_config['IGNORE_EOS']:
        additional_args.append('--ignore-eos')

    # Handle dataset-specific parameters and max tokens conversion
    if dataset_name == 'sharegpt':
        if 'SHAREGPT_OUTPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--sharegpt-output-len', str(vllm_benchmark_config['SHAREGPT_OUTPUT_LEN'])])
        elif 'MAX_TOKENS' in vllm_benchmark_config:
            # Convert MAX_TOKENS to sharegpt-specific parameter
            additional_args.extend(['--sharegpt-output-len', str(vllm_benchmark_config['MAX_TOKENS'])])
    elif dataset_name == 'random':
        if 'RANDOM_INPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--random-input-len', str(vllm_benchmark_config['RANDOM_INPUT_LEN'])])
        if 'RANDOM_OUTPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--random-output-len', str(vllm_benchmark_config['RANDOM_OUTPUT_LEN'])])
        elif 'MAX_TOKENS' in vllm_benchmark_config:
            # Convert MAX_TOKENS to random-specific parameter
            additional_args.extend(['--random-output-len', str(vllm_benchmark_config['MAX_TOKENS'])])
        if 'RANDOM_RANGE_RATIO' in vllm_benchmark_config:
            additional_args.extend(['--random-range-ratio', str(vllm_benchmark_config['RANDOM_RANGE_RATIO'])])
    elif dataset_name == 'sonnet':
        if 'SONNET_INPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--sonnet-input-len', str(vllm_benchmark_config['SONNET_INPUT_LEN'])])
        if 'SONNET_OUTPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--sonnet-output-len', str(vllm_benchmark_config['SONNET_OUTPUT_LEN'])])
        elif 'MAX_TOKENS' in vllm_benchmark_config:
            # Convert MAX_TOKENS to sonnet-specific parameter
            additional_args.extend(['--sonnet-output-len', str(vllm_benchmark_config['MAX_TOKENS'])])
        if 'SONNET_PREFIX_LEN' in vllm_benchmark_config:
            additional_args.extend(['--sonnet-prefix-len', str(vllm_benchmark_config['SONNET_PREFIX_LEN'])])
    elif dataset_name == 'hf':
        if 'HF_OUTPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--hf-output-len', str(vllm_benchmark_config['HF_OUTPUT_LEN'])])
        elif 'MAX_TOKENS' in vllm_benchmark_config:
            # Convert MAX_TOKENS to hf-specific parameter
            additional_args.extend(['--hf-output-len', str(vllm_benchmark_config['MAX_TOKENS'])])
    elif dataset_name == 'custom':
        if 'CUSTOM_OUTPUT_LEN' in vllm_benchmark_config:
            additional_args.extend(['--custom-output-len', str(vllm_benchmark_config['CUSTOM_OUTPUT_LEN'])])
        elif 'MAX_TOKENS' in vllm_benchmark_config:
            # Convert MAX_TOKENS to custom-specific parameter
            additional_args.extend(['--custom-output-len', str(vllm_benchmark_config['MAX_TOKENS'])])

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'vllm-benchmark-serving' / 'run_vllm_benchmark_serving.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"VLLMBenchmark script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    # Run benchmarks for each request rate
    for request_rate in request_rates:
        cmd = [str(workload_exec_script_path)]
        cmd.extend([str(MODEL_URL)])
        cmd.extend(["http://localhost:30080/v1"]) # the base URL when serving with production stack (fixed to include /v1)
        cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
        cmd.extend([backend])
        cmd.extend([dataset_name])
        cmd.extend([dataset_path or ""])  # Use empty string if dataset_path is None
        cmd.extend([str(num_prompts)])
        cmd.extend([str(benchmark_name)])
        cmd.extend([str(CURRENT_SERVING_INDEX)])
        cmd.extend([str(CURRENT_SPEC_FILE_PATH)]) # Pass the spec file path
        cmd.extend([str(LMBENCH_SESSION_ID)]) # Pass the session ID
        cmd.extend([str(request_rate)])
        cmd.extend(additional_args)

        # Execute the workload
        print(f"Running VLLMBenchmark workload with request rate {request_rate} and parameters: {' '.join(cmd)}")
        result = subprocess.run(cmd, check=True)

        if result.returncode == 0:
            print(f"VLLMBenchmark workload completed successfully for request rate {request_rate}")
        else:
            raise RuntimeError(f"Failed to run VLLMBenchmark workload for request rate {request_rate}")

def clean_up() -> None:
    """
    Does not need to specified in the bench-spec.yaml configuration
    """
    # run 4-latest-results/post-processing/cleanup.sh
    cleanup_script_path = Path(__file__).parent / '4-latest-results' / 'post-processing' / 'cleanup.sh'
    os.chmod(cleanup_script_path, 0o755)
    subprocess.run([str(cleanup_script_path)], check=True)

def run_suite_visualization(suite_name: str) -> None:
    """Run the suite workloads visualization script for a completed benchmark suite."""
    try:
        visualization_script_path = Path(__file__).parent / '4-latest-results' / 'post-processing' / 'suite-workloads-visualization.py'

        if not visualization_script_path.exists():
            print(f"Warning: Visualization script not found at {visualization_script_path}")
            return

        print(f"\n=== Generating workload comparisons for suite: {suite_name} ===")

        # Run the visualization script
        result = subprocess.run([
            sys.executable,
            str(visualization_script_path),
            suite_name
        ], check=True, capture_output=True, text=True)

        if result.returncode == 0:
            print(f"Successfully generated workload comparisons for suite: {suite_name}")
            if result.stdout:
                print(result.stdout)
        else:
            print(f"Warning: Visualization script failed for suite: {suite_name}")
            if result.stderr:
                print(f"Error: {result.stderr}")

    except Exception as e:
        print(f"Warning: Failed to run visualization for suite {suite_name}: {str(e)}")

import argparse

def parse_args():
    parser = argparse.ArgumentParser(description="Run benchmarking pipeline.")
    parser.add_argument("--start-from", type=int, choices=[1, 2, 3], default=1,
                        help="Start pipeline from stage 1, 2, or 3 (default: 1)")
    parser.add_argument("--model-url", type=str, help="Inject a model URL if starting from stage 3")
    parser.add_argument("--port-forward-url", type=str,
                        help="Inject a port-forward base URL if starting from stage 2 or 3")
    parser.add_argument("--hf-token", type=str, help="Inject a HF token if starting from stage 3")
    parser.add_argument("--key", type=str, help="Inject a key if starting from stage 3")
    parser.add_argument("--ignore-data-generation", action="store_true", help="Ignore data generation and use existing data in 4-latest-results/sharegpt-data.json")
    parser.add_argument("--skip-node-affinity", action="store_true", help="Skip node pool affinity assignments )")
    parser.add_argument("--auto-upload", action="store_true", help="Automatically upload benchmark results to API dashboard")
    parser.add_argument("--api-url", type=str, default="http://localhost:3001/upload", help="API endpoint URL for uploading results (default: http://localhost:3001/upload)")
    return parser.parse_args()

def run_multiple_specs(run_bench_config: Dict[str, Any], args) -> None:
    """Run multiple benchmark specs in sequence."""
    global CURRENT_SPEC_FILE_PATH

    spec_files = run_bench_config['0-bench-specs']
    infrastructure_config = run_bench_config['1-infrastructure']

    print(f"Found {len(spec_files)} spec files to run: {spec_files}")
    print(f"Infrastructure configuration: {infrastructure_config}")

    # Track if infrastructure has been set up
    infrastructure_setup = False

    for spec_index, spec_file in enumerate(spec_files):
        try:
            print(f"\n{'='*80}")
            print(f"RUNNING SPEC {spec_index + 1}/{len(spec_files)}: {spec_file}")
            print(f"{'='*80}")

            # Set the current spec file path for use in workload functions
            CURRENT_SPEC_FILE_PATH = f"0-bench-specs/{spec_file}"

            # Read and process the spec file
            config = read_and_process_spec_file(spec_file)

            # Set the current spec config for use in workload functions
            global CURRENT_SPEC_CONFIG
            CURRENT_SPEC_CONFIG = config

            # Inject infrastructure config into the spec config for compatibility with existing functions
            config['Infrastructure'] = infrastructure_config

            # 1. Set up infrastructure (only once for the first spec)
            if args.start_from <= 1 and not infrastructure_setup:
                setup_infrastructure_from_run_bench_config(infrastructure_config)
                infrastructure_setup = True

            # 2 & 3. Run cartesian product of serving baselines and workloads
            if args.start_from <= 2:
                run_cartesian_product(config)
            else:
                # If starting from stage 3, we need injected values
                if not MODEL_URL or not HF_TOKEN or not KEY:
                    raise ValueError("When starting from stage 3, --model-url, --hf-token, and --key must be provided")
                run_workload(config)

            print(f"\n=== Completed spec {spec_index + 1}: {spec_file} ===")

            # Generate workload comparisons for this completed suite
            suite_name = config.get('Name', 'unknown')
            run_suite_visualization(suite_name)

        except Exception as e:
            print(f"Error with spec {spec_file}: {str(e)}")
            # Continue with next spec
            continue

# High-Level Benchmarking Pipeline
def main() -> None:
    # Generate unique session ID for this benchmarking session
    timestamp = int(time.time())
    session_uuid = str(uuid.uuid4())[:8]  # Use first 8 characters of UUID for brevity
    global LMBENCH_SESSION_ID
    LMBENCH_SESSION_ID = f"lmbench-{timestamp}-{session_uuid}"
    print(f"LMBench Session ID: {LMBENCH_SESSION_ID}")

    args = parse_args()
    global GLOBAL_ARGS
    GLOBAL_ARGS = args
    print(f"Starting from stage {args.start_from}")

    if args.start_from < 1 or args.start_from > 3:
        raise ValueError("Invalid start-from argument. Must be 1 (infrastructure), 2 (baseline), or 3 (workload).")

    # Check if HF_TOKEN environment variable is set (unless injecting via command line)
    if not args.hf_token and not os.environ.get('HF_TOKEN'):
        print("Error: HF_TOKEN environment variable must be set!")
        print("Please set the HF_TOKEN environment variable or use --hf-token argument.")
        sys.exit(1)

    if args.model_url:
        print(f"Injecting model URL: {args.model_url}")
        global MODEL_URL
        MODEL_URL = args.model_url
    if args.hf_token:
        print(f"Injecting HF token: {args.hf_token}")
        global HF_TOKEN
        HF_TOKEN = args.hf_token
        # Also set the environment variable for scripts that need it
        os.environ['HF_TOKEN'] = args.hf_token
    if args.key:
        print(f"Injecting key: {args.key}")
        global KEY
        KEY = args.key
    if args.ignore_data_generation:
        print("Ignoring data generation!")

    # Set environment variables for auto-upload functionality
    if args.auto_upload:
        print(f"🚀 Auto-upload enabled: {args.api_url}")
        os.environ['LMBENCH_AUTO_UPLOAD'] = 'true'
        os.environ['LMBENCH_API_URL'] = args.api_url
    else:
        os.environ['LMBENCH_AUTO_UPLOAD'] = 'false'

    try:
        # Read the run-bench configuration
        run_bench_config = read_run_bench_config()

        # Run all specs in sequence
        run_multiple_specs(run_bench_config, args)

    except Exception as e:
        print(f"Benchmarking Error: {str(e)}")
        sys.exit(1)

    finally:
        clean_up()

def run_cartesian_product(config: Dict[str, Any]) -> None:
    """Run the cartesian product of serving baselines and workloads."""
    serving_configs = config['Serving']

    for serving_index, serving_config in enumerate(serving_configs):
        try:
            print(f"\n{'='*60}")
            print(f"SERVING BASELINE {serving_index + 1}/{len(serving_configs)}")
            print(f"{'='*60}")

            # 2. Set up this serving baseline
            setup_single_baseline(serving_config, config, serving_index)

            # 3. Run all workloads for this serving baseline
            run_workload(config)

            print(f"\n=== Completed serving baseline {serving_index}: {list(serving_config.keys())[0]} ===")

        except Exception as e:
            print(f"Error with serving baseline {serving_index}: {str(e)}")
            # Continue with next serving baseline
            continue

if __name__ == "__main__":
    main()
