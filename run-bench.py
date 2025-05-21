#!/usr/bin/env python3

import yaml
import os
import subprocess
import time
from pathlib import Path
from typing import Dict, Any, Union, Optional
import sys

GLOBAL_ARGS = None # MIGHT be set in parse_args()

# Global variables passed between stages in the pipeline
MODEL_URL = None # MUST be set in setup_baseline()
HF_TOKEN = None # MUST be set in setup_baseline()
KEY = None # MUST be set in run_workload()

def read_bench_spec() -> Dict[str, Any]:
    """Read and parse the bench-spec.yaml file."""
    with open('bench-spec.yaml', 'r') as f:
        config = yaml.safe_load(f)

        # validate that hf_token is not <YOUR_HF_TOKEN>
        baseline = config['Serving'].get('Baseline')
        if baseline == 'SGLang':
            print("validating hf_token for SGLang baseline")
            sglang_config = config['Serving'].get('SGLang', {})
            hf_token = sglang_config.get('hf_token')
            if hf_token == '<YOUR_HF_TOKEN>':
                raise ValueError("hf_token must be specified in bench-spec.yaml for SGLang baseline")
        elif baseline == 'Helm-ProductionStack':
            print("validating hf_token for Helm-ProductionStack baseline")
            prodstack_config = config['Serving'].get('Helm-ProductionStack', {})
            hf_token = prodstack_config.get('hf_token')
            if hf_token == '<YOUR_HF_TOKEN>':
                raise ValueError("hf_token must be specified in bench-spec.yaml for Helm-ProductionStack baseline")
        elif baseline == 'Direct-ProductionStack':
            print("validating hf_token for Direct-ProductionStack baseline")
            direct_production_stack_config = config['Serving'].get('Direct-ProductionStack', {})
            model_url = direct_production_stack_config.get('modelURL')
            hf_token = direct_production_stack_config.get('hf_token')
            if not model_url:
                raise ValueError("modelURL must be specified in bench-spec.yaml for Direct-ProductionStack baseline")
            if not hf_token:
                raise ValueError("hf_token must be specified in bench-spec.yaml for Direct-ProductionStack baseline")
        elif baseline == 'Dynamo':
            print("validating hf_token for Dynamo baseline")
            pass
        elif baseline == 'KubeRay':
            print("validating hf_token for KubeRay baseline")
            kuberay_config = config['Serving'].get('KubeRay', {})
            model_url = kuberay_config.get('modelURL')
            hf_token = kuberay_config.get('hf_token')
            if not model_url:
                raise ValueError("modelURL must be specified in bench-spec.yaml for KubeRay baseline")
            if hf_token == '<YOUR_HF_TOKEN>':
                raise ValueError("hf_token must be specified in bench-spec.yaml for KubeRay baseline")
        else:
            raise ValueError(f"Unsupported baseline: {baseline}")

        print("Validated hf_token. run_bench.py now running")
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

# 2. Baseline Setup
def setup_baseline(config: Dict[str, Any]) -> None:
    """Set up the baseline (cluster of serving engines) based on the configuration."""
    if 'Serving' not in config:
        raise ValueError("Serving configuration is missing in bench-spec.yaml")

    baseline = config['Serving'].get('Baseline')
    global MODEL_URL # saved for later steps
    global HF_TOKEN # saved for later steps
    global KEY # saved for later steps
    if baseline == 'SGLang':
        KEY = 'sglang'
        single_config = config['Serving'].get('SGLang', {})
        model_url = single_config.get('modelURL')
        hf_token = single_config.get('hf_token')
        if not model_url:
            raise ValueError("modelURL must be specified in bench-spec.yaml for SGLang baseline")
        if not hf_token:
            raise ValueError("hf_token must be specified in bench-spec.yaml for SGLang baseline")
        MODEL_URL = model_url
        HF_TOKEN = hf_token

        # Set up SGLang
        sglang_installation(single_config)
    elif baseline == 'Helm-ProductionStack':
        KEY = 'stack'
        prodstack_config = config['Serving'].get('Helm-ProductionStack', {})
        model_url = prodstack_config.get('modelURL')
        hf_token = prodstack_config.get('hf_token')
        if not model_url:
            raise ValueError("modelURL must be specified in bench-spec.yaml for Helm-ProductionStack baseline")
        if not hf_token:
            raise ValueError("hf_token must be specified in bench-spec.yaml for Helm-ProductionStack baseline")
        MODEL_URL = model_url
        HF_TOKEN = hf_token

        # helm installation
        helm_installation(prodstack_config, config)
    elif baseline == 'Direct-ProductionStack':
        KEY = 'stack'
        direct_production_stack_config = config['Serving'].get('Direct-ProductionStack', {})
        model_url = direct_production_stack_config.get('modelURL')
        hf_token = direct_production_stack_config.get('hf_token')
        if not model_url:
            raise ValueError("modelURL must be specified in bench-spec.yaml for Direct-ProductionStack baseline")
        if not hf_token:
            raise ValueError("hf_token must be specified in bench-spec.yaml for Direct-ProductionStack baseline")
        MODEL_URL = model_url
        HF_TOKEN = hf_token

        kubernetes_application(direct_production_stack_config, config)
    elif baseline == 'Dynamo':
        KEY = 'dynamo'
        #TODO
        dynamo_config = config['Serving'].get('Dynamo', {})
        pass
    elif baseline == 'KubeRay':
        KEY = 'kuberay'
        kuberay_config = config['Serving'].get('KubeRay', {})
        model_url = kuberay_config.get('modelURL')
        hf_token = kuberay_config.get('hf_token')
        if not model_url:
            raise ValueError("modelURL must be specified in bench-spec.yaml for KubeRay baseline")
        if not hf_token:
            raise ValueError("hf_token must be specified in bench-spec.yaml for KubeRay baseline")
        MODEL_URL = model_url
        HF_TOKEN = hf_token

        # Set up KubeRay
        kuberay_installation(kuberay_config)
    else:
        raise ValueError(f"Unsupported baseline: {baseline}")

