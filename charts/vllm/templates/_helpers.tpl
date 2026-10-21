{{/*
  The name every resource this chart owns is called.

  Defaults to the release name, unadorned. One release serves one model, so the
  release name IS the name, and nothing needs a suffix to stay unique -- the two
  components that would otherwise collide, the metrics mock and the CART
  subchart, keep their own suffixed identity and are deliberately NOT routed
  through this helper.

  fullnameOverride exists for one reason: releases installed before the resource
  names were simplified, when the engine Deployment was <release>-vllm.
  Renaming a live Deployment is a delete-and-create, not a rolling update, and on
  a GPU node the replacement cannot even schedule until the old pod releases its
  GPU -- so the upgrade costs the full termination grace period plus a cold model
  load, rather than a rolling restart. Pinning

      fullnameOverride: <release>-vllm

  keeps that Deployment exactly where it is and makes the upgrade ordinary.

  It does not restore the older Service (<release>-vllm-svc) or LLMScaler
  (<release>-scaler): those carried different suffixes, and one value cannot be
  three names. Both are still recreated, which costs a new ClusterIP and an
  operator re-adopt but no pod restart -- and the route survives it, because the
  ModelRoute's top peer tier is direct pod IPs rather than the Service.

  Leave it empty on new releases.
*/}}
{{- define "vllm.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  The id this service is known by OUTSIDE the cluster's object graph: what the
  decision server, the SLO operator and the route all index it under. Not a
  Kubernetes name and never looked up from an object, which is why it gets its
  own value rather than reusing vllm.fullname directly -- but fullname is the
  sensible default, so an unset serviceId costs nothing.
*/}}
{{- define "vllm.serviceId" -}}
{{- .Values.serviceId | default (include "vllm.fullname" .) -}}
{{- end -}}

