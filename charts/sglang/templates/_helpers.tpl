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
