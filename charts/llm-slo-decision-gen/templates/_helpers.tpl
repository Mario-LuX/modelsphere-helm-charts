{{- define "llm-slo.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Cluster-scoped RBAC names. Bare "decision-gen" / "slo-api" collide when two
releases of this chart are installed (even into different namespaces). Scope
by Release.Name so each release owns its own ClusterRole/Binding. Namespaced
workloads (Service, Deployment, ServiceAccount) stay on fixed names so the
DNS contract decision-gen.<Release.Namespace>.svc remains stable.
*/}}
{{- define "llm-slo.decisionGen.clusterRoleName" -}}
{{- printf "%s-decision-gen" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llm-slo.sloApi.clusterRoleName" -}}
{{- printf "%s-slo-api" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
