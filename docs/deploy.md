# Deploying the sglang releases

Three sglang releases run in production. Until now "what is deployed" lived in
the `helm install ...` line in each values file's header comment plus whoever's
shell history; `helmfile.yaml` at the repo root is now the inventory, and this
document is how to drive it.

| what | where |
| --- | --- |
| the inventory (release, namespace, chart, values) | `helmfile.yaml` |
| the values themselves, unchanged | `charts/sglang/production/*.yaml` |
| what those inputs actually render to | `rendered/`, committed |
| wrappers | `Makefile` |

Prerequisites: `helmfile`, the `helm-diff` plugin, `jq`, `yq`.

```
brew install helmfile
helm plugin install https://github.com/databus23/helm-diff
```

**Check this first.** The helm binary here is v4, and most of the helmfile /
helm-diff ecosystem still assumes helm 3. Run `helmfile version` and
`make render` before trusting anything below. If either breaks, point helmfile
at a helm 3 binary (`helmfile --helm-binary /path/to/helm3`) rather than
working around it — every step here depends on `helmfile template` producing the
same bytes `helm template` does.

## Step 0 — adopt the three live releases (once)

`helmfile apply` is `helm upgrade --install` underneath. On a release that
already exists it takes it over; on a name or namespace that does *not* match
what is live it installs a **second** release. For this workload that means two
engines contending for the same GPUs and two ModelRoutes writing the same key
into openresty's shared ConfigMap — the collision `docs/blue-green-migration.md`
warns about, and the one the namespace split does not save you from.

Two of the three entries in `helmfile.yaml` have namespaces that were *inferred*
from conflicting sources in this repo, so this step is not a formality:

```
make verify
```

It prints what `helmfile.yaml` claims next to the live releases rendered from
the sglang chart. They must line up name-for-name and namespace-for-namespace.
Where they don't, the file is wrong — fix `helmfile.yaml`, never the cluster.
The per-release comments in that file record which source each guess came from.

Then:

```
make diff
```

**Adoption is correct when this prints nothing for all three.** Anything else:

- *A whole release shown as being created* — the name or namespace is wrong.
  Fix `helmfile.yaml`. Do not apply.
- *Small diffs on a few fields* — the live release has drifted from what is in
  git: a `--set` someone did by hand, or a values commit that was never
  deployed. Decide per field which side is right. If the cluster is right, bring
  git up to match **before** adopting; applying a stale values file is how you
  find out the hard way that `f2116d1`'s startupProbe fix was never rolled out.

Only once `make diff` is empty is `make apply` a no-op you can trust. Commit the
first render at that point:

```
make render && git add rendered/ && git commit -m "deploy: adopt the three sglang releases into helmfile"
```

## Day to day

```
make releases                   # the names you can select on
make diff                       # every release, read-only
make apply                      # diff, then sync only what changed
```

### Selecting one or several releases

Every target takes `R` (release names) or `L` (a helmfile label). `make releases`
prints the names, `helmfile list` prints the labels.

```
make diff   R=kimi-k25                            # one
make apply  R=kimi-k25,modelforge-01-glm          # two
make render L=topology=lws                        # everything multi-node
make lint   L=model=fallback-modelforge
```

`R` expands to one `-l name=...` flag per entry. That matters: helmfile ORs
repeated `-l` flags but ANDs the terms inside a single one, so
`-l name=a,name=b` means "named a *and* named b" and matches nothing. Going
through `R` gives you the "or" you meant.

One behaviour worth knowing: a full `make render` owns `rendered/` and prunes
files for releases that no longer exist, while a selective one only rewrites
what it was asked for — otherwise it would delete the renders it never
regenerated. `make check` still looks at the whole directory either way, so a
stale file for a release you did not select still fails.

Never `helm upgrade` by hand. The point of the inventory is that the cluster has
exactly one writer; a hand upgrade shows up as drift on the next `make diff`,
and by then nobody remembers what it was for.

Two diffs, and they answer different questions — you want both:

- `make diff` is **intent vs reality**. It reads the live cluster.
- the diff on `rendered/` in a PR is **intent vs intent**: what the last
  reviewed state would produce, against what this change would produce. It needs
  no cluster and it is where a chart bump's blast radius across all three
  releases becomes visible instead of having to be simulated in your head.

