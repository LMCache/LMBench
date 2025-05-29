Running both at once:

```yaml

Name: basic-benchmark # suggested

...

Serving:
  - Direct-ProductionStack:
      kubernetesConfigSelection: basic/llama8B_vllm.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: meta-llama/Llama-3.1-8B-Instruct
- Direct-ProductionStack:
      kubernetesConfigSelection: basic/llama8B_lmcache.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: meta-llama/Llama-3.1-8B-Instruct

...
```
