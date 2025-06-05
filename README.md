# LMBench: Kubernetes-based Online Inference Benchmarking.

[Dashboard: lmbench.dev](https://lmbench.dev/)

# E2E: From `run-bench.yaml` to Artifacts

Specify which benchmarking suites you want to run inside of `run-bench.yaml`.

## 1. Local

```bash
export HF_TOKEN=<YOUR_HF_TOKEN>
pip install -r requirements.txt
python run-bench.py
```

## 2. LMCache Runner

Create a PR, a push, or manually trigger the workflow.

## Results:

Every benchmark suite is defined (and **NAMED**) by a spec file (e.g. `layerwise-spec.yaml` or `routing-spec.yaml`) inside of `0-bench-specs/`. A Benchmarking Suite is defined as the Cartesian Product of a set of Serving Baselines and a set of Workloads. The artifacts for the running of a single benchmark suite show up in `suite-name/` as a collection of stats and visualization artifacts.

Example (`suite-name/` <- Name of the Benchmarking Suite):
```text:
suite-name/{KEY1}_{WORKLOAD1}_{QPS1}_{TIME1}.json
suite-name/{KEY1}_{WORKLOAD1}_{QPS2}_{TIME2}.json
suite-name/{KEY1}_{WORKLOAD2}_{QPS1}_{TIME3}.json
suite-name/{KEY1}_{WORKLOAD2}_{QPS2}_{TIME4}.json
suite-name/{KEY2}_{WORKLOAD1}_{QPS1}_{TIME5}.json
suite-name/{KEY2}_{WORKLOAD1}_{QPS2}_{TIME6}.json
suite-name/{KEY2}_{WORKLOAD2}_{QPS1}_{TIME7}.json
suite-name/{KEY2}_{WORKLOAD2}_{QPS2}_{TIME8}.json
suite-name/{WORKLOAD1}_comparison.json
suite-name/{WORKLOAD1}_comparison.png
suite-name/{WORKLOAD2}_comparison.json
suite-name/{WORKLOAD2}_comparison.png
```

Examples:
```text
example/layerwise_w_synthetic_0.7_20250529-0758.json
example/layerwise_w_synthetic_0.9_20250529-0826.json
example/layerwise_wo_synthetic_0.7_20250529-0910.json
example/layerwise_wo_synthetic_0.9_20250529-1053.json
example/synthetic_comparison.json
example/synthetic_comparison.png

daily/routing_lmcache_roundrobin_agentic_0.2_20250529-1124.json
daily/routing_lmcache_session_agentic_0.2_20250529-1148.json
daily/routing_lmcache_sessionaware_agentic_0.2_20250529-1319.json
daily/routing_lmcache_kvaware_agentic_0.2_20250529-1523.json
daily/agentic_comparison.json
daily/agentic_comparison.png
```
