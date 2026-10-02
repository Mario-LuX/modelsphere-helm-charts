# ModelSphere Helm Charts

Helm charts for running large language models on Kubernetes: the inference
engine itself, the cache-aware router in front of it, and the pieces that keep
both healthy.

```bash
helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm repo update
helm search repo modelsphere
```

## Charts

| Chart | What it deploys |
|---|---|
| [`sglang`](charts/sglang) | An SGLang inference deployment — single-node or multi-node (LeaderWorkerSet) — with optional CART, autoscaling, and a hang watcher |
| [`vllm`](charts/vllm) | The same, on vLLM |
| [`cart`](charts/cart) | [CART](https://github.com/modelsphere/cache_aware_router) on its own: routes each request to the replica that already holds the longest matching prompt prefix |
| [`llm-slo-decision-gen`](charts/llm-slo-decision-gen) | Turns SLO requirements into replica recommendations: a decision service plus the SLO storage API and its two CRDs |
| [`autoconfig`](charts/autoconfig) | Keeps the routing layer in step with what is actually deployed: watches backends and rewrites OpenResty peers and cache-aware-router workers |
| [`llmscaleoperator`](charts/llmscaleoperator) | The autoscaler the `sglang` and `vllm` charts hand their `LLMScaler` objects to: scales replicas on KV-cache utilization, queue depth and TPM rather than CPU |
| [`rdma-injector`](charts/rdma-injector) | A mutating webhook that injects `NCCL_IB_HCA` and the node's RDMA device list into pods labelled `rdma-ib: "true"` |

`sglang` and `vllm` pull in `cart` as a subchart, gated on `cart.enabled`.
Installing either of them gives you an engine and a router that already know
about each other.

## Quick start

```bash
helm install my-model modelsphere/sglang \
  --set model.name=my-model \
  --set model.path=/models/my-model \
  --set cart.enabled=true
```

Every chart ships a commented `values.yaml`; start there rather than from this
README, since that is the file that is kept current.

## Images

The charts default to public images on Docker Hub under
[`4pdosc`](https://hub.docker.com/u/4pdosc), alongside upstream
`lmsysorg/sglang` and `vllm/vllm-openai` for the engines. Point them at your own
registry by overriding the `image` values — a mirror is worth setting up if your
cluster has no egress.

## Custom resources

Some optional features render custom resources that the chart does not define:

- `modelRoute.enabled` needs the `ModelRoute` CRD from
  [autoconfig](https://github.com/modelsphere/autoconfig)
- `scaler.enabled` needs the `LLMScaler` CRD from the scaling operator

With the CRD absent, enabling the feature fails the install with
`no matches for kind ...`. The charts deliberately carry no copy of either
schema, because the operator that reconciles it owns it.

## Contributing

Charts live under `charts/<name>/`. Bump the chart's `version` in `Chart.yaml`
in the same change — CI publishes exactly those charts whose version moved, so a
change without a bump ships nothing.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
