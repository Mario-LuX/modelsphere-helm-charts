# catalog-mirror

An in-cluster copy of the [model catalog](https://github.com/modelsphere/model-catalog)
and of this helm chart repository, for clusters whose route to GitHub is slow or
unreliable. [swiss](../swiss) is then pointed at the cluster instead of GitHub Pages.

| path | content | default upstream |
|---|---|---|
| `/model-catalog/` | `index.json` and `index-v2.json`, every version and variant file they name, histories, perf reports | `https://modelsphere.github.io/model-catalog/` |
| `/helm-charts/` | `index.yaml` (archive URLs rewritten to relative names) and every chart archive | `https://modelsphere.github.io/helm-charts/` |
| `/status.json` | result of the last sync round | |

## Install

The cluster this is for may be the one that cannot read the published chart
repository, so install from a checkout of this repository:

```sh
git clone https://github.com/modelsphere/helm-charts
helm install catalog-mirror ./helm-charts/charts/catalog-mirror -n swiss-system
helm test catalog-mirror -n swiss-system
```

The pod becomes Ready once the first sync has published both indexes.
`helm test` then reads the copy through the Service the way swiss and helm do:
every catalog version file matches the digest the index pins, every chart
archive is served and matches a digest in `index.yaml`, and a missing archive
is a 404. It also fails when the **last sync round** failed (status.json), even
though the copy keeps serving: a mirror that no longer follows its upstream
should show up red. The message names the half and the upstream error; once
the upstream is reachable again the next round (within
`sync.retryIntervalSeconds`) clears it.

Then, in the swiss site profile (the `swissd-profile` ConfigMap, re-read within a
minute; the install notes print these URLs for your release):

```yaml
chartRepo: http://catalog-mirror.swiss-system.svc/helm-charts
catalogs:
  - name: default          # keep the name existing releases recorded in their plans
    url: http://catalog-mirror.swiss-system.svc/model-catalog/
    default: true
```

Plain `http://` works for both: swiss treats a chartRepo that is not `oci://` as a
classic helm repository.

## Clusters with no route to upstream

Make the copy where upstream is reachable and hand it over: a gzip'd tar holding
the two trees exactly as nginx serves them, and nothing else.

```
model-catalog/index.json         model-catalog/index-v2.json    model-catalog/models/...
helm-charts/index.yaml           helm-charts/<chart>-<version>.tgz
```

`helm-charts/index.yaml` names its archives by bare file name, as `helm repo index`
writes it. Then:

```sh
kubectl -n swiss-system create configmap catalog-mirror-snapshot --from-file=snapshot.tar.gz
helm install catalog-mirror ./helm-charts/charts/catalog-mirror -n swiss-system \
  --set sync.enabled=false --set snapshot.configMap=catalog-mirror-snapshot \
  --set snapshot.checksum=$(sha256sum snapshot.tar.gz | cut -d' ' -f1)
```

An init container (`files/snapshot.py`) checks the archive whole -- every file
its indexes name, with the digest they pin; chart archives named by bare file
name -- and refuses it before writing anything if that fails. It then unpacks it
onto the volume on every pod start, by atomic rename and indexes last, drops the
ETags sync keeps, and writes a `status.json` saying the copy is a snapshot. With `sync.enabled=false` no sync container runs and nginx is
Ready once both indexes are there; `helm test` checks the copy the same way.
A ConfigMap holds at most 1 MiB, so leave the catalog's HTML reports out: swiss
does not read them, and they are most of the catalog's size. Create it with
`kubectl create` or `kubectl apply --server-side`: a client-side apply copies
the whole archive into an annotation that holds 256 KiB. With sync off, the
volume can be an emptyDir (`--set persistence.enabled=false`).

The snapshot and sync can also go together: the pod starts serving the snapshot at
once, and the first sync round moves it forward -- both `index.json` and the
`index-v2.json` swiss reads with `schemaVersion: v2`. The ConfigMap is optional
then: without it the pod starts from what sync has put on the volume.

## How it works

One pod: **nginx** serves the volume, **sync** (`files/sync.py`, Python standard
library only) refreshes it every `sync.intervalSeconds` (300). Both images are
stock upstream images; the script and the nginx config ship in the chart.

- **Verified copies.** Version files are checked against the sha256 digest the
  catalog index pins; chart archives against the digests in `index.yaml`. A
  mismatch fails the round.
- **Never a half-updated index.** An index is replaced (atomic rename) only after
  every file it names is on disk and verified. A failed round changes nothing and
  the previous complete copy keeps serving; the next try is
  `sync.retryIntervalSeconds` (120) later.
- **Cheap when nothing changed.** The last ETag of each index is kept on the volume
  and sent as `If-None-Match`; a 304 ends that half of the round without touching
  the disk.
- **Incremental, never deletes.** Files already present with the right digest are
  not fetched again; catalog versions and chart releases are immutable.
- **Flaky upstream.** Network errors, 5xx and 429 are retried with backoff; other
  4xx are not.

The copy lives on a PVC (a few MB today), so a restarted pod serves the last copy
at once. The chart's PVC is kept on `helm uninstall` (`persistence.keep`); to reuse
an existing one, set `persistence.existingClaim`.

## Values worth knowing

| value | default | |
|---|---|---|
| `upstream.catalogUrl` / `upstream.chartsUrl` | GitHub Pages | what is mirrored; `chartsUrl` may be any classic helm repository, with absolute archive URLs (chart-releaser) or relative ones (ChartMuseum, Harbor) |
| `sync.intervalSeconds` | `300` | seconds between rounds |
| `sync.extraEnv` | `[]` | e.g. `HTTPS_PROXY` when GitHub is reachable only through a proxy |
| `image.nginx` / `image.python` | `docker.io/library/{nginx:1.27-alpine,python:3.12-alpine}` | point at a mirror if the cluster cannot pull from Docker Hub |
| `sync.enabled` | `true` | `false`: serve the snapshot only, see above |
| `snapshot.configMap` / `snapshot.key` / `snapshot.checksum` | empty / `snapshot.tar.gz` / empty | a packed copy to start from |
| `persistence.*` | 2Gi, cluster default class | `enabled: false` uses an emptyDir (full re-sync on restart) |