def sglang_installation(sglang_config: Dict[str, Any]) -> None:
    """
    Deploy SGLang using the configured parameters
    """
    base_yaml_file = Path(__file__).parent / '2-serving-engines' / 'sglang' / 'k8s-sglang-distributed-sts.yaml'

    if not base_yaml_file.exists():
        raise FileNotFoundError(f"Base YAML file not found: {base_yaml_file}")

    with open(base_yaml_file, 'r') as f:
        base_config = yaml.safe_load_all(f)
        # Convert generator to list to allow multiple iterations
        base_config_list = list(base_config)

    updated_config_list = _override_sglang_yaml(base_config_list, sglang_config)

    # dump the updated config to the latest results folder for visibility
    output_path = Path(__file__).parent / "4-latest-results" / "generated-sglang-config.yaml"
    with open(output_path, 'w') as out:
        yaml.dump_all(updated_config_list, out, default_flow_style=False)
        print(f"Generated SGLang config written to {output_path}")

    # Run the sglang installation script
    install_script = Path(__file__).parent / '2-serving-engines' / 'sglang' / 'run-sglang.sh'
    os.chmod(install_script, 0o755)
    print("Running SGLang install script...")
    subprocess.run([str(install_script)], check=True)

def _override_sglang_yaml(base_config_list: list, override: Dict[str, Any]) -> list:
    """
    Override the base SGLang YAML configuration with values from the override dict
    """
    # Make a deep copy to avoid modifying the original
    updated_config_list = []
    for doc in base_config_list:
        updated_config_list.append(doc.copy() if doc else {})

    # Find the StatefulSet document
    for doc in updated_config_list:
        if doc.get('kind') == 'StatefulSet':
            # Apply overrides to the StatefulSet
            try:
                # Handle replicas
                if 'replicaCount' in override:
                    doc['spec']['replicas'] = override['replicaCount']

                # Handle container configuration
                container = doc['spec']['template']['spec']['containers'][0]

                # Replace model URL placeholder
                for i, arg in enumerate(container['args']):
                    if arg == 'MODEL_URL_PLACEHOLDER':
                        container['args'][i] = override.get('modelURL')

                # Replace HF token
                for env in container['env']:
                    if env['name'] == 'HF_TOKEN':
                        env['value'] = override.get('hf_token')

                # Handle context length
                if 'contextLength' in override:
                    for i, arg in enumerate(container['args']):
                        if arg == '32768' and container['args'][i-1] == '--context-length':
                            container['args'][i] = str(override['contextLength'])

                # Handle tensor parallel size
                if 'tensorParallelSize' in override:
                    tensor_parallel_found = False
                    for i, arg in enumerate(container['args']):
                        if arg == '1' and container['args'][i-1] == '--tensor-parallel-size':
                            container['args'][i] = str(override['tensorParallelSize'])
                            tensor_parallel_found = True
                            break

                    # If tensor parallel args don't exist, add them
                    if not tensor_parallel_found:
                        # Find the index after context-length
                        for i, arg in enumerate(container['args']):
                            if arg == '--context-length':
                                # Add after the context length value
                                insert_idx = i + 2
                                container['args'].insert(insert_idx, '--tensor-parallel-size')
                                container['args'].insert(insert_idx + 1, str(override['tensorParallelSize']))
                                break

                # Handle resources
                if 'numGPUs' in override:
                    container['resources']['requests']['nvidia.com/gpu'] = override['numGPUs']
                    container['resources']['limits']['nvidia.com/gpu'] = override['numGPUs']

                if 'numCPUs' in override:
                    container['resources']['requests']['cpu'] = str(override['numCPUs'])
                    container['resources']['limits']['cpu'] = str(override['numCPUs'])

                if 'requestMemory' in override:
                    container['resources']['requests']['memory'] = override['requestMemory']
                    container['resources']['limits']['memory'] = override['requestMemory']

                # Handle SHM size
                for volume in doc['spec']['template']['spec']['volumes']:
                    if volume['name'] == 'shm':
                        if 'shmSize' in override:
                            volume['emptyDir']['sizeLimit'] = override['shmSize']
            except (KeyError, IndexError, TypeError) as e:
                raise ValueError(f"Error applying overrides to StatefulSet: {e}")

        # Find the PVC document
        elif doc.get('kind') == 'PersistentVolumeClaim':
            # Apply overrides to the PVC
            try:
                if 'cacheSize' in override:
                    doc['spec']['resources']['requests']['storage'] = override['cacheSize']
            except (KeyError, IndexError, TypeError) as e:
                raise ValueError(f"Error applying overrides to PVC: {e}")

    return updated_config_list

