# bodylog-victorialogs

Makes the router's body logs searchable. [bodylog](../bodylog) writes every request
and response as hourly JSONL on one node; this chart runs
[Vector](https://vector.dev) next to it to ship each record into
[VictoriaLogs](https://docs.victoriametrics.com/victorialogs/), and registers
VictoriaLogs as a Grafana datasource so the records can be queried with LogsQL.

```
bodylog pod ──writes──> <dir>/YYYY-MM-DD/HH.jsonl  (hostPath or PVC, one node)
                               │ read-only
                        Vector (same node) ──HTTP jsonline──> VictoriaLogs <── Grafana
```

| component | what | image |
|---|---|---|
| Vector | Deployment, 1 replica, scheduled onto the bodylog pod's node | `timberio/vector` |
| VictoriaLogs | subchart [`victoria-logs-single`](https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-logs-single), aliased `victorialogs` | `victoriametrics/victoria-logs` |
| Grafana datasource | ConfigMap for Grafana's datasource sidecar | |

## Install

Point the chart at the directory bodylog writes to -- the bodylog chart's
`persistence.hostPath`, or its PVC:

```sh
helm install bodylog-victorialogs modelsphere/bodylog-victorialogs -n logging --create-namespace \
  --set bodylog.hostPath=/data/bodylog \
  --set bodylog.namespace=router
helm test bodylog-victorialogs -n logging
```

- `bodylog.namespace` / `bodylog.podLabels` select the bodylog pod Vector follows
  (default: label `app.kubernetes.io/name: bodylog` in the release namespace). With
  several bodylog releases in one namespace, add `app.kubernetes.io/instance`.
- `bodylog.existingClaim` instead of `hostPath` mounts bodylog's PVC read-only. A
  ReadWriteOnce claim works, because both pods run on the same node.
- To ship into a VictoriaLogs you already run: `victorialogs.enabled=false` and
  `victorialogsUrl=http://...:9428`.
- Vector claims 10Gi of the default StorageClass for its read positions and its
  disk buffer -- see *Restarts and node moves* below for why that is not an
  `emptyDir` or a node directory. A cluster with no dynamic provisioner can use
  `vector.state.existingClaim`, or `vector.state.hostPath` with the
  caveat spelled out there.

VictoriaLogs answers at `http://victorialogs.<namespace>.svc:9428` -- a fixed
Service name (`victorialogs.server.fullnameOverride`), so another workload can be
configured with it. Two releases of this chart in one namespace need different
names there.

`helm test` checks that VictoriaLogs answers at the URL Vector and Grafana are
configured with, and that its query API works. It waits up to
`test.readyTimeoutSeconds` for VictoriaLogs, because an installer that does not
wait for pods gets there first. On a router with steady traffic, set
`test.expectRecordsWithin=1h` to also require that records arrived recently.

## How it works

- **Placement.** A Deployment with a required `podAffinity` on the bodylog pod, not a
  DaemonSet: the DaemonSet controller ignores pod affinity and would leave a Pending
  pod on every other node. If bodylog is not running, Vector stays Pending too.
- **Where reading starts.** `vector.readFrom: end` (default) ships records written
  after Vector first starts. `beginning` also ships the current day's files -- on a
  busy router that is hundreds of GB at once. Files bodylog creates later, at each
  hour's rotation, are always read from the beginning whatever this is set to.
- **Restarts and node moves.** Read positions live on a claim of their own
  (`vector.state`, 10Gi from the cluster's default StorageClass), so they
  follow the pod. That matters more than it sounds: `podAffinity` moves Vector
  whenever the bodylog pod moves, and on a node with no read positions
  `readFrom: end` seeks to the end of the file bodylog is writing -- everything
  already in today's file is then never shipped, silently. The update strategy is
  `Recreate`, and `ReadWriteOnce` makes a second reader on the same positions
  impossible anyway.
- **When VictoriaLogs is down.** The sink retries without limit, and
  acknowledgements hold the read position until a record is durable, so an outage
  pauses reading rather than advancing past records that never arrived. With the
  default disk buffer (`vector.buffer`, 8GiB) "durable" means written to that
  buffer, which sits on the same claim as the read positions. Two things follow:
  records already buffered survive Vector restarting in the middle of an outage,
  and Vector's memory stays bounded by the buffer instead of by how long the
  outage lasts. A memory buffer loses what it holds when the pod restarts, and by
  then bodylog may have archived and deleted the file those records came from --
  at which point they are gone. How much of an outage the buffer absorbs is
  `maxSize` over the record rate (~4 hours at 2GB/hour); past that, `whenFull`
  decides: `block` stops reading, `drop_newest` keeps reading and loses the
  overflow.
- **Each record** is transformed by [`files/bodylog.vrl`](files/bodylog.vrl)
  (override with `vector.vrl`): all fields are kept; `model`, `prompt_tokens`,
  `completion_tokens` and `total_tokens` are lifted out of the response; `_msg` gets
  a one-line summary
  (`<model>:<peer> --> <upstream> prompt:N cache:N output:N TTFT:Ns status:N`);
  inline base64 images are cut to 10 characters and request bodies over 1.5MB are
  truncated, because VictoriaLogs rejects entries over 2MiB.
- **Time and streams.** Entries are timestamped from the record's `ts` (when the
  request happened, `vector.timeField`). `method`, `status` and `model` are the
  stream fields (`vector.streamFields`); keep that list low-cardinality.

## Sizing

Records carry whole request and response bodies. Measured on a production router:
~10GB/hour of raw records compressed to ~12GB/day in VictoriaLogs, so the default
14-day retention needed ~170GB. Size `victorialogs.server.persistentVolume.size`
from a day of your own traffic. Retention is by age (`retentionPeriod`; a bare number
is months); `victorialogs.server.retentionDiskSpaceUsage` adds a size cap.

## Record size

Two limits apply, at different layers and to different things, and only one of
them can be configured:

| | `insert.maxLineSizeBytes` | the 2MB limit |
|---|---|---|
| layer | HTTP ingestion, per read buffer | storage, per entry |
| measures | the raw input line | the parsed entry's estimated JSON length |
| default | 256KB | hardcoded `2*1024*1024` |
| over it | skips to the next line, counts `vl_too_long_lines_skipped_total` | ignores the entry, logs once per 5s, **no metric** |

The 256KB default would skip most long-prompt requests, so this chart raises
`maxLineSizeBytes` -- but to just under 2MB, not above it. Setting it higher does
not let a bigger record in (the 2MB limit is a compile-time constant: records are
stored in blocks of up to 2MB, sized to fit a CPU's L2 cache); it only moves an
oversize record's death to the layer with no metric.

So the request-body truncation in the VRL is what actually keeps records
ingestible. Measured on a production router: records average ~370KB, 3.2% exceed
2MB raw, and capping `req_body` at 1.5MB brings all of those to ~1.50MB. That
leaves about 0.5MB of headroom for everything else in the record, `resp_body`
included -- a record whose weight is in the response rather than the request can
still be over, and nothing reports it.

## Grafana

The datasource ConfigMap (`grafana.datasource.*`) is created in `monitoring`
with label `grafana_datasource: "1"`, which kube-prometheus-stack's Grafana sidecar
loads. Grafana also needs the
[`victoriametrics-logs-datasource`](https://grafana.com/grafana/plugins/victoriametrics-logs-datasource/)
plugin, which this chart cannot install (Grafana belongs to another release). In the
kube-prometheus-stack values:

```yaml
grafana:
  plugins:
    - victoriametrics-logs-datasource
```

When the Grafana pod has no route to grafana.com, install the plugin from an init
container that gets a proxy, and keep the proxy away from Grafana itself (its
in-cluster datasources would go through it):

```yaml
grafana:
  extraInitContainers:
    - name: install-victorialogs-plugin
      image: docker.io/grafana/grafana:13.1.1          # the same image Grafana runs
      env:
        - { name: HTTPS_PROXY, value: "http://proxy.example:3128" }
      command: ["sh", "-c"]
      args:
        - grafana cli --pluginsDir /var/lib/grafana/plugins plugins install victoriametrics-logs-datasource 0.32.0
          || echo "plugin install failed; starting Grafana without it"
      volumeMounts:
        - { name: storage, mountPath: /var/lib/grafana }
```

A repeated install is a no-op, and a failed download does not keep Grafana from
starting. The plugins directory must be persistent (`grafana.persistence.enabled`)
for the init container's install to be the one Grafana loads.

Example queries (Explore, VictoriaLogs datasource):

```
status:500
model:"kimi-k2.6" AND first_chunk_t:>2
prompt_tokens:>3000 AND resp_meta.usage.prompt_tokens_details.cached_tokens:<500
request_id:"41dc9914feb71bca5453c751187e5584"
NOT resp_meta.finish_reason:"stop"
```

## Values

| key | default | |
|---|---|---|
| `bodylog.hostPath` / `bodylog.existingClaim` | `""` | where bodylog writes; exactly one is required |
| `bodylog.namespace` | release namespace | namespace of the bodylog pod |
| `bodylog.podLabels` | `app.kubernetes.io/name: bodylog` | labels of the bodylog pod |
| `victorialogs.enabled` | `true` | deploy VictoriaLogs; `false` needs `victorialogsUrl` |
| `victorialogs.server.fullnameOverride` | `victorialogs` | the Service name, and so the address |
| `victorialogs.server.retentionPeriod` | `14d` | |
| `victorialogs.server.persistentVolume.size` | `100Gi` | see Sizing |
| `vector.readFrom` | `end` | `beginning` ships the current day's files too |
| `vector.timeField` | `ts` | empty stamps entries with ship time |
| `vector.streamFields` | `[method, status, model]` | |
| `vector.vrl` | `""` | replaces `files/bodylog.vrl` |
| `vector.state.size` | `10Gi` | read positions + the disk buffer; must exceed `vector.buffer.maxSize` |
| `vector.state.storageClass` | `""` | the cluster's default class |
| `vector.state.existingClaim` / `.hostPath` | `""` | bring your own claim, or fall back to a node directory |
| `vector.buffer.type` | `disk` | `memory` stops reading during an outage and holds bodylog's disk |
| `vector.buffer.maxSize` | `8GiB` | how much of an outage Vector absorbs |
| `vector.buffer.whenFull` | `block` | `drop_newest` to keep reading and lose the overflow |
| `grafana.datasource.enabled` | `true` | |
| `grafana.datasource.namespace` | `monitoring` | Grafana's namespace |
| `test.image.repository` / `.tag` | `docker.io/curlimages/curl` / `8.11.1` | the `helm test` hook image |
| `test.readyTimeoutSeconds` | `180` | how long `helm test` waits for VictoriaLogs |
| `test.expectRecordsWithin` | `""` | e.g. `1h` |
