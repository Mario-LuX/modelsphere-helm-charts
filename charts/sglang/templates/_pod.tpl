{{/*
  The pod spec every SGLang pod in this chart shares.

  There are three of them and they differ far less than they look:

    single   the Deployment's pod -- one node, serves traffic.
    leader   rank 0 of a LeaderWorkerSet group -- serves traffic AND drives the
             cross-node NCCL group.
    worker   rank 1..n-1 of that group -- never serves traffic; SGLang only
             starts the HTTP server on rank 0.

  Everything that is genuinely the same (the model volume, the model-check init
  container, the engine image, env, resources, scheduling) is written once here,
  so leader and worker cannot drift apart -- a mismatched --tp or a model volume
  present on one side only does not fail at render time, it fails minutes later
  as a NCCL timeout that reads like a network fault.

  What the role actually decides:

    - the engine command form. `single` keeps the exec form
      (sglang serve, no shell). Multi-node pods need a shell,
      for two reasons that both matter: --node-rank has to come from
      ${LWS_WORKER_INDEX} at runtime, and the rdma-injector webhook only prepends
      its `source /etc/gpu-node/nccl-ib.env` (the per-node NCCL_IB_HCA pipeline)
      to containers started as bash/sh -c. An exec-form container gets the
      hostPath mount and nothing else -- RDMA then silently falls back to the
      wrong HCA rather than failing.
      Neither form is built under commandOverride, which also frees
      model.localPath and model.gpus to be empty (see values.yaml).
    - --nnodes / --node-rank / --dist-init-addr, added only for lws roles.
    - probes, the hang-watcher sidecar and the container port: `serves` roles
      only. There is nothing listening on a worker to probe.
    - preStop: see sglang.preStopScript.

  Call it as:  include "sglang.podSpec" (dict "root" $ "role" "leader")
*/}}
{{- define "sglang.podSpec" -}}
{{- $root := .root }}
{{- $role := .role }}
{{- $lws := $root.Values.lws }}
{{- $multi := ne $role "single" }}
{{- $worker := eq $role "worker" }}
{{- $serves := not $worker }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- /* Defined -- including as [] -- takes the container over, and nothing below
       is built. [] renders no command at all: the image's ENTRYPOINT. */}}
{{- $cmd := $root.Values.commandOverride }}
{{- $override := not (kindIs "invalid" $cmd) }}
{{- /* Empty means no model volume: no hostPath, no mount. */}}
{{- $hasModel := ne (toString ($root.Values.model.localPath | default "")) "" }}
{{- if and $override $root.Values.extraArgs }}
{{- fail (printf "sglang: extraArgs is set (%v) but commandOverride replaces the command line the chart would append it to, so these flags would reach nothing. Fold them into commandOverride, or drop it" $root.Values.extraArgs) }}
{{- end }}
{{- if and (not $override) (not $hasModel) }}
{{- fail "sglang: model.localPath is empty while the chart is still building SGLang's command line, and SGLang cannot start without --model-path. Set commandOverride to run a non-SGLang image, or point model.localPath at the weights" }}
{{- end }}
{{- /*
  The engine command line, built once so both command forms say the same thing. Skipped entirely under commandOverride.

  extraArgs stays last so it can override anything above it -- SGLang's argparse
  takes the last occurrence of a repeated flag.
*/}}
{{- $flags := list
      (printf "--model-path=%s" $root.Values.model.mountPath)
      (printf "--served-model-name=%s" $root.Values.model.name)
      "--host=0.0.0.0"
      (printf "--port=%v" $root.Values.service.port) }}
{{- /* Left out when empty, so SGLang uses the model's own context length. */}}
{{- with $root.Values.model.contextLength }}
{{- $flags = append $flags (printf "--context-length=%v" .) }}
{{- end }}
{{- /*
  Not optional for this chart. SGLang mounts /metrics only when this is set (it
  defaults to off), and without it both the LLMScaler queries and the preStop
  drain below have nothing to read. Do not repeat it in extraArgs.
*/}}
{{- $flags = append $flags "--enable-metrics" }}
{{- if $multi }}
{{- /*
  The three flags that make one SGLang instance span the group. They are derived,
  not configured: nnodes IS lws.size (a group is the instance), the rank IS the
  pod's position in the group, and the rendezvous address IS the leader. Anything
  the chart cannot derive -- how those GPUs are carved up, i.e. --tp / --pp-size
  -- belongs in extraArgs, and the check in lws.yaml rejects restating these
  three there rather than letting two sources of truth disagree.

  ${LWS_WORKER_INDEX} and ${LWS_LEADER_ADDRESS} are injected into every pod of the
  group by the LWS controller; the leader is index 0 by definition, so it is
  written literally rather than read back from the env.
*/}}
{{- $flags = append $flags (printf "--nnodes=%v" $lws.size) }}
{{- $flags = append $flags (printf "--node-rank=%s" (ternary "${LWS_WORKER_INDEX}" "0" $worker)) }}
{{- $flags = append $flags (printf "--dist-init-addr=${LWS_LEADER_ADDRESS}:%v" $lws.distPort) }}
{{- end }}
{{- /* toString, so a YAML-typed entry (`- 8` under `- --tp`) reaches the pod as
       the string the API server requires rather than an int it rejects. */}}
{{- range $root.Values.extraArgs }}
{{- $flags = append $flags (toString .) }}
{{- end -}}
{{- /* Shutdown budget: preStop + SGLang's post-SIGTERM drain, checked by
       sglang.shutdownBudget. Workers get their own, because they drain nothing
       and their whole group is being deleted with them -- a long grace only
       holds GPUs until the kubelet's SIGKILL. */}}
{{- $grace := $root.Values.terminationGracePeriodSeconds }}
{{- if and $worker $lws.workerTerminationGracePeriodSeconds }}
{{- $grace = $lws.workerTerminationGracePeriodSeconds }}
{{- end }}
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
{{- /* The leader's dist port opens an image pull and a startup after the leader
       POD exists, which is all startupPolicy: LeaderCreated promises. A worker
       that races it and gives up first EXITS, which under
       RecreateGroupOnPodRestart restarts the whole group into the same cold
       start. Unbounded: a waiting worker is a late group, an exiting one is a
       loop -- at the cost of holding the pod's GPUs meanwhile. Reuses the engine
       image; bash's /dev/tcp does the probing. */}}
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
      leader="${LWS_LEADER_ADDRESS:-${POD_NAME%-*}.{{ ternary "${POD_NAME%-*}" (include "sglang.fullname" $root) (eq $lws.subdomainPolicy "UniquePerReplica") }}}"
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
- name: sglang
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  {{- if $override }}
  {{- with $cmd }}
  command:
    {{- range . }}
    - {{ toString . | quote }}
    {{- end }}
  {{- end }}
  {{- else if $multi }}
  # Shell form on purpose -- see the header of this file. `exec` keeps SGLang as
  # PID 1, which SIGTERM handling and the leader preStop below both depend on.
  #
  # ulimit -l lifts the locked-memory cap so the RDMA driver can pin its
  # buffers; without it NCCL falls back to a slower path or fails outright on an
  # IB fabric. Guarded, because a container without CAP_IPC_LOCK cannot raise it
  # and that is not a reason to refuse to start.
  #
  # Flags carrying a ${...} are left unquoted so the shell expands them; the rest
  # are single-quoted, so a value with a space in it (a JSON --*-override-args,
  # say) survives the trip through bash.
  command: ["bash", "-lc"]
  args:
    - |
      ulimit -l unlimited 2>/dev/null || true
      exec sglang serve{{ range $flags }} \
        {{ if contains "$" . }}{{ . }}{{ else }}{{ squote . }}{{ end }}{{ end }}
  {{- else }}
  command: ["sglang", "serve"]
  args:
    {{- range $flags }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  env:
    # false makes /health a plain status check. Left at SGLang's own
    # default (true) it runs a real 1-token generation, sleeps at least 1s
    # and can take 20s, which no sane probe timeout survives.
    - name: SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION
      value: {{ $root.Values.healthEndpointGeneration | quote }}
    {{- if $root.Values.lifecycle.forceShutdown }}
    # Makes SGLang skip its drain and exit as soon as SIGTERM arrives.
    #
    # Both spellings, because upstream renamed it and the two live side by side
    # across the images in use: 0.5.10 still reads SGL_FORCE_SHUTDOWN but warns
    # ("deprecated, please use SGLANG_FORCE_SHUTDOWN"), and 0.5.15 has dropped it
    # entirely -- grep the package and the string is not there, so on 0.5.15 the
    # old name alone is a no-op and this whole switch does nothing.
    - name: SGLANG_FORCE_SHUTDOWN
      value: "1"
    - name: SGL_FORCE_SHUTDOWN
      value: "1"
    {{- end }}
    {{- with $root.Values.env }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- if $serves }}
  ports:
  - containerPort: {{ $root.Values.service.port }}
    name: http
  {{- end }}
  {{- with $root.Values.securityContext }}
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
         leaves the key out altogether rather than asking for zero of it. */}}
  {{- $res := $root.Values.resources | default dict }}
  {{- range $section := list "limits" "requests" }}
  {{- if hasKey (index $res $section | default dict) "nvidia.com/gpu" }}
  {{- fail (printf "sglang: set the GPU count with model.gpus, not resources.%s -- model.gpus is what renders nvidia.com/gpu and what the rest of the chart refers to" $section) }}
  {{- end }}
  {{- end }}
  {{- $gpus := toString ($root.Values.model.gpus | default "") }}
  {{- if not (or (eq $gpus "") (eq $gpus "0")) }}
  {{- $res = mergeOverwrite (deepCopy $res) (dict "limits" (dict "nvidia.com/gpu" $gpus)) }}
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
      # Written in python3 because that is what the container already runs, so it is always there -- the SGLang image ships no curl or wget. Needs no external drain API.
      exec:
        command:
          - python3
          - -c
          # Whether the hook ends by killing SGLang itself is gated per role -- a group
          # through lws.leaderPreStopKill, since there the kill additionally has to
          # break a collective its workers have left; a single pod through
          # lifecycle.preStopKill. Deliberately NOT lifecycle.forceShutdown: that one
          # asks the engine to skip its drain, which is a statement about in-flight
          # requests, while this is about what to do when the engine does not exit at
          # all. Wanting the fallback without giving up the drain is a legitimate
          # combination, so they stay separate switches.
          - |
            {{- include "sglang.preStopScript" (dict "root" $root "serves" $serves "kill" (ternary $lws.leaderPreStopKill $root.Values.lifecycle.preStopKill $multi)) | nindent 14 }}
  {{- end }}
  {{- if $serves }}
  {{- with $root.Values.startupProbe }}
  # While this is running the kubelet suppresses the other two probes, so a
  # slow model load cannot trip a restart. Its
  # failureThreshold x periodSeconds is the entire startup budget.
  #
  # Under LWS it covers more than a model load: the leader's port only binds
  # once the whole group has finished the NCCL rendezvous, so this budget has
  # to clear the slowest worker's start too.
  startupProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.readinessProbe }}
  readinessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if $root.Values.hangWatcher.enabled }}
  # hang-watcher owns liveness: probe the sidecar's /healthz on the shared
  # pod network; a 503 (hang) restarts THIS container. Replaces the
  # /health_generate check -- see hangWatcher in values.yaml for why.
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
# own SGLang /metrics over localhost and serves /healthz for the engine's
# livenessProbe above. Reports only; the kubelet does the restart. No RBAC.
#
# Worker pods do not get one: they run no HTTP server, so there are no metrics
# to read -- and under RecreateGroupOnPodRestart a hung group is dealt with by
# restarting the leader anyway, which takes the whole group with it.
- name: hang-watcher
  image: "{{ $root.Values.hangWatcher.image.repository }}:{{ $root.Values.hangWatcher.image.tag }}"
  env:
  - name: ENGINE_URL
    value: "http://127.0.0.1:{{ $root.Values.service.port }}"
  - name: LISTEN
    value: ":{{ $root.Values.hangWatcher.port }}"
  - name: CONFIG_FILE
    value: /etc/hang-watcher/config.json
  {{- if (($root.Values.hangWatcher.config).logHang | default dict).enabled }}
  # Log fast path. Containers in a pod do NOT share a filesystem, so "same pod"
  # is not enough to read the engine's output: its stdout goes to the NODE, at
  # /var/log/pods/<ns>_<pod>_<uid>/<container>/N.log. Hence the read-only hostPath
  # below plus these two downward-API vars -- without them the glob would also match
  # the sglang container of every OTHER pod on the node, and a neighbour's stall
  # would get this pod restarted. The uid and the rotation index stay globs.
  #
  # (The alternative -- an emptyDir shared with the engine -- would need SGLang to
  # write to a file, which it has no flag for; wrapping the command in a `tee` pipe
  # would displace PID 1 and break the SIGTERM drain this chart relies on.)
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: POD_NS
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: LOG_FILE
    value: "/var/log/pods/$(POD_NS)_$(POD_NAME)_*/sglang/*.log"
  {{- with (($root.Values.hangWatcher.config).logHang | default dict).patterns }}
  {{- /* Join the list into one RE2 alternation. Each entry is wrapped in (?:...)
         so an entry that itself contains `|` stays self-contained instead of
         merging with the next one. Empty list -> env omitted -> sidecar default. */}}
  - name: LOG_HANG_PATTERN
    value: {{ (printf "(?:%s)" (join ")|(?:" .)) | quote }}
  {{- end }}
  {{- end }}
  ports:
  - containerPort: {{ $root.Values.hangWatcher.port }}
    name: hang-hz
  {{- with $root.Values.hangWatcher.readinessProbe }}
  # Readiness on the sidecar itself: a hang verdict drops the POD out of the Service (an endpoint
  # needs every container ready), so traffic stops arriving before the kill/drain even starts.
  # The engine's own /v1/models readiness is untouched and still applies -- see values.yaml.
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
  {{- if (($root.Values.hangWatcher.config).logHang | default dict).enabled }}
  - name: pod-logs
    mountPath: /var/log/pods
    readOnly: true
  {{- end }}
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
{{- if (($root.Values.hangWatcher.config).logHang | default dict).enabled }}
- name: pod-logs
  hostPath:
    path: /var/log/pods
    type: Directory
{{- end }}
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

