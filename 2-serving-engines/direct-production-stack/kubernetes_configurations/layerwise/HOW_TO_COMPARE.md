Running both at once:

```yaml
Name: layerwise-benchmarks # suggested

...

Serving:
  - Direct-ProductionStack:
      kubernetesConfigSelection: layerwise/w_lmcache.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: meta-llama/Llama-3.1-8B-Instruct
- Direct-ProductionStack:
      kubernetesConfigSelection: layerwise/wo_lmcache.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: meta-llama/Llama-3.1-8B-Instruct

...
```