{{/*
  The engine's own Service. Under lws.enabled it is <fullname>-leader, because
  the LWS controller already owns a headless Service named <fullname> (the
  group's DNS domain) and two Services cannot share a name.
*/}}
{{- define "vllm.serviceName" -}}
{{- $name := include "vllm.fullname" . -}}
{{- if .Values.lws.enabled -}}
{{- $name = printf "%s-leader" $name -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Everything the shutdown does has to fit inside terminationGracePeriodSeconds.
  That timer starts when the pod is marked Terminating and covers BOTH the
  preStop hook and vLLM finishing up after SIGTERM. If the total is too big the
  kubelet kills the pod while requests are still running, so fail here rather
  than ship a config that quietly drops them.

  lifecycle.shutdownReserveSeconds is headroom after SIGTERM for vLLM's own exit
  (and, under preStopKill, how long the hook waits after its own SIGTERM on top
  of shutdownTimeout before killing PID 1's children).

  Renders nothing -- it either fails the release or gets out of the way. Both
  the Deployment and the LeaderWorkerSet call it, because both carry the same
  preStop hook and the same grace period.
*/}}
{{- define "vllm.shutdownBudget" -}}
{{- $preStop := .Values.lifecycle.preStop -}}
{{- $budget := add (int .Values.lifecycle.shutdownTimeout) (int .Values.lifecycle.shutdownReserveSeconds) -}}
{{- if $preStop.enabled -}}
{{- $budget = add $budget (int $preStop.endpointSyncSeconds) (int $preStop.drainSeconds) -}}
{{- end -}}
{{- if gt (int $budget) (int .Values.terminationGracePeriodSeconds) -}}
{{- fail (printf "vllm: terminationGracePeriodSeconds (%d) is smaller than the shutdown budget (%d = preStop endpointSyncSeconds %d + drainSeconds %d + lifecycle.shutdownTimeout %d + lifecycle.shutdownReserveSeconds %d); the pod would be SIGKILLed mid-drain" (int .Values.terminationGracePeriodSeconds) (int $budget) (int $preStop.endpointSyncSeconds) (int $preStop.drainSeconds) (int .Values.lifecycle.shutdownTimeout) (int .Values.lifecycle.shutdownReserveSeconds)) -}}
{{- end -}}
{{- end -}}

{{/*
  The labels every engine pod carries on top of the chart's own (app, role):
  podLabels, plus rdma-ib: "true" when rdma.enabled under lws.enabled OR under
  pd's DisaggregatedSet shape -- the label rdma-injector keys off. A podLabels
  entry of the same name wins, so a hand-written one is neither duplicated
  (which would be invalid YAML) nor overridden.

  Colocate pd pods talk NIXL over cuda_ipc inside one netns and never touch
  IB, so they get no rdma-ib label here even when rdma.enabled is set.

  Renders nothing when there is nothing to add.
*/}}
{{- define "vllm.podLabels" -}}
{{- $labels := deepCopy (.Values.podLabels | default dict) -}}
{{- $needsRdma := or .Values.lws.enabled (and .Values.pd.enabled (not .Values.pd.colocate)) -}}
{{- if and .Values.rdma.enabled $needsRdma -}}
{{- $labels = merge $labels (dict "rdma-ib" "true") -}}
{{- end -}}
{{- with $labels }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
  Render one env `value` as the string the Kubernetes API requires. EnvVar.value
  is a string, and server-side apply refuses anything else ("expected string,
  got int") -- but a values file that says `value: 1`, `value: 0` or
  `value: true` hands the chart a number or a bool, and toYaml would emit it
  bare.

  Helm reads values files through JSON, so every YAML number arrives here as a
  float64, and printing one with %v turns 1000000000 into "1e+09". A whole
  number is therefore printed with no exponent and no fraction; anything else
  goes through toJson, which keeps a plain decimal (0.5 -> "0.5"). Integers
  from --set, bools and strings print as themselves; null is "". A map or list
  is not an env value and is refused rather than stringified.
*/}}
{{- define "vllm.envValueString" -}}
{{- $v := . -}}
{{- if kindIs "string" $v -}}
{{- $v -}}
{{- else if kindIs "invalid" $v -}}
{{- else if kindIs "bool" $v -}}
{{- ternary "true" "false" $v -}}
{{- else if or (kindIs "float64" $v) (kindIs "float32" $v) -}}
{{- $f := float64 $v -}}
{{- if eq $f 0.0 -}}
{{- "0" -}}
{{- else if eq $f (floor $f) -}}
{{- printf "%.0f" $f -}}
{{- else -}}
{{- toJson $f -}}
{{- end -}}
{{- else if regexMatch "^u?int" (kindOf $v) -}}
{{- printf "%d" $v -}}
{{- else -}}
{{- fail (printf "vllm: an env value must be a string, number or bool, got %s %s" (kindOf $v) (toJson $v)) -}}
{{- end -}}
{{- end -}}

{{/*
  Merge chart-supplied env entries with user env entries (Values.env), user-wins
  on duplicate name, emitting a deduplicated item list for the call site to
  plant under its own `env:` key.

  The Kubernetes API rejects an env list with two entries of the same name --
  "duplicate env name" from the server, and server-side apply in particular
  fails outright rather than resolve last-wins the way the kubelet's $(VAR)
  expansion does. The chart's pd-only NIXL/UCX entries are load-bearing for
  NixlConnector, and a user that duplicates one (e.g. to bump
  VLLM_LOGGING_LEVEL to DEBUG) would otherwise produce exactly that broken
  shape. This helper renders one entry per name so apply succeeds; the user's
  value wins and the pod runs with it, whatever it is.

  Order: chart entries stay in the order the caller built them (load-bearing
  wherever an entry's value references an earlier entry via $(VAR) expansion),
  and a user entry overwrites its chart twin IN PLACE so position is stable;
  non-colliding user entries append at the end. Callers therefore emit their
  entries in dependency order and treat Values.env as a pure overlay.

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
{{- define "vllm.mergeEnv" -}}
{{- $padding := .padding | default 2 | int -}}
{{- $out := list -}}
{{- range (.chart | default list) -}}
  {{- $out = mustAppend $out . -}}
{{- end -}}
{{- range $raw := .user | default list -}}
  {{- /* A copy, so the caller's entry is never modified, with its value as a
       string; a valueFrom entry is left alone, except that a null value
       beside it is dropped (the API refuses an entry carrying both). */}}
  {{- $u := $raw -}}
  {{- if and (kindIs "map" $raw) (hasKey $raw "value") -}}
    {{- $u = deepCopy $raw -}}
    {{- if and (kindIs "invalid" $u.value) (hasKey $u "valueFrom") -}}
      {{- $_ := unset $u "value" -}}
    {{- else -}}
      {{- $_ := set $u "value" (include "vllm.envValueString" $u.value) -}}
    {{- end -}}
  {{- end -}}
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