{{/*
  The preStop hook's drain script, shared by the Deployment pod and the LWS
  leader. `kill` adds the LWS-only tail.

  Stage 1a (endpointSyncSeconds) always waits: Kubernetes removes the pod from
  the EndpointSlice and runs this hook at the SAME time, and the pod has no way
  to observe that removal. Stage 1b then watches SGLang's own metrics and returns
  as soon as the server goes idle, so a quiet pod shuts down in about
  endpointSyncSeconds rather than always burning drainSeconds.

  The tail (`kill`) exists because of how LWS tears a group down. It deletes the
  leader FIRST, so the leader takes SIGTERM while its workers are still running
  and still expecting it in the next collective. SGLang's own SIGTERM drain then
  blocks inside cross-node NCCL, PID 1 sits in do_wait, and the pod burns the
  entire terminationGracePeriodSeconds before the kubelet SIGKILLs it -- holding
  its GPUs the whole time, which on a full cluster is exactly what the
  replacement group is waiting for.

  What the tail may NOT do is SIGKILL PID 1. A process inside a PID namespace
  cannot kill that namespace's init: the kernel drops signals the init has no
  handler for, and SIGKILL can never have one (man 7 pid_namespaces). kill(2)
  still returns 0, so it reads as success while doing nothing.

  What works is the pair below. SIGTERM to PID 1 IS delivered, because SGLang
  installs a handler for it -- so the hook starts the real shutdown itself,
  inside the grace period. Then it waits shutdownReserveSeconds: if PID 1 exits,
  the kernel tears the PID namespace down and takes this hook with it, so simply
  surviving that sleep means SGLang is wedged. At that point its CHILDREN get
  SIGKILLed -- they carry no such protection -- and their death releases the
  do_wait PID 1 is parked in, so it exits on its own.

  Why the kill half exists at all: SGLang deleted mid-load misses SIGTERM (uvicorn has
  not installed its handler yet), finishes booting, and then holds its GPUs until the
  kubelet SIGKILLs it at terminationGracePeriodSeconds -- an hour, for these values.
  Both roles hit that, which is why `kill` is not lws-only; the caller decides.

  Call it as: include "sglang.preStopScript" (dict "root" $ "kill" true)
*/}}
{{- define "sglang.preStopScript" -}}
{{- $root := .root -}}
{{- $preStop := $root.Values.lifecycle.preStop -}}
{{- $poll := int ($preStop.pollIntervalSeconds | default 2) -}}
{{- /* ~30s of consecutive unreadable metrics, whatever the poll interval. */ -}}
{{- $streak := max 3 (div 30 $poll) -}}
{{- $streakSecs := mul $streak $poll -}}
import time, urllib.request, urllib.error{{ if .kill }}, os, signal{{ end }}

