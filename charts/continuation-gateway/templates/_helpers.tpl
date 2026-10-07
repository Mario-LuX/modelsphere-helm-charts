{{/* The chart's own name is written out rather than read from .Chart.Name: when this
     chart is a subchart under an `alias` (sglang uses continuationGateway), Helm
     reports the alias as .Chart.Name, and a camelCase resource name is not a legal
     DNS label. */}}
{{- define "continuation-gateway.chartName" -}}continuation-gateway{{- end -}}
{{- define "continuation-gateway.name" -}}{{ default (include "continuation-gateway.chartName" .) .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "continuation-gateway.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}{{- $name := default (include "continuation-gateway.chartName" .) .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else -}}{{ printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}{{- end -}}{{- end -}}
{{- end -}}
{{- define "continuation-gateway.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "continuation-gateway.chartName" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "continuation-gateway.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "continuation-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "continuation-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Downstream URL. An explicit downstream.url wins outright. Otherwise it is this
     release's CART, whose Service name is the cart chart's fullname for a release
     with no cart.nameOverride/fullnameOverride: <release>-cart, or just <release>
     when the release name already contains "cart". That rule is restated here rather
     than called, because a subchart cannot reach a sibling's helpers or the parent's
     values -- which is also why a changed cart name has to be mirrored by setting
     downstream.url. */}}
{{- define "continuation-gateway.downstreamUrl" -}}
{{- if .Values.downstream.url -}}
{{- .Values.downstream.url | trimSuffix "/" -}}
{{- else -}}
{{- $svc := .Values.downstream.service -}}
{{- if not $svc -}}
{{- $svc = ternary .Release.Name (printf "%s-cart" .Release.Name) (contains "cart" .Release.Name) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- printf "http://%s.%s.svc:%d" $svc (.Values.downstream.namespace | default .Release.Namespace) (int .Values.downstream.port) -}}
{{- end -}}
{{- end -}}

{{/* Models that get resume behaviour, as the comma-separated string the gateway reads:
     config.continuationModels, else global.modelName (set by the parent chart, e.g.
     sglang), else empty. config.continuationModels may be written as a string
     ("a,b") or a list ([a, b]); a list is joined, because passing it through as-is
     would render "[a b]" and the gateway would silently match no model. */}}
{{- define "continuation-gateway.models" -}}
{{- $m := .Values.config.continuationModels | default (.Values.global | default dict).modelName | default "" -}}
{{- if kindIs "slice" $m }}{{ join "," $m }}{{ else }}{{ $m }}{{ end -}}
{{- end -}}
