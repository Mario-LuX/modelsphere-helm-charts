# Blue/green migration for a live model release

How to move a model that is serving traffic onto a new chart version without an
outage, by running the new release alongside the old one and shifting traffic at
the gateway.

Worked through with the `fallback-modelforge` example
(`charts/sglang/examples/sglang-values-fallback-modelforge.yaml`). Substitute your
own names throughout.

## Why not `helm upgrade`

Two reasons, and the second is the real one.

**Resource names changed.** Helm diffs manifests by name, so a renamed resource is
one object deleted and a different one created — not a rolling update. The
engine's replacement cannot even schedule until the old pod releases its GPU, so
the upgrade costs the full termination grace period plus a cold model load.

**Ownership is split.** Where the ModelRoute and CART were created outside Helm,
the chart cannot manage them: it cannot update `discovery.service` when the
Service name changes, and `helm upgrade` cannot adopt them (Helm 3 rejects
objects lacking `meta.helm.sh/release-name`). An in-place upgrade preserves that
split permanently. A new release dissolves it — green owns its ModelRoute and its
CART from the first install, and every name the CR references is one the chart
generated and keeps in sync.

Rollback is also a route flip rather than a second outage.

## Is a hard cutover safe for traffic already in flight?

Yes. Nothing is deleted at cutover — blue's openresty route key, its CART and its
Deployment all keep running until step 5 — and the HTTPRoute rewrite is a routing
decision made per request. An established SSE stream is an already-open connection
through gateway → openresty → CART → pod; changing the route does not re-evaluate
it. Only the next *new* request sees the rewrite.

So the cost of Variant A is not broken streams. It is the cold CART cache taking
100% of traffic at once, and needing green at full capacity instantly.

Two things do still need checking:

- **Your gateway must hot-swap config, not restart listeners.** Envoy-based
  controllers do a graceful config update that leaves existing streams alone;
  confirm yours does the same rather than draining connections on change.
- **Blue's LLMScaler will scale down** once its queue depth collapses, and the
  pods it removes may still be streaming. The chart's drain path covers this — the
  modelforge values give each removed pod `drainSeconds: 600` in preStop, then
  SIGTERM, with `terminationGracePeriodSeconds: 3600` as the hard cut, and
  SGLang's own post-SIGTERM drain has no timeout of its own. A stream is protected
  for roughly an hour. That is a property of those values, not of the chart
  defaults (60s), so keep them.

## Green in its own namespace

Installing green into a **new namespace** — e.g. `fallback-modelforge-01` — is
worth doing, and changes two things for the better.

**Names get simpler.** The namespace is what separates blue from green, so green
does not need a `-green` release name at all; it can carry the final name from day
one and there is no rename at the end. Only the openresty **route** still needs a
temporary distinct name, because openresty is shared and autoconfig keys its
ConfigMap per route.

**Teardown gets cleaner.** Blue's leftovers are confined to blue's namespace.

The chart handles the cross-namespace part on its own: every reference it emits is
fully qualified from `.Release.Namespace`, so `discovery.service`,
`cart.service` and `cart.outputConfigMap` all come out as
`fallback-modelforge-01/...` automatically, while `nginx.outputConfigMap`
(`llm-route/openresty-conf`) and `monitor.outputConfigMap`
(`monitoring/monitor-conf`) stay pointed at wherever those live. Autoconfig
watches cluster-wide, so a ModelRoute in the new namespace is picked up normally.

What the chart does **not** handle, and you must set up in the new namespace
first:

| | |
|---|---|
| **Image pull secret** | Neither the chart nor the CART subchart exposes `imagePullSecrets`. A fresh namespace has none, so if `harbor.4pd.io` needs auth the pods cannot pull at all. Copy the secret across and attach it to the namespace's `default` ServiceAccount, or add pull-secret support to the chart. |
| **Prometheus namespace selector** | If the Prometheus instance's `serviceMonitorNamespaceSelector` does not include the new namespace, green's ServiceMonitor is ignored. Metrics are never scraped, the LLMScaler's queries return no data, and — per its own contract — "if every metric is skipped the replica count is held where it is". Green would silently freeze at `minReplicas` and never scale. **Check this before the ramp**, or the capacity table below cannot execute. |
| **NetworkPolicy** | If policies are in force, allow openresty (`llm-route`) → green pods, and green → Prometheus. |
| **ResourceQuota / LimitRange** | A new namespace may inherit restrictive cluster defaults, or none at all. Confirm the GPU and ephemeral-storage requests fit. |

