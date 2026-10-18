{{/*
  The name every resource this chart owns is called.

  Defaults to the release name, unadorned. One release serves one model, so the
  release name IS the name, and nothing needs a suffix to stay unique -- the two
  components that would otherwise collide, the metrics mock and the CART
  subchart, keep their own suffixed identity and are deliberately NOT routed
  through this helper.

  fullnameOverride exists for one reason: releases installed before the resource
  names were simplified, when the engine Deployment was <release>-sglang.
  Renaming a live Deployment is a delete-and-create, not a rolling update, and on
  a GPU node the replacement cannot even schedule until the old pod releases its
  GPU -- so the upgrade costs the full termination grace period plus a cold model
  load, rather than a rolling restart. Pinning

      fullnameOverride: <release>-sglang

  keeps that Deployment exactly where it is and makes the upgrade ordinary.

  It does not restore the older Service (<release>-sglang-svc) or LLMScaler
  (<release>-scaler): those carried different suffixes, and one value cannot be
  three names. Both are still recreated, which costs a new ClusterIP and an
  operator re-adopt but no pod restart -- and the route survives it, because the
  ModelRoute's top peer tier is direct pod IPs rather than the Service.

  Leave it empty on new releases.
*/}}
{{- define "sglang.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sglang.serviceId" -}}
{{- $id := .Values.serviceId | default (include "sglang.fullname" .) -}}
{{- $id -}}
{{- end -}}

{{- define "sglang.serviceName" -}}
{{- $name := include "sglang.fullname" . -}}
{{- if .Values.lws.enabled -}}
{{- $name = printf "%s-leader" $name -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Everything the shutdown does has to fit inside terminationGracePeriodSeconds.
  That timer starts when the pod is marked Terminating and covers BOTH the
  preStop hook and SGLang's own drain after SIGTERM. If the total is too big the
  kubelet kills the pod while requests are still running, so fail here rather
  than ship a config that quietly drops them.

  Note this check is a FLOOR, not a guarantee: SGLang's post-SIGTERM drain has
  no timeout of its own, so shutdownReserveSeconds only covers its fixed tail
  (5s drain re-check + up to 15s for schedulers to exit). A generation longer
  than the reserve is still cut off. Keep the real draining in drainSeconds,
  where it is bounded and can end early.

  Renders nothing -- it either fails the release or gets out of the way. Both
  the Deployment and the LeaderWorkerSet call it, because both carry the same
  preStop hook and the same grace period.
*/}}
{{- define "sglang.shutdownBudget" -}}
{{- $preStop := .Values.lifecycle.preStop -}}
{{- $budget := int .Values.lifecycle.shutdownReserveSeconds -}}
{{- if $preStop.enabled -}}
{{- $budget = add $budget (int $preStop.endpointSyncSeconds) (int $preStop.drainSeconds) -}}
{{- end -}}
{{- if gt (int $budget) (int .Values.terminationGracePeriodSeconds) -}}
{{- fail (printf "sglang: terminationGracePeriodSeconds (%d) is smaller than the shutdown budget (%d = preStop endpointSyncSeconds %d + drainSeconds %d + lifecycle.shutdownReserveSeconds %d); the pod would be SIGKILLed mid-drain" (int .Values.terminationGracePeriodSeconds) (int $budget) (int $preStop.endpointSyncSeconds) (int $preStop.drainSeconds) (int .Values.lifecycle.shutdownReserveSeconds)) -}}
{{- end -}}
{{- end -}}

{{/*
  The per-model directory under cache.hostPath, and the default for
  cache.hostPathSuffix -- so every release serving one model shares its warm
  kernels on a node, instead of each install compiling its own copy.

  model.name can be a HF repo id, so "/" and ":" fold to "--" rather than
  turning one name into nested directories.
*/}}
{{- define "sglang.cacheModelDir" -}}
{{- .Values.model.name | replace "/" "--" | replace ":" "--" -}}
{{- end -}}

{{/*
  Template hash for cache isolation. Evaluates all inputs that define compiled kernel compatibility:
  image repo & tag, model name, context length, extraArgs, and compiler-relevant environment variables.
*/}}
{{- define "sglang.cacheTemplateHash" -}}
{{- $envList := list -}}
{{- range .Values.env -}}
  {{- $envList = append $envList (printf "%s=%s" .name (.value | default "")) -}}
{{- end -}}
{{- $inputs := list
      .Values.image.repository
      .Values.image.tag
      .Values.model.name
      .Values.model.contextLength
      .Values.extraArgs
      $envList
    | toJson -}}
{{- sha256sum $inputs | trunc 10 -}}
{{- end -}}

