Running all 4 at once:

```yaml
Name: routing-benchmarks # suggested

...

Serving:
  - Direct-ProductionStack:
      kubernetesConfigSelection: routing/lmcache_kvaware.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: mistralai/Mistral-7B-Instruct-v0.2
  - Direct-ProductionStack:
      kubernetesConfigSelection: routing/lmcache_kvaware.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: mistralai/Mistral-7B-Instruct-v0.2
  - Direct-ProductionStack:
      kubernetesConfigSelection: routing/lmcache_kvaware.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: mistralai/Mistral-7B-Instruct-v0.2
  - Direct-ProductionStack:
      kubernetesConfigSelection: routing/lmcache_kvaware.yaml
      hf_token: <YOUR_HF_TOKEN>
      modelURL: mistralai/Mistral-7B-Instruct-v0.2

...
```