### The two spellings are not the same string

They differ by design, and nothing can make them match — a namespace name is an
RFC 1123 label and cannot contain a dot, while the route can (the chart requires
only `[a-z0-9._-]`):

| | |
|---|---|
| namespace | `fallback-modelforge-01` — no dot, RFC 1123 |
| openresty route / URL path | `fallback-modelforge-0.1` — **dot** |
| green's temporary route | `fallback-modelforge-0.1-green` |

The place this bites is the HTTPRoute. Its `value` and `replacePrefixMatch` are
**URL paths**, so both take the dotted spelling. A rewrite built from the
namespace name matches nothing, the rule never fires, and traffic keeps going to
blue — which looks exactly like "the cutover did nothing" rather than like an
error. Nothing in Kubernetes or the chart will flag it.

Only `-n` and `metadata.namespace` take the dotless spelling.

## Before you start: capacity

**This is the constraint that decides whether the plan is viable at all.**

Blue and green run concurrently, and each replica claims `model.gpus`. For the
modelforge example — `scaler.minReplicas: 24`, `model.gpus: 2` — blue alone holds
**48 GPUs**, and it cannot shrink below that on its own, because `minReplicas` is
a floor the LLMScaler will not cross (the CRD sets `minimum: 1`).

So green cannot simply be installed at full size. Traffic and capacity have to
move together:

| step | blue `minReplicas` | green `minReplicas` | traffic to green |
|---|---|---|---|
| install green | 24 | 2 | 0% |
| ramp | 20 | 6 | 20% |
| ramp | 12 | 14 | 50% |
| ramp | 2 | 24 | 100% |
| drain + uninstall | — | 24 | 100% |

Each row is a `helm upgrade` on blue changing only `scaler.minReplicas` (a CR
field — no rename, no pod churn beyond the scale-down itself) plus a weight change
on the HTTPRoute. Confirm you have headroom for the largest row before starting.

If your Gateway controller cannot do weighted rewrites (see Variant B in the
HTTPRoute example), you get a hard cutover instead, and green must be at full size
before you flip. That needs double the GPUs for real.

## Steps

### 0. Prepare the namespace

```
kubectl create namespace fallback-modelforge-01
# image pull secret, if your registry needs one -- the chart cannot do this
kubectl -n fallback-modelforge-01 create secret docker-registry harbor \
  --docker-server=harbor.4pd.io --docker-username=... --docker-password=...
kubectl -n fallback-modelforge-01 patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"harbor"}]}'
```

Then confirm Prometheus will actually watch the new namespace — see the table
above. This is the step whose omission is silent.

### 1. Install green

Its own namespace, so the release keeps the clean final name. Only the **route**
gets a temporary suffix:

```yaml
# green-values.yaml — overlay on your existing values
modelRoute:
  enabled: true
  nginx:
    route: "fallback-modelforge-0.1-green"     # temporary: autoconfig keys per route
  monitor:
    model: "fallback-modelforge-0.1-green"     # temporary: monitor keys per MODEL
cart:
  enabled: true                                 # chart-owned CART, not the external one
scaler:
  minReplicas: 2                                # ramp up later
  maxReplicas: 4
```

```
helm install fallback-modelforge-01 ./charts/sglang \
  -n fallback-modelforge-01 --create-namespace \
  -f charts/sglang/examples/sglang-values-fallback-modelforge.yaml \
  -f green-values.yaml
```

The distinct route name is load-bearing, not cosmetic: autoconfig writes one key
per route into openresty's shared ConfigMap, so blue and green coexist as separate
routes. Reusing blue's name would have two ModelRoutes fighting over one key —
and the namespace split does **not** save you here, because the collision is on
the key inside openresty's ConfigMap, not on any Kubernetes object name.

`monitor.model` must be distinct for the same reason: monitor's ConfigMap is keyed
per **model**, not per route, so leaving it equal to blue's would have the two
releases clobbering each other's row.

Note the example values still carry `fullnameOverride`. Drop it — in a dedicated
namespace there is nothing to collide with, and the release name is already the
name you want.

