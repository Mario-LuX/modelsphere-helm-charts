# End-to-end test on kind

CPU-only end-to-end test of the host-level compile cache in `charts/sglang` and
`charts/vllm`. One kind node, so both replicas share the hostPath the cache
manager leases from. The engine is a mock image built from
`mock-engine/Dockerfile`: `sglang` and `vllm` on `PATH` answer every HTTP path
with 200 and write `compiled.marker` into the cache directory they were handed.

`commandOverride` is not set. Each pod runs the chart's real wrapper,
`python3 /opt/<engine>-cache/cache_manager.py -- <engine> serve ...`.

## Run

Needs docker, kind, kubectl, helm and Go.

```sh
make test-e2e-kind                 # both charts, then delete the cluster
make test-e2e-kind E2E_CHART=vllm  # one chart
make test-e2e-kind KEEP_CLUSTER=1  # keep the cluster afterwards
make test-e2e-kind E2E_VERBOSE=1   # print helm output, pods, the hostPath tree, engine env, cache-mgr lines
make cleanup-test-e2e-kind
```

`E2E_CHART` is `sglang`, `vllm`, or empty (both, vllm then sglang). The release
is uninstalled between charts. `E2E_VERBOSE` is off unless it is `1` or `true`.
CI sets it to `1`.

A failing `go test` stops the Makefile before it deletes the cluster. `KEEP_CLUSTER=1`
keeps the cluster on success as well.

## What is installed

The values files turn off everything a plain kind cluster cannot serve:

| Value | Why |
|---|---|
| `scaler.enabled=false` | needs the LLMScaler CRD |
| `sloRequirement.enabled=false` | needs the LLMSLORequirement CRD |
| `modelRoute.enabled=false` | needs the ModelRoute CRD (and `modelRoute.nginx.outputConfigMap`) |
| `serviceMonitor.enabled=false` | needs the Prometheus Operator CRDs |
| `cart.enabled=false` | would pull the cache-aware router image |
| `hangWatcher.enabled=false` | would pull the hang-watcher image; probes hit the engine |
| `model.gpus=0` | omits `nvidia.com/gpu` |
| `shm.enabled=false` | the mock does not use `/dev/shm` |

`model.localPath` is a hostPath of type `Directory`. The suite creates it on
the kind node (`/var/lib/e2e/model`, with a `config.json` for the model-check
init container) before install. The cache hostPath is `DirectoryOrCreate`.

The mock image is tagged `e2e-cache-engine:a`, `:b` and `:c` (the same image)
and loaded with `kind load docker-image`. The charts have no `image.pullPolicy`
field. Those tags are not `latest`, so the kubelet defaults to `IfNotPresent`
and uses the image already loaded into the node.

## Specs

For each chart:

1. **Start.** Two replicas, `maxSlotsPerNode=2`. Both pods Ready. Each holds a
   different `slot-N` under `<hostPath>/e2e/<templateHash>/`, with lock files
   under `.locks/<hash>/`. The engine environment and `~/.cache/<engine>`
   point at that slot. The cache-mgr `Acquired slot` line matches. vLLM's
   `VLLM_CACHE_*` control variables are absent from the engine process
   environment. The directory name equals the pod's template-hash env.
2. **Exhaustion.** Scale to 3. `acquire_slot` takes `LOCK_EX|LOCK_NB` and, with
   both slots held, exits 1. It does not wait and it does not fall back. The
   third pod's log contains `All 2 cache slots are in use` and no `slot-2`
   directory is created. Scale back to 2.
3. **Upgrade.** A second image tag changes the template hash. New pods use the
   new directory. The previous directory is still there (`historyLimit` 2).
4. **GC.** A third tag with `historyLimit` 1. The new pod's GC purges the
   abandoned template and skips the previous one, which is still leased
   because the rollout uses `maxUnavailable: 0`. Then a deleted pod's
   replacement re-leases the released slot of the same template and finds
   `compiled.marker` from the previous run, with the start count incremented.