def helm_installation(prodstack_config: Dict[str, Any], global_config: Dict[str, Any]) -> None:
    """
    Deploy the router and serving engines through production stack helm installation
    """
    prodstack_base_name = 'v0-base-production-stack.yaml'
    generated_name = 'v0-generated-production-stack.yaml'
    if prodstack_config.get('vLLM-Version') == 1:
        prodstack_base_name = 'v1-base-production-stack.yaml'
        generated_name = 'v1-generated-production-stack.yaml'

    base_yaml_file = Path(__file__).parent / '2-serving-engines' / 'helm-production-stack' / prodstack_base_name

    if not base_yaml_file.exists():
        raise FileNotFoundError(f"Base YAML file not found: {base_yaml_file}")

    with open(base_yaml_file, 'r') as f:
        base_config = yaml.safe_load(f)

    updated_config = _override_yaml(base_config, prodstack_config)

    # dump the updated config to the latest results folder for visibility
    output_path = Path(__file__).parent / "4-latest-results" / generated_name
    with open(output_path, 'w') as out:
        yaml.dump(updated_config, out, default_flow_style=False)
        print(f"Generated config written to {output_path}")

    # Run the helm installation script
    install_script = Path(__file__).parent / '2-serving-engines' / 'helm-production-stack' / 'helm-install.sh'
    os.chmod(install_script, 0o755)
    print("Running Helm install script...")

    # Determine if we should skip node affinity based on Infrastructure.Location or command-line flag
    skip_node_affinity = GLOBAL_ARGS.skip_node_affinity or (global_config.get('Infrastructure', {}).get('Location') != 'LMCacheGKE')

    cmd = [str(install_script), str(output_path)]
    if skip_node_affinity:
        cmd.append("--skip-node-affinity")

    subprocess.run(cmd, check=True)

    # The patching of deployments to the appropriate node pools is now handled directly
    # in the helm-install.sh script before waiting for pods to be ready

