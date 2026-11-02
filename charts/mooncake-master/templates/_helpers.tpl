{{- define "mooncake-master.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mooncake-master.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mooncake-master.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "mooncake-master.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "mooncake-master.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mooncake-master.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: master
{{- end -}}

{{- define "mooncake-master.etcdSelectorLabels" -}}
app.kubernetes.io/name: {{ include "mooncake-master.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: etcd
{{- end -}}

{{- define "mooncake-master.etcdName" -}}
{{- printf "%s-etcd" (include "mooncake-master.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The HA connection string the masters use: explicit, or the bundled etcd. */}}
{{- define "mooncake-master.haConnstring" -}}
{{- if .Values.ha.connstring -}}
{{- .Values.ha.connstring -}}
{{- else if .Values.etcd.enabled -}}
{{- printf "http://%s-client.%s.svc:2379" (include "mooncake-master.etcdName" .) .Release.Namespace -}}
{{- else -}}
{{- fail "mooncake-master: set ha.connstring to your etcd endpoints, or enable the bundled etcd (etcd.enabled=true)" -}}
{{- end -}}
{{- end -}}

{{/* What clients put in MOONCAKE_MASTER: the backend, without the http:// scheme. */}}
{{- define "mooncake-master.clientEntry" -}}
{{- $cs := include "mooncake-master.haConnstring" . -}}
{{- printf "%s://%s" .Values.ha.backend (regexReplaceAll "https?://" $cs "") -}}
{{- end -}}
