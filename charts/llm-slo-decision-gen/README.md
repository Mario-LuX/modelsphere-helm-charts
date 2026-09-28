# llm-slo-decision-gen

Turns SLO requirements into replica recommendations: a `decision-gen` service
plus optional `slo-api`, and the two CRDs they read.

```bash
helm install llm-slo modelsphere/llm-slo-decision-gen -n llm-scaler --create-namespace
```

Workloads use `{{ .Release.Namespace }}` (set with `helm install -n`). Service
DNS is `http://decision-gen.<namespace>.svc:80` for
`LLMScaler.customProvider.serverAddress`.

## What this chart owns

| Resource | Notes |
|---|---|
| `decision-gen` Deployment/Service/SA | Stable recommendation endpoint |
| `decision-gen-unstable` (optional) | Same image + `LOG_LEVEL=DEBUG`; off by default |
| `slo-api` (optional) | **Leave disabled** — published `v0.1` still targets the old API group |
| CRDs `LLMSLORequirement`, `JobSLORequirement` | Under `inference.modelsphere.dev`; annotated `helm.sh/resource-policy: keep` |

This chart does **not** create or patch Namespace resources. Create the target
namespace yourself (or pass `--create-namespace`).

`LLMScaler` and its operator live in the separate `llmscaleoperator` chart.

### CRD keep policy

Both CRDs under `crds/` carry `helm.sh/resource-policy: keep`. Uninstalling
the release does **not** delete the CRDs or existing CRs. That is intentional
so SLO objects survive chart churn. Do not ship a second chart that also
defines these CRDs into the same cluster.

## Unstable variant

`decisionGen.unstable` mirrors the source repo's
`config/manager/manager-unstable.yaml`: same image tag as stable, plus
`LOG_LEVEL=DEBUG`. There is no distinct unstable tag on Docker Hub
(`4pdosc/llm-scaler-decision-gen` publishes numbered releases only). Default
is `enabled: false`.

## ClusterRole naming

ClusterRole / ClusterRoleBinding names are release-scoped
(`{{Release.Name}}-decision-gen`, `{{Release.Name}}-slo-api`) so two installs
do not collide. Namespaced objects keep fixed names for DNS stability.

Upgrading from chart `<0.3.0` replaces the old bare `decision-gen` /
`slo-api` ClusterRole names via Helm; Service DNS is unchanged.

## Images

| Component | Default image |
|---|---|
| decision-gen | `4pdosc/llm-scaler-decision-gen:0.7.0` (matches `appVersion`) |
| slo-api | `4pdosc/llm-slo-api:v0.1` (incompatible with current CRDs — do not enable) |
