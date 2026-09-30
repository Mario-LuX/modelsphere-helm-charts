{{/*
  The pod spec every vLLM pod in this chart shares.

  There are three of them and they differ far less than they look:

    single   the Deployment's pod -- one node, serves traffic.
    leader   rank 0 of a LeaderWorkerSet group -- serves traffic AND hosts the
             group's rendezvous (torch TCPStore on lws.distPort).
    worker   rank 1..n-1 of that group -- runs vLLM --headless: GPU workers
             only, no API server, never serves traffic.

  Everything that is genuinely the same (the model volume, the model-check init
  container, the engine image, env, resources, scheduling) is written once here,
  so leader and worker cannot drift apart -- a mismatched
  --tensor-parallel-size or a model volume present on one side only does not
  fail at render time, it fails minutes later as a NCCL timeout that reads like
  a network fault.

  What the role actually decides:

    - the engine command form. Every role runs `vllm serve` (the image's own
      entrypoint, and the only CLI that handles --headless). `single` keeps the
      exec form (no shell). Multi-node pods need a shell, for two reasons that
      both matter:
        * --node-rank has to come from ${LWS_WORKER_INDEX} at runtime.
        * the rdma-injector webhook only prepends its
          `source /etc/gpu-node/nccl-ib.env` (the per-node NCCL_IB_HCA pipeline)
          to containers started as bash/sh -c. An exec-form container gets the
          hostPath mount and nothing else -- RDMA then silently falls back to
          the wrong HCA rather than failing.
      Neither form is built under commandOverride, which also frees
      model.localPath and model.gpus to be empty (see values.yaml).
    - --nnodes / --node-rank / --master-addr / --master-port /
      --distributed-executor-backend, added only for lws roles, plus
      --headless on workers.
    - probes, the hang-watcher sidecar and the container port: `serves` roles
      only. There is nothing listening on a worker to probe.
    - preStop: see vllm.preStopScript.

  Call it as:  include "vllm.podSpec" (dict "root" $ "role" "leader")
*/}}
{{- define "vllm.podSpec" -}}
{{- $root := .root }}
{{- $role := .role }}
{{- $lws := $root.Values.lws }}
{{- $multi := ne $role "single" }}
{{- $worker := eq $role "worker" }}
{{- $serves := not $worker }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- /* Defined -- including as [] -- takes the container over, and nothing the
       chart would build is used. [] renders no command at all: the image's own
       ENTRYPOINT. */}}
{{- $cmd := $root.Values.commandOverride }}
{{- $override := not (kindIs "invalid" $cmd) }}
{{- /* Empty means no model volume: no hostPath, no mount. */}}
{{- $hasModel := ne (toString ($root.Values.model.localPath | default "")) "" }}
{{- if and $override $root.Values.extraArgs }}
{{- fail (printf "vllm: extraArgs is set (%v) but commandOverride replaces the command line the chart would append it to, so these flags would reach nothing. Fold them into commandOverride, or drop it" $root.Values.extraArgs) }}
{{- end }}
{{- if and (not $override) (not $hasModel) }}
{{- fail "vllm: model.localPath is empty while the chart is still building vLLM's command line, and vLLM cannot start without --model. Set commandOverride to run a non-vLLM image, or point model.localPath at the weights" }}
{{- end }}
{{- /*
  The engine command line, built once so both command forms say the same thing.
  Skipped entirely under commandOverride.

  extraArgs stays last so it can override anything above it -- vLLM's argparse
  takes the last occurrence of a repeated flag.
*/}}
{{- /* The flags the chart itself derives from the LWS environment at runtime --
       the only ones the multi-node shell may expand. */}}
{{- $expand := list }}
{{- $flags := list
      (printf "--model=%s" $root.Values.model.mountPath)
      (printf "--served-model-name=%s" $root.Values.model.name)
      "--host=0.0.0.0"
      (printf "--port=%v" $root.Values.service.port) }}
{{- /* Left out when empty, so vLLM uses the model's own max length.
       model.maxLen is the old name of model.contextLength and still wins when
       set, so values written for earlier chart versions keep their meaning. */}}
{{- $ctxLen := $root.Values.model.contextLength }}
{{- if hasKey $root.Values.model "maxLen" }}
{{- $ctxLen = $root.Values.model.maxLen }}
{{- end }}
{{- with $ctxLen }}
{{- $flags = append $flags (printf "--max-model-len=%v" .) }}
{{- end }}
{{- /* Once SIGTERM arrives, give requests that are still running this long to
       finish instead of killing them (vLLM's default is 0 = kill). This catches
       anything that ran past the preStop hook below. */}}
{{- if gt (int $root.Values.lifecycle.shutdownTimeout) 0 }}
{{- $flags = append $flags (printf "--shutdown-timeout=%v" $root.Values.lifecycle.shutdownTimeout) }}
{{- end }}
{{- if $multi }}
{{- /*
  The flags that make one vLLM instance span the group. They are derived, not
  configured: nnodes IS lws.size (a group is the instance), the rank IS the
  pod's position in the group, and the rendezvous address IS the leader.
  Anything the chart cannot derive -- how those GPUs are carved up, i.e.
  --tensor-parallel-size / --pipeline-parallel-size -- belongs in extraArgs,
  and the check in lws.yaml rejects restating these there rather than letting
  two sources of truth disagree.

  ${LWS_WORKER_INDEX} and ${LWS_LEADER_ADDRESS} are injected into every pod of the
  group by the LWS controller; the leader is index 0 by definition, so it is
  written literally rather than read back from the env.

  mp, not Ray: the multiprocessing executor spans nodes by itself, so there is
  no Ray cluster to stand up in front of vLLM. Spelled out because vLLM picks
  Ray on its own when the world size exceeds the node's GPUs.
*/}}
{{- $flags = append $flags "--distributed-executor-backend=mp" }}
{{- $flags = append $flags (printf "--nnodes=%v" $lws.size) }}
{{- $flags = append $flags (printf "--node-rank=%s" (ternary "${LWS_WORKER_INDEX}" "0" $worker)) }}
{{- $expand = append $expand (last $flags) }}
{{- $flags = append $flags "--master-addr=${LWS_LEADER_ADDRESS}" }}
{{- $expand = append $expand (last $flags) }}
{{- $flags = append $flags (printf "--master-port=%v" $lws.distPort) }}
{{- if $worker }}
{{- $flags = append $flags "--headless" }}
{{- end }}
{{- end }}
{{- /* toString, so a YAML-typed entry (`- 2` under `- --tensor-parallel-size`)
       reaches the pod as the string the API server requires rather than an int
       it rejects. */}}
{{- range $root.Values.extraArgs }}
{{- $flags = append $flags (toString .) }}
{{- end }}
{{- /* Shutdown budget: preStop + vLLM finishing up after SIGTERM, checked by
       vllm.shutdownBudget. Workers get their own, because they drain nothing
       and their whole group is being deleted with them -- a long grace only
       holds GPUs until the kubelet's SIGKILL. */}}
{{- $grace := $root.Values.terminationGracePeriodSeconds }}
{{- /* 0 is a real value (SIGKILL at once -- a worker drains nothing); only
       empty or null means "same as the leader's". */}}
{{- $wg := $lws.workerTerminationGracePeriodSeconds }}
{{- if and $worker (not (kindIs "invalid" $wg)) (ne (toString $wg) "") }}
{{- $grace = $wg }}
{{- end -}}
# Total time allowed to shut down. The preStop hook AND vLLM finishing up after SIGTERM both come out of this, or the pod gets killed.
# Checked at render time by vllm.shutdownBudget.
terminationGracePeriodSeconds: {{ $grace }}
{{- /* Workers wait for the leader's rendezvous port; leaders wait for nothing. */}}
{{- $waitLeader := and $worker $lws.waitForLeader }}
{{- if or $root.Values.modelCheck.enabled $waitLeader }}
initContainers:
{{- if $root.Values.modelCheck.enabled }}
# Refuse to start the engine unless the mounted model directory actually
# holds a model. hostPathType above already rejects a missing path; this
# covers an empty or half-copied one. Reuses the engine image so no extra
# image has to be pulled, and takes no GPU.
- name: model-check
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  command:
    - /bin/sh
    - -c
    - |
      DIR={{ $root.Values.model.mountPath | quote }}
      if [ ! -d "$DIR" ]; then
        echo "model-check: $DIR is not a directory" >&2
        exit 1
      fi
      if [ -z "$(ls -A "$DIR" 2>/dev/null)" ]; then
        echo "model-check: $DIR is empty -- is {{ $root.Values.model.localPath }} populated on this node?" >&2
        exit 1
      fi
      {{- range $root.Values.modelCheck.requiredGlobs }}
      if [ -z "$(find "$DIR" -maxdepth 1 -name {{ . | quote }} -print -quit)" ]; then
        echo "model-check: no {{ . }} directly under $DIR -- looks like an incomplete model" >&2
        exit 1
      fi
      {{- end }}
      echo "model-check: $DIR looks like a model directory"
  volumeMounts:
  - name: model-storage
    mountPath: {{ $root.Values.model.mountPath }}
    readOnly: true
{{- end }}
{{- if $waitLeader }}
{{- /* The leader's rendezvous port opens an image pull and a process start
       after the leader POD exists, which is all startupPolicy: LeaderCreated
       promises. A worker that races it and gives up first EXITS, which under
       RecreateGroupOnPodRestart restarts the whole group into the same cold
       start. Unbounded: a waiting worker is a late group, an exiting one is a
       loop -- at the cost of holding the pod's GPUs meanwhile. Reuses the
       engine image; bash's /dev/tcp does the probing. */}}
