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
| `slo-api` Deployment/Service/SA/Secret | HTTP API for editing SLO specs by route; on by default (`sloApi.enabled`) |
| CRDs `LLMSLORequirement`, `JobSLORequirement` | Under `inference.modelsphere.dev`; annotated `helm.sh/resource-policy: keep` |

This chart does **not** create or patch Namespace resources. Create the target
namespace yourself (or pass `--create-namespace`).

`LLMScaler` and its operator live in the separate `llmscaleoperator` chart.

### CRD keep policy

Both CRDs under `crds/` carry `helm.sh/resource-policy: keep`. Uninstalling
the release does **not** delete the CRDs or existing CRs. That is intentional
so SLO objects survive chart churn. Do not ship a second chart that also
defines these CRDs into the same cluster.

### Upgrading the CRDs

Helm installs `crds/` on first install only; `helm upgrade` never touches
them. When a chart release changes a CRD, apply it yourself before (or right
after) upgrading:

```bash
kubectl apply --server-side -f charts/llm-slo-decision-gen/crds/
```

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
| decision-gen | `4pdosc/llm-scaler-decision-gen:0.8.1` (matches `appVersion`) |
| slo-api | `4pdosc/llm-slo-api:0.3.0` |