{{/*
  Container HOME that wire_cache() resolves via expanduser("~"). Chart-visible
  only: an explicit env HOME value wins; otherwise /root, matching the chart's
  default empty securityContext (image user, uid 0 → /root on the SGLang
  images this chart targets). A non-root runAsUser without env HOME is refused
  by the collision guard in _pod.tpl — passwd home is unknowable at render time.
*/}}
{{- define "sglang.cacheHome" -}}
{{- $home := "/root" -}}
{{- range .Values.env -}}
{{- if and (eq .name "HOME") (hasKey . "value") (ne (toString .value) "") -}}
{{- $home = trimSuffix "/" (toString .value) -}}
{{- end -}}
{{- end -}}
{{- $home -}}
{{- end -}}

{{/*
  The labels every engine pod carries on top of the chart's own (app, role):
  podLabels, plus rdma-ib: "true" when rdma.enabled under lws.enabled -- the
  label rdma-injector keys off. A podLabels entry of the same name wins, so a hand-written one is
  neither duplicated (which would be invalid YAML) nor overridden.

  Renders nothing when there is nothing to add.
*/}}
{{- define "sglang.podLabels" -}}
{{- $labels := deepCopy (.Values.podLabels | default dict) -}}
{{- if and .Values.rdma.enabled (or .Values.lws.enabled .Values.pd.enabled) -}}
{{- $labels = merge $labels (dict "rdma-ib" "true") -}}
{{- end -}}
{{- with $labels }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
  Merge chart-supplied env entries with user env entries (Values.env), user-wins
  on duplicate name, emitting a deduplicated item list for the call site to
  plant under its own `env:` key.

  The Kubernetes API rejects an env list with two entries of the same name --
  "duplicate env name" from the server, and server-side apply in particular
  fails outright rather than resolve last-wins the way the kubelet's $(VAR)
  expansion does. With the chart's SGLANG_FORCE_SHUTDOWN pair or the cache
  quartet enabled, a user that duplicates one via Values.env would otherwise
  produce exactly that broken shape. This helper renders one entry per name
  so apply succeeds; the user's value wins and the pod runs with it, whatever
  it is.

  Order: chart entries stay in the order the caller built them -- the
  hang-watcher's LOG_FILE references $(POD_NS)/$(POD_NAME) declared upstream,
  so position is load-bearing wherever $(VAR) expansion is used. A user entry
  overwrites its chart twin IN PLACE so position is stable; non-colliding
  user entries append at the end. Callers therefore emit their entries in
  dependency order and treat Values.env as a pure overlay.

  `mustAppend` returns a fresh list on every call, so `$out` is never a
  mutation of the caller's `$chartEnv` -- colocate renders the same chart
  list for two engine containers and each render starts from a clean copy.

  Emits the item list only, indented by `padding` (default 2). No leading or
  trailing newline of its own: the call site owns the `env:` key and how it
  lines up with surrounding contexts. When both lists are empty the helper
  emits the empty string, which keeps an unconditional `env:` key legal
  (`env:` with a null child parses as a null value, matching what the chart
  emitted before this helper existed).
*/}}
{{- define "sglang.mergeEnv" -}}
{{- $padding := .padding | default 2 | int -}}
{{- $out := list -}}
{{- range (.chart | default list) -}}
  {{- $out = mustAppend $out . -}}
{{- end -}}
{{- range $u := .user | default list -}}
  {{- $merged := false -}}
  {{- $next := list -}}
  {{- range $e := $out -}}
    {{- if and (not $merged) (eq $e.name $u.name) -}}
      {{- $next = mustAppend $next $u -}}
      {{- $merged = true -}}
    {{- else -}}
      {{- $next = mustAppend $next $e -}}
    {{- end -}}
  {{- end -}}
  {{- if $merged -}}
    {{- $out = $next -}}
  {{- else -}}
    {{- $out = mustAppend $out $u -}}
  {{- end -}}
{{- end -}}
{{- if $out -}}
{{ toYaml $out | nindent $padding | trimSuffix "\n" }}
{{- end -}}
{{- end -}}