METRICS = "http://127.0.0.1:{{ $root.Values.service.port }}/metrics"
# What SGLang is working on right now, plus what is queued up.
# These names are SGLang's own -- vLLM calls them
# vllm:num_requests_running / vllm:num_requests_waiting.
BUSY = ("sglang:num_running_reqs", "sglang:num_queue_reqs")
# Never send this at a proxy: a cluster that injects HTTP_PROXY into pods would
# otherwise have us ask a proxy for the pod's OWN port, which it cannot reach --
# and an unreadable /metrics reads as "no server to drain" below.
OPEN = urllib.request.build_opener(urllib.request.ProxyHandler({})).open


def log(msg):
    # PID 1's stdout, so this lands in `kubectl logs` beside the engine's own.
    try:
        with open("/proc/1/fd/1", "a") as f:
            f.write("[preStop] %s\n" % msg)
    except Exception:
        pass


def inflight():
    """Requests still on this pod, or None if we cannot tell."""
    try:
        body = OPEN(METRICS, timeout=2).read().decode()
    except Exception:
        return None
    total, found = 0.0, False
    for line in body.splitlines():
        if line.startswith(BUSY):
            try:
                total += float(line.rsplit(" ", 1)[1])
            except (IndexError, ValueError):
                return None
            found = True
    # No matching series at all means the metrics we rely on are
    # missing (--enable-metrics dropped, or renamed upstream). Report
    # "cannot tell" rather than "idle", so a broken assumption makes
    # the drain wait instead of silently skipping.
    return total if found else None


