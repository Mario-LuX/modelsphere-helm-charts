{{/*
Expand the name of the chart.
*/}}
{{- define "llm-bench.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "llm-bench.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "llm-bench.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "llm-bench.labels" -}}
helm.sh/chart: {{ include "llm-bench.chart" . }}
{{ include "llm-bench.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "llm-bench.selectorLabels" -}}
app.kubernetes.io/name: {{ include "llm-bench.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "llm-bench.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "llm-bench.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
PostgreSQL service name
*/}}
{{- define "llm-bench.postgresql.fullname" -}}
{{- printf "%s-postgres" (include "llm-bench.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Redis service name
*/}}
{{- define "llm-bench.redis.fullname" -}}
{{- printf "%s-redis" (include "llm-bench.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Image references. `tag` is empty by default and falls back to the chart's
appVersion, so a chart upgrade moves the images with it and a pin is a single
explicit override rather than a value that silently means "latest".
*/}}
{{- define "llm-bench.backendImage" -}}
{{- printf "%s:%s" .Values.image.backend.repository (.Values.image.backend.tag | default .Chart.AppVersion) }}
{{- end }}

{{- define "llm-bench.frontendImage" -}}
{{- printf "%s:%s" .Values.image.frontend.repository (.Values.image.frontend.tag | default .Chart.AppVersion) }}
{{- end }}
