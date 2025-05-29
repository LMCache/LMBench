# The Direct Production Stack Serving Baseline will be the most important place for LMCache team to performance test new features.

# Requirements

Please render the production stack helm template as such

Go to (clone and cd) production-stack/helm

```bash
helm template vllm . -f values.yaml > YOUR_NEW_CONFIG.yaml
```

Please use the `vllm` release name.

Tips when modifying `helm/values.yaml`
- make sure the vllm api key remains commented out (or else the open ai client has to know the key)
- start uncommenting from modelSpec
- remove the line      "runtimeClassName: nvidia" (or any line containing "runtimeClassName")
- substitute lmcacheConfig.enabled: {true, false}
- comment out modelSpec: []
- best to use `v1: 1` for the serving engines
- remove line      enableChunkedPrefill: false (or any line containing "enableChunkedPrefill")
- substitute modelURL, name, and model entries (key names) with the given modelURL from bench-spec.yaml
- change "LMCacheConnector" to "LMCacheConnectorV1"
- increase the PVC size to 180Gi


IMPORTANT: each GKE a2-highgpu-1g has around 76 GB RAM total. That means you should not request more than 70 GB generally.

This works:
IMAGE=lmcache/vllm-openai:2025-05-17-v1
docker run --runtime nvidia --gpus all \
    --env "HF_TOKEN=<YOUR_HF_TOKEN>" \
    --env "LMCACHE_USE_EXPERIMENTAL=True" \
    --env "LMCACHE_CHUNK_SIZE=256" \
    --env "LMCACHE_LOCAL_CPU=True" \
    --env "LMCACHE_MAX_LOCAL_CPU_SIZE=5" \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    --network host \
    $IMAGE \
    mistralai/Mistral-7B-Instruct-v0.2 --kv-transfer-config \
    '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}'


The ENTRYPOINT is:
["vllm", "serve"]