# Keep serving while the cluster takes this pod out of rotation, so no new requests are sent here.
time.sleep({{ $preStop.endpointSyncSeconds }})

# Then wait for the requests we already accepted, stopping as soon as SGLang says it is idle.
# Unreadable metrics come back as None, which is never == 0, so a blip keeps us waiting rather
# than cutting requests off early. Staying unreadable for ~{{ $streakSecs }}s is different: there is no
# server to drain -- it never bound its port, or it has already died -- and sitting out the rest
# of drainSeconds would only hold the GPUs while the replacement waits for them. A live server
# is covered either way, because SIGTERM starts SGLang's own drain once this hook returns.
{{- /* The sidecar only exists on pods that serve (see the hang-watcher container below), so
       asking it anything is only meaningful there. preStop itself is already gated on $serves
       today, which would make this guard redundant -- state it anyway rather than rely on a
       caller two hundred lines away staying that way. */}}
{{- $askWatcher := and $root.Values.hangWatcher.enabled .serves }}
{{- if $askWatcher }}


HEALTHZ = "http://127.0.0.1:{{ $root.Values.hangWatcher.port }}/healthz"


def hung():
    """True when the hang-watcher sidecar has already called this engine hung."""
    try:
        OPEN(HEALTHZ, timeout=2)
        return False
    except urllib.error.HTTPError as e:
        return e.code == 503
    except Exception:
        return False        # sidecar unreachable -- say nothing, fall through to the drain
{{- end }}


