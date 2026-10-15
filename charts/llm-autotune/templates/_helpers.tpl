{{- define "llm-autotune.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llm-autotune.fullname" -}}
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

{{- define "llm-autotune.labels" -}}
app.kubernetes.io/name: {{ include "llm-autotune.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- /* Labels for the pod template of something that keeps state (the database,
the mock benchmark's submissions): no version or chart label. A pod template
that changes restarts the pod, and these must not restart on every upgrade
just because the chart's version did; with postgresql.storage.enabled=false
that restart would empty the database. */ -}}
{{- define "llm-autotune.stableLabels" -}}
app.kubernetes.io/name: {{ include "llm-autotune.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "llm-autotune.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "llm-autotune.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "llm-autotune.backendImage" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.backend $tag -}}
{{- end -}}

{{- define "llm-autotune.frontendImage" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.frontend $tag -}}
{{- end }}

{{- define "llm-autotune.mockEngineImage" -}}
{{- .Values.mockModel.image | default (printf "llm-autotune-mock-engine:%s" .Chart.AppVersion) -}}
{{- end -}}

{{/*
Environment shared by the api, the worker and the migration job. Settings that
are secret come from the Secret; everything else from the ConfigMap. Both are
mounted wholesale so adding a setting is a one-line change here.
*/}}
{{- define "llm-autotune.env" -}}
envFrom:
  - configMapRef:
      name: {{ include "llm-autotune.fullname" . }}-config
  - secretRef:
      name: {{ include "llm-autotune.fullname" . }}-secrets
{{- with .Values.extraEnv }}
env: {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Why the runLogs claim may never bind, read from the cluster at install time:
"" when it should bind (or when there is no cluster to ask, as in
`helm template`), "no-default" when no class is named and the cluster has no
default one, "missing <class>" when the named class does not exist, and
"rwo <class> <provisioner>" when the class's provisioner only makes
single-node volumes, which a ReadWriteMany claim waits on forever. The list is
of provisioners known to be ReadWriteOnce only; an unknown one is given the
benefit of the doubt.
*/}}
{{- define "llm-autotune.runLogsProblem" -}}
{{- if .Values.runLogs.enabled -}}
{{- $classes := lookup "storage.k8s.io/v1" "StorageClass" "" "" -}}
{{- if $classes -}}
{{- $sc := dict -}}
{{- $name := .Values.runLogs.storageClass -}}
{{- range ($classes.items | default list) -}}
{{- $isDefault := index (.metadata.annotations | default dict) "storageclass.kubernetes.io/is-default-class" | default "" -}}
{{- if or (and $name (eq .metadata.name $name)) (and (not $name) (eq $isDefault "true")) -}}
{{- $sc = . -}}
{{- end -}}
{{- end -}}
{{- if not $sc -}}
{{- if $name -}}missing {{ $name }}{{- else -}}no-default{{- end -}}
{{- else -}}
{{- $rwoOnly := list "rancher.io/local-path" "k8s.io/minikube-hostpath" "docker.io/hostpath" "kubernetes.io/host-path" "kubernetes.io/no-provisioner" "openebs.io/local" "topolvm.io" "ebs.csi.aws.com" "kubernetes.io/aws-ebs" "pd.csi.storage.gke.io" "kubernetes.io/gce-pd" "disk.csi.azure.com" "kubernetes.io/azure-disk" "cinder.csi.openstack.org" "kubernetes.io/cinder" -}}
{{- if or (has $sc.provisioner $rwoOnly) (hasSuffix ".rbd.csi.ceph.com" $sc.provisioner) -}}
rwo {{ $sc.metadata.name }} {{ $sc.provisioner }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