- name: wait-leader
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  env:
  {{- /* Fallback if LWS does not inject its env into init containers: this pod
         is <leader-pod>-<workerIndex>, on the LWS's headless Service (or, under
         UniquePerReplica, the per-group one, which carries the leader's name). */}}
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  command: ["bash", "-lc"]
  args:
    - |
      set -u
      leader="${LWS_LEADER_ADDRESS:-${POD_NAME%-*}.{{ ternary "${POD_NAME%-*}" (include "vllm.fullname" $root) (eq $lws.subdomainPolicy "UniquePerReplica") }}}"
      port={{ $lws.distPort }}
      echo "wait-leader: waiting for the group leader at ${leader}:${port}"
      i=0
      until timeout 5 bash -c "exec 3<>/dev/tcp/${leader}/${port}" 2>/dev/null; do
        i=$((i + 1))
        # ~1 line a minute, so a 20-minute cold start does not bury the log
        [ $((i % 12)) -eq 1 ] && echo "wait-leader: ${leader}:${port} not accepting yet (${i} tries)"
        sleep 5
      done
      echo "wait-leader: ${leader}:${port} is up after ${i} tries -- starting the engine"
{{- end }}
{{- end }}
containers:
- name: vllm
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  {{- if $override }}
  {{- with $cmd }}
  command:
    {{- range . }}
    - {{ toString . | quote }}
    {{- end }}
  {{- end }}
  {{- else if $multi }}
  # Shell form on purpose -- see the header of this file. `exec` keeps vLLM as
  # PID 1, which SIGTERM handling and the leader preStop below both depend on.
  #
  # ulimit -l lifts the locked-memory cap so the RDMA driver can pin its
  # buffers; without it NCCL falls back to a slower path or fails outright on an
  # IB fabric. Guarded, because a container without CAP_IPC_LOCK cannot raise it
  # and that is not a reason to refuse to start.
  #
  # Every flag reaches the engine exactly as written. The ones the chart derives
  # from the LWS environment (the rank and the leader's address) are
  # double-quoted so bash expands their ${...}; everything else -- extraArgs
  # included -- is single-quoted with any ' inside escaped, so spaces, quotes,
  # $ and JSON survive the trip through bash untouched, the same as in the
  # single-pod exec form. To reference the container's env from extraArgs, use
  # Kubernetes' $(VAR) syntax: the kubelet expands it in either form.
  command: ["bash", "-lc"]
  args:
    - |
      ulimit -l unlimited 2>/dev/null || true
      exec vllm serve{{ range $flags }} \
        {{ if has . $expand }}"{{ . }}"{{ else }}'{{ replace "'" "'\\''" . }}'{{ end }}{{ end }}
  {{- else }}
  command: ["vllm", "serve"]
  args:
    {{- range $flags }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- with $root.Values.env }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if $serves }}
  ports:
  - containerPort: {{ $root.Values.service.port }}
    name: http
  {{- end }}
  {{- /* rdma.enabled adds IPC_LOCK to whatever securityContext says, so the
         RDMA driver can pin its buffers (and the lws command form's
         `ulimit -l unlimited` actually takes). Added once, never duplicated. */}}
  {{- $sc := deepCopy ($root.Values.securityContext | default dict) }}
  {{- if $root.Values.rdma.enabled }}
  {{- $caps := $sc.capabilities | default dict }}
  {{- $add := $caps.add | default list }}
  {{- if not (has "IPC_LOCK" $add) }}
  {{- $_ := set $caps "add" (append $add "IPC_LOCK") }}
  {{- end }}
  {{- $_ := set $sc "capabilities" $caps }}
  {{- end }}
  {{- with $sc }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if or $hasModel $root.Values.volumeMounts }}
  volumeMounts:
  {{- if $hasModel }}
  - name: model-storage
    mountPath: {{ $root.Values.model.mountPath }}
    readOnly: true
  {{- end }}
  {{- with $root.Values.volumeMounts }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- end }}
  {{- /* The GPU limit stays derived from model.gpus -- the one place this
         chart names a GPU count -- and is merged over whatever else is in
         .Values.resources, so cpu/memory/ephemeral-storage can be set
         without restating it. A second way to say "2 GPUs" would only
         drift, so naming it under resources is refused rather than
         silently ignored.

         nvidia.com/gpu is an extended resource: it belongs in limits
         only, and the kubelet sets the request equal to it. Empty or 0
         leaves the key out altogether rather than asking for zero of it.

         Under lws.enabled this is per POD: a group holds lws.size x
         model.gpus GPUs. */}}
  {{- $res := $root.Values.resources | default dict }}
  {{- range $section := list "limits" "requests" }}
  {{- if hasKey (index $res $section | default dict) "nvidia.com/gpu" }}
  {{- fail (printf "vllm: set the GPU count with model.gpus, not resources.%s -- model.gpus is what renders nvidia.com/gpu and what the rest of the chart refers to" $section) }}
  {{- end }}
  {{- end }}
  {{- $gpus := toString ($root.Values.model.gpus | default "") }}
  {{- if not (or (eq $gpus "") (eq $gpus "0")) }}
  {{- $res = mergeOverwrite (deepCopy $res) (dict "limits" (dict "nvidia.com/gpu" $gpus)) }}
  {{- end }}
  {{- /* rdma.enabled adds one RDMA device from the shared-device plugin
         (rdma/hca_shared), unless resources already asks for it -- the user's
         count stands. A null there counts as not asking: it is what a values
         overlay leaves behind when it removes a hand-written entry, and the
         point of such an overlay is to hand the job to this switch. */}}
  {{- if $root.Values.rdma.enabled }}
  {{- if kindIs "invalid" (index (index $res "limits" | default dict) "rdma/hca_shared") }}
  {{- $res = mergeOverwrite (deepCopy $res) (dict "limits" (dict "rdma/hca_shared" "1")) }}
  {{- end }}
  {{- end }}
  {{- with $res }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- /* No preStop on a worker: it serves nothing, so there is nothing to drain,
         and it must stay in the NCCL group until the leader is done with it. */}}
  {{- if and $preStop.enabled $serves }}
  lifecycle:
    preStop:
      # Runs before SIGTERM, and its time counts against terminationGracePeriodSeconds.
      # Written in python3 because that is what the container already runs, so it is always there -- the vLLM image ships no curl or wget. Needs no external drain API.
      exec:
        command:
          - python3
          - -c
          # Whether the hook ends by killing vLLM itself is gated per role -- a group
          # through lws.leaderPreStopKill, since there the kill additionally has to
          # break a collective its workers have left; a single pod through
          # lifecycle.preStopKill.
          - |
            {{- include "vllm.preStopScript" (dict "root" $root "kill" (ternary $lws.leaderPreStopKill $root.Values.lifecycle.preStopKill $multi)) | nindent 12 }}
  {{- end }}
  {{- if $serves }}
  {{- with $root.Values.startupProbe }}
  # While this is running the kubelet suppresses the other two probes, so a
  # slow model load cannot trip a restart. Its
  # failureThreshold x periodSeconds is the entire startup budget.
  {{- if $multi }}
  #
  # Under LWS it covers more than a model load: the leader's port only binds
  # once every worker has joined and loaded its shard, so this budget has to
  # clear the slowest worker's start too.
  {{- end }}
  startupProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.readinessProbe }}
  readinessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if $root.Values.hangWatcher.enabled }}
  # hang-watcher owns liveness: probe the sidecar's /healthz on the shared
  # pod network; a 503 (hang) restarts THIS container. Replaces the default
  # livenessProbe -- see hangWatcher in values.yaml for why.
  livenessProbe:
    httpGet:
      path: /healthz
      port: {{ $root.Values.hangWatcher.port }}
    {{- with $root.Values.hangWatcher.livenessProbe }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- else }}
  {{- with $root.Values.livenessProbe }}
  livenessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
  {{- end }}
{{- if and $root.Values.hangWatcher.enabled $serves }}
# Hang-detection sidecar (see hangWatcher in values.yaml). Reads this pod's
# own vLLM /metrics over localhost and serves /healthz for the engine's
# livenessProbe above. Reports only; the kubelet does the restart. No RBAC.
{{- if $multi }}
#
# Worker pods do not get one: they run no API server, so there are no metrics
# to read -- and under RecreateGroupOnPodRestart a hung group is dealt with by
# restarting the leader anyway, which takes the whole group with it.
{{- end }}
- name: hang-watcher
  image: "{{ $root.Values.hangWatcher.image.repository }}:{{ $root.Values.hangWatcher.image.tag }}"
  env:
  - name: ENGINE_URL
    value: "http://127.0.0.1:{{ $root.Values.service.port }}"
  - name: LISTEN
    value: ":{{ $root.Values.hangWatcher.port }}"
  - name: CONFIG_FILE
    value: /etc/hang-watcher/config.json
  ports:
  - containerPort: {{ $root.Values.hangWatcher.port }}
    name: hang-hz
  {{- with $root.Values.hangWatcher.readinessProbe }}
  # Readiness on the sidecar itself: a pod is an endpoint only while every container is
  # ready, so a hang verdict drops the POD out of the Service before the restart even
  # starts. The engine's own readinessProbe is untouched and still applies.
  readinessProbe:
    httpGet:
      path: /healthz
      port: {{ $root.Values.hangWatcher.port }}
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
  - name: hang-watcher-config
    mountPath: /etc/hang-watcher
    readOnly: true
  {{- with $root.Values.hangWatcher.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- $hangVol := and $root.Values.hangWatcher.enabled $serves }}
{{- if or $hasModel $hangVol $root.Values.volumes }}
volumes:
{{- if $hasModel }}
- name: model-storage
  hostPath:
    path: {{ $root.Values.model.localPath }}
    type: {{ $root.Values.model.hostPathType }}
{{- end }}
{{- if $hangVol }}
- name: hang-watcher-config
  configMap:
    name: {{ $root.Release.Name }}-hang-watcher
{{- end }}
{{- with $root.Values.volumes }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}
{{- with $root.Values.schedulerName }}
schedulerName: {{ . }}
{{- end }}
{{- with $root.Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with $root.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