deadline = time.monotonic() + {{ $preStop.drainSeconds }}
unreadable = 0
while time.monotonic() < deadline:
    {{- if $askWatcher }}
    # A hung engine's counters are frozen, not falling: they sit at whatever they were when it
    # wedged and never reach 0, so this loop would burn the full drainSeconds waiting for a
    # number that cannot move. Measured: the kubelet emitted Killing within 45s of the 503, and
    # the container still took ~4 more minutes to restart, stuck right here.
    #
    # This adds no new verdict of its own -- by the time preStop runs the container is already
    # being terminated, so the worst a wrong answer costs is one termination that did not wait
    # for a drain. That is not the same class of mistake as deciding to kill something.
    if hung():
        log("hang-watcher reports hung -- counters are frozen, nothing to drain")
        break
    {{- end }}
    n = inflight()
    if n == 0:
        log("drained: nothing in flight")
        break
    if n is None:
        unreadable += 1
        if unreadable >= {{ $streak }}:
            log("metrics unreadable for ~{{ $streakSecs }}s -- no server to drain")
            break
    else:
        unreadable = 0
    time.sleep({{ $poll }})
else:
    log("drain deadline reached after {{ $preStop.drainSeconds }}s, requests may still be in flight")
{{- if .kill }}

# Drained (or out of time). Drive the shutdown from here rather than let the
# kubelet's SIGTERM find SGLang blocked in a collective its workers will never
# join. SIGTERM reaches PID 1 because SGLang installs a handler for it; SIGKILL
# never would. See the comment above this script.
log("SIGTERM -> PID 1")
os.kill(1, signal.SIGTERM)

# If PID 1 exits, the kernel tears down the PID namespace and this hook dies with
# it -- so getting past this sleep means SGLang is stuck in its own drain.
time.sleep({{ $root.Values.lifecycle.shutdownReserveSeconds }})

log("still up after {{ $root.Values.lifecycle.shutdownReserveSeconds }}s -- killing PID 1's children to release its do_wait")
keep = (1, os.getpid(), os.getppid())
for entry in os.listdir("/proc"):
    if not entry.isdigit() or int(entry) in keep:
        continue
    try:
        os.kill(int(entry), signal.SIGKILL)
    except OSError:
        pass
{{- end }}
{{- end -}}