### 2. Verify green in isolation

Green is live on its own path and receiving nothing. Check it end to end before
any traffic moves:

```
kubectl -n fallback-modelforge-01 get pods
kubectl -n fallback-modelforge-01 get modelroute fallback-modelforge-01 -o yaml
curl -s localhost:8080/fallback-modelforge-0.1-green/v1/models    # via openresty
```

Confirm the CART came up rather than sitting in Init — it waits for autoconfig to
write its worker list, so a stuck Init means the ModelRoute is not being picked up:

```
kubectl -n fallback-modelforge-01 get cm fallback-modelforge-01-cart-config -o yaml
```

### 3. Shift traffic

Apply `charts/sglang/examples/httproute-blue-green.yaml`. Clients keep calling
`/fallback-modelforge-0.1`; the gateway rewrites to the `-green` path.

Ramp the weights and the two `minReplicas` together, per the capacity table.

Green's CART starts with an empty prefix cache, so TTFT will be worse until it
warms — which is exactly what the ramp is for. A hard cutover takes that hit all
at once.

### 4. Drain blue

The HTTPRoute only moves **new** requests. Established SSE streams keep running on
blue, and uninstalling cuts them at `terminationGracePeriodSeconds`.

Wait for a sustained zero — not merely zero new requests:

```
# per-replica in-flight on blue; wait until this holds at 0
kubectl -n <blue-namespace> exec deploy/<blue-deployment> -- \
  curl -s localhost:8050/metrics | grep sglang:num_running_reqs
```

The modelforge values set `terminationGracePeriodSeconds: 3600`, so even a
straggler has an hour — but confirm rather than assume.

### 5. Uninstall blue and its external pieces

Helm removes only what it owns. The external ModelRoute and the external CART are
separate and will survive:

```
helm uninstall <blue-release> -n <blue-namespace>
kubectl -n <blue-namespace> delete modelroute <blue-modelroute>   # external, hand-created
helm uninstall <blue-cart-release> -n <cart-ns>                   # external CART, own release
```

Then confirm blue's key is gone from openresty's ConfigMap:

```
kubectl -n llm-route get cm openresty-conf -o yaml | grep fallback-modelforge
```

### 6. Give green the real route name, drop the gateway hop

```yaml
modelRoute:
  nginx:
    route: "fallback-modelforge-0.1"      # was ...-green
  monitor:
    model: "fallback-modelforge-0.1"
```

```
helm upgrade fallback-modelforge-01 ./charts/sglang -n fallback-modelforge-01 \
  -f charts/sglang/examples/sglang-values-fallback-modelforge.yaml \
  -f green-values.yaml
```

This touches no workload — it is a CR field change, and autoconfig rewrites
openresty's config in place. **Verify the `-green` key is actually removed** rather
than left behind alongside the new one; the chart cannot do that for you.

Then delete the HTTPRoute (and the ReferenceGrant, if you added one). Clients are
back to a direct path with no rewrite.

## Rollback

Before step 5, rollback is one command — remove the HTTPRoute, and traffic goes
straight back to blue, which never stopped serving:

```
kubectl delete httproute fallback-modelforge-bluegreen -n llm-gateway
```

Restore blue's `scaler.minReplicas` if you lowered it. After step 5 there is no
rollback; blue is gone.

## Things to verify in your cluster

Neither this repo nor the chart can confirm these — check them on a scratch route
before you rely on them:

- **Per-backendRef `URLRewrite` filters** (Variant B). Optional in the Gateway API
  spec and not universally implemented. Check `status.parents[].conditions` on the
  HTTPRoute for `Accepted=True`.
- **Autoconfig removing a stale route key** when `nginx.route` changes in step 6,
  rather than leaving both keys in openresty's ConfigMap.
- **Two routes for one model** coexisting in openresty during the ramp. They are
  separate keys, so it should be fine, but the model is served twice under
  different names for the duration.

## Aftermath

Because the namespace separates blue from green, the release keeps its clean name
(`fallback-modelforge-01`) permanently — there is no `-green` suffix left behind
and nothing to rename at the end. Only the route carried a temporary suffix, and
step 6 removes it.

The next migration repeats the same shape into a fresh namespace, so release and
route names stay stable across generations.
