# LMBench: Kubernetes-based Online Benchmarking.

[Dashboard: lmbench.dev](https://lmbench.dev/)

# E2E Instructions

## Step 1: Take a look at the LMBench benchmarking "suites" inside of `0-bench-specs/`

Definition: every single one of these specification files is a benchmarking **"suite."** A suite is defined as the cartesian product between a set of serving baselines (e.g. production stack w/ lmcache, production stack w/o lmcache, sglang, dynamo, llm-d etc.) and a set of workload generators (e.g. long input short output synthetic, sharegpt, agentic, vllm benchmark serving etc.). Every serving baseline will be run on every workload generator.

**USAGE**: Please take a look at `TEMPLATE-spec.yaml` for all the existing serving baselines and workload generators.

**Observability**: Every specification file contains a "suite name" at the top. These will be the top level groupings inside of [lmbench.dev](lmbench.dev).

**EXTENSIBILITY**: Feel free to create your own suites i.e. create your own specs. Again, everything you need should be in `TEMPLATE-spec.yaml`.

## Step 2: Choose which benchmarking suites you want to run in your LMBench "session"

Definition: every time you deploy LMBench, this is defined as a benchmarking **"session"**. [lmbench.dev](lmbench.dev) allows you to view the results specific to a single session.

**CONTROL FLOW**: The top level entrypoint is `run-bench.py`. The top level configuration is `run-bench.yaml`

**CONFIGURATION**: Specify which benchmarking suites you want to run inside of `run-bench.yaml`. You also need to specify what kind of infrastructure you want to run on (deployment explained right below). Please see `run-bench-TEMPLATE.yaml` for all the existing infrastructures and the exact details on how to choose suites to run.

**DEPLOYMENT**:

#### Option 1: Local (please specify `LocalMinikube` in the infrastructure in `run-bench.yaml`)

```bash
export HF_TOKEN=<YOUR_HF_TOKEN>
pip install -r requirements.txt
python run-bench.py
```

#### Option 2: LMCache GKE Runner (please specify `LMCacheGKE` along with number of GPUs and VRAM in `run-bench.yaml`)

Then create a PR, a push, or manually trigger the workflow. The artifact will be available at `https://github.com/LMCache/LMBench/actions` once completed.


## Step 3: Viewing and Contributing to the dashboard

If the results (see appendum for how to undrstand LMBench artifacts) of your LMBench "session" look good, please upload/contribute them to [lmbench.dev](lmbench.dev) (ask us for the password! this is so junk results don't pollute the dashboard).

The dashboard groups first by suites, then workloads within the suite, and then you can view graphs `by QPS` or `by Date` (time series). If you understand how LMBench uses the word "suite" (a set of serving baselines all compared on the same set of workloads) and the word "session" (a single deployment of LMBench), then the dashboard should feel intuitive!

# Appendum: Understanding LMBench Artifacts

TL;DR -- look for `.png` files if you just want a nice looking graph summarizing your suites for your session

Longer explanation of the deliverable per suite (a folder)

Example (`suite-name/` <- Name of the Benchmarking Suite is the folder name):
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