def _override_yaml(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    try:
        model_spec = base['servingEngineSpec']['modelSpec'][0]
        vllm_config = model_spec['vllmConfig']
        lmcache_config = model_spec.get('lmcacheConfig', {})
    except (KeyError, IndexError, TypeError):
        raise ValueError("Expected structure missing in base YAML")

    # Apply only known, nested overrides
    mapping = {
        # modelSpec level
        'modelURL': lambda v: model_spec.update({'modelURL': v}),
        'replicaCount': lambda v: model_spec.update({'replicaCount': v}),
        'hf_token': lambda v: model_spec.update({'hf_token': v}),
        'numGPUs': lambda v: model_spec.update({'requestGPU': v}),
        'numCPUs': lambda v: model_spec.update({'requestCPU': v}),

        # vllmConfig level
        'maxModelLen': lambda v: vllm_config.update({'maxModelLen': v}),
        'tensorParallelSize': lambda v: vllm_config.update({'tensorParallelSize': v}),

        # lmcacheConfig level
        'useLMCache': lambda v: lmcache_config.update({'enabled': bool(v)}),
        'cpuSize': lambda v: lmcache_config.update({'cpuOffloadingBufferSize': str(v)}),
    }

    # v1 specific overrides
    if override.get('vLLM-Version') == 1:
        mapping['enablePrefixCaching'] = lambda v: vllm_config.update({'enablePrefixCaching': bool(v)})

    for key, val in override.items():
        handler = mapping.get(key)
        if handler:
            handler(val)
        else:
            print(f"[warn] Ignoring unrecognized override key: '{key}'")

    return base

def kubernetes_application(direct_production_stack_config: Dict[str, Any], global_config: Dict[str, Any]) -> None:
    """
    Apply pre-made kubernetes configurations from direct-production-stack
    """
    # Get the kubernetes config file name
    k8s_config_filename = direct_production_stack_config.get('kubernetesConfigSelection')
    if not k8s_config_filename:
        raise ValueError("kubernetesConfigSelection must be specified in bench-spec.yaml for Direct-ProductionStack baseline")

    # Execute the choose-and-deploy script
    deploy_script_path = Path(__file__).parent / '2-serving-engines' / 'direct-production-stack' / 'choose-and-deploy.sh'
    os.chmod(deploy_script_path, 0o755)

    # Determine if we should skip node affinity based on Infrastructure.Location or command-line flag
    skip_node_affinity = GLOBAL_ARGS.skip_node_affinity or (global_config.get('Infrastructure', {}).get('Location') != 'LMCacheGKE')

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

def kuberay_installation(kuberay_config: Dict[str, Any]) -> None:
    """
    Deploy KubeRay using the configured parameters
    """
    # Generate the KubeRay configuration
    generate_script = Path(__file__).parent / '2-serving-engines' / 'kuberay' / 'generate-kuberay-config.sh'

    if not generate_script.exists():
        raise FileNotFoundError(f"KubeRay config generation script not found: {generate_script}")

    # Make the script executable
    os.chmod(generate_script, 0o755)

    # Generate the KubeRay configuration
    print("Generating KubeRay configuration...")
    subprocess.run([str(generate_script)], check=True)

    # Run the KubeRay installation script
    install_script = Path(__file__).parent / '2-serving-engines' / 'kuberay' / 'run-kuberay.sh'

    if not install_script.exists():
        raise FileNotFoundError(f"KubeRay installation script not found: {install_script}")

    # Make the script executable
    os.chmod(install_script, 0o755)

    # Install KubeRay
    print("Running KubeRay installation...")
    subprocess.run([str(install_script)], check=True)

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

    supported_workloads = ['ShareGPT', 'LMCacheSynthetic', 'Agentic', 'Mooncake']
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

def run_sharegpt(sharegpt_config: Dict[str, Any]) -> None:
    """Run the ShareGPT workload with the specified configuration."""
    if not GLOBAL_ARGS.ignore_data_generation:
        sharegpt_data_generation(sharegpt_config)
    sharegpt_run_workload(sharegpt_config)

def sharegpt_data_generation(sharegpt_config: Dict[str, Any]) -> None:
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
    else:
        raise RuntimeError("Failed to generate ShareGPT data")

def sharegpt_run_workload(sharegpt_config: Dict[str, Any]) -> None:
    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'sharegpt' / 'workload_execution' / 'run-sharegpt.sh'

    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"ShareGPT script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    global MODEL_URL

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080/v1/"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
    limit = sharegpt_config.get('LIMIT')
    min_rounds = sharegpt_config.get('MIN_ROUNDS')
    start_round = sharegpt_config.get('START_ROUND')
    qps_values = sharegpt_config.get('QPS')
    cmd.extend([str(limit)])
    cmd.extend([str(min_rounds)])
    cmd.extend([str(start_round)])
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

    global MODEL_URL

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

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'synthetic' / 'run_synthetic_layerwise.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"Synthetic script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080/v1/"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results

    """
    MODEL=$1
    BASE_URL=$2
    KEY=$3

    # Configuration
    NUM_USERS_WARMUP=$4
    NUM_USERS=$5
    NUM_ROUNDS=$6
    SYSTEM_PROMPT=$7
    CHAT_HISTORY=$8
    ANSWER_LEN=$9
    USE_SHAREGPT=${10}
    """
    cmd.extend([str(NUM_USERS_WARMUP)])
    cmd.extend([str(NUM_USERS)])
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(SYSTEM_PROMPT)])
    cmd.extend([str(CHAT_HISTORY)])
    cmd.extend([str(ANSWER_LEN)])
    cmd.extend([str(USE_SHAREGPT)])
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
    qps_values = mooncake_config.get('QPS')
    NUM_ROUNDS = mooncake_config.get('NUM_ROUNDS')
    SYSTEM_PROMPT = mooncake_config.get('SYSTEM_PROMPT')
    CHAT_HISTORY = mooncake_config.get('CHAT_HISTORY')
    ANSWER_LEN = mooncake_config.get('ANSWER_LEN')

    workload_exec_script_path = Path(__file__).parent / '3-workloads' / 'mooncake' / 'run_mooncake.sh'
    if not workload_exec_script_path.exists():
        raise FileNotFoundError(f"Mooncake script not found at {workload_exec_script_path}")

    os.chmod(workload_exec_script_path, 0o755)

    global MODEL_URL

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080/v1/"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(SYSTEM_PROMPT)])
    cmd.extend([str(CHAT_HISTORY)])
    cmd.extend([str(ANSWER_LEN)])

    # Execute the workload
    print(f"Running Mooncake workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Mooncake workloads completed successfully")
    else:
        raise RuntimeError("Failed to run Mooncake workload")