CI should run `make check` with no selection, which regenerates all of
`rendered/` and fails if the committed copy is stale. It gates on
`git status`, not `git diff`, so the render of a newly added release — untracked,
and the case most worth catching — fails the check instead of slipping through.

## When the chart changes

```
./hack/check-chart-version.sh    # or: make chart-version
```

Any change under `charts/*/templates`, `values.yaml` or `charts/*/charts` must
come with a `Chart.yaml` version bump. This is not bookkeeping: `sglang` sat at
`0.4.0` across at least six different renderings (`f0283da`, `736e9f0`,
`8b1d01a`, `c1eff9f`, `436f385`, …), which makes a pinned `--version` a
decoration: you cannot say which templates a given release was rendered from.
Changes under `production/` or `examples/` are deployment facts, not the chart's
contract, and deliberately do not trigger it.

Run this in CI on every branch.

## Moving off the local chart path

`helmfile.yaml` currently points at `charts/sglang` in this tree, which is what
makes adoption a provable no-op — helmfile renders exactly what
`helm install ./charts/sglang` rendered. Once the chart is packaged and pushed:

1. push `0.4.2` to harbor
2. uncomment the `repositories:` block and change the `templates.sglang` anchor
   to `chart: hardcore/sglang` plus `version: "0.4.2"` — all three releases
   merge that anchor, so it is one edit
3. drop `--skip-deps` from `HELMFILE_FLAGS` in the `Makefile`; helmfile needs a
   repo refresh to see a newly pushed version, which it does not need while the
   chart is a local path
4. `make diff` — **it must still be empty**

Step 4 is the whole point: an empty diff proves the artifact in harbor is the
same tree these values were tested against. A non-empty one means the push was
stale, and you found out before deploying rather than after.

### Why the anchor, and not a template variable

Helmfile v1 no longer renders `helmfile.yaml` as a Go template — only
`helmfile.yaml.gotmpl` is templated. A `{{ $chart }}` variable in this file is
therefore left as literal text and the YAML fails to parse:

```
failed to read helmfile.yaml: reading document at index 1.
Started seeing this since Helmfile v1? Add the .gotmpl file extension:
yaml: line 42: did not find expected node content
```

Renaming to `.gotmpl` is one fix. The anchor is the better one: it keeps the
file ordinary YAML that any tool can read, and a merge key expresses "these
three releases share one chart" more directly than a variable does.

## Values are schema-checked

`charts/sglang/values.schema.json` rejects an unrecognised values key instead of
ignoring it. Helm's default behaviour is to ignore, which means a typo in a
300-line override file is not an error — it is a setting that quietly does not
apply. The case it was written for: `failurThreshold` under `startupProbe`. The
chart forwards probe blocks with `toYaml`, the API server prunes the unknown
field rather than rejecting it, the probe falls back to Kubernetes' default
`failureThreshold: 3`, and a 40-minute cold load gets killed after 45 seconds —
with no error anywhere. That is the failure `8b1d01a` and `f2116d1` fixed,
reintroducible by one misspelling.

It runs automatically on every `helm template`, `helm lint`, `helmfile diff` and
`helmfile apply`, so `make lint`, `make diff` and `make check` all enforce it —
nothing extra to wire up.

Blocks the chart merely forwards to Kubernetes (`resources`, `affinity`,
`tolerations`, `env`, `volumes`, `securityContext`) are deliberately left open:
the API server owns those contracts, and restating them here would be a second
source of truth that goes stale. Same for `modelRoute.nginx.values`, whose key
set belongs to openresty's autoconfig, and for the vendored `cart` subchart.

Editing the schema is a change to what the chart accepts, so
`hack/check-chart-version.sh` treats it as a contract change and demands a
`Chart.yaml` bump — the same as touching a template.

## Still missing

- standard labels — nothing this chart renders carries `helm.sh/chart`, so a
  live object cannot tell you which chart version produced it. Object metadata
  only; putting it in the pod template would restart a 40-minute load on every
  bump.