def run_agentic(agentic_config: Dict[str, Any]) -> None:
    """Run the Agentic workload with the specified configuration."""
    """

    MODEL_LIST="$1"
    BASE_URL=$2
    KEY=$3

    # Configuration
    NUM_USERS_WARMUP=$4
    NUM_AGENTS=$5
    NUM_ROUNDS=$6
    SYSTEM_PROMPT=$7
    CHAT_HISTORY=$8
    ANSWER_LEN=$9
    """
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

    global MODEL_URL

    cmd = [str(workload_exec_script_path)]
    cmd.extend([str(MODEL_URL)])
    cmd.extend(["http://localhost:30080/v1/"]) # the base URL when serving with production stack
    cmd.extend([KEY]) # the key that will be embedded in the filenames of the results
    cmd.extend([str(NUM_USERS_WARMUP)])
    cmd.extend([str(NUM_AGENTS)])
    cmd.extend([str(NUM_ROUNDS)])
    cmd.extend([str(SYSTEM_PROMPT)])
    cmd.extend([str(CHAT_HISTORY)])
    cmd.extend([str(ANSWER_LEN)])
    cmd.extend([str(interval) for interval in NEW_USER_INTERVALS])

    # Execute the workload
    print(f"Running Agentic workload with parameters: {' '.join(cmd)}")
    result = subprocess.run(cmd, check=True)

    if result.returncode == 0:
        print("Agentic workloads completed successfully")
    else:
        raise RuntimeError("Failed to run Agentic workload")
def clean_up() -> None:
    """
    Does not need to specified in the bench-spec.yaml configuration
    """
    # run 4-latest-results/post-processing/cleanup.sh
    cleanup_script_path = Path(__file__).parent / '4-latest-results' / 'post-processing' / 'cleanup.sh'
    os.chmod(cleanup_script_path, 0o755)
    subprocess.run([str(cleanup_script_path)], check=True)

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
    return parser.parse_args()


# High-Level Benchmarking Pipeline
def main() -> None:
    args = parse_args()
    global GLOBAL_ARGS
    GLOBAL_ARGS = args
    print(f"Starting from stage {args.start_from}")

    if args.start_from < 1 or args.start_from > 3:
        raise ValueError("Invalid start-from argument. Must be 1 (infrastructure), 2 (baseline), or 3 (workload).")
    if args.model_url:
        print(f"Injecting model URL: {args.model_url}")
        global MODEL_URL
        MODEL_URL = args.model_url
    if args.hf_token:
        print(f"Injecting HF token: {args.hf_token}")
        global HF_TOKEN
        HF_TOKEN = args.hf_token
    if args.key:
        print(f"Injecting key: {args.key}")
        global KEY
        KEY = args.key
    if args.ignore_data_generation:
        print("Ignoring data generation!")

    try:
        # Read the configuration
        config = read_bench_spec()

        # 1. Set up infrastructure
        if args.start_from <= 1:
            setup_infrastructure(config)

        # 2. Set up baseline (cluster of serving engines)
        if args.start_from <= 2:
            setup_baseline(config)

        # 3. Run the specified workload
        run_workload(config)

    except Exception as e:
        print(f"Benchmarking Error: {str(e)}")
        sys.exit(1)

    finally:
        clean_up()

if __name__ == "__main__":
    main()
