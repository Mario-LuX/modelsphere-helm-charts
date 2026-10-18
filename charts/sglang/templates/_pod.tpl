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

  The work is split into three defines so the pd colocate shape can put TWO
  engines (and two hang-watchers) into ONE pod without copying the engine
  container:

    sglang.engineIdentity   turns a role into everything the engine command and
                            its probes/preStop need -- the flags, the pd trio,
                            the colocate port-name offset -- as a YAML dict, so
                            a caller two hundred lines away reads ONE source of
                            truth instead of re-deriving it. Renders nothing on
                            its own; the dict is the whole output.
    sglang.engineContainers the engine's container list item, plus the
                            hang-watcher sidecar that watches it. Consumes the
                            identity dict. Emits list items only (no
                            `containers:` key) so colocate can interleave its
                            router container.
    sglang.podSpec          the whole one-engine pod: prologue, the identity,
                            initContainers, `containers:` + engineContainers,
                            then the volumes/scheduling scaffold.
*/}}
{{- define "sglang.engineIdentity" -}}
{{- $root := .root }}
{{- $role := .role }}
{{- $lws := $root.Values.lws }}
{{- $multi := ne $role "single" }}
{{- /* pd role strings ("prefill-leader", "decode-worker", ...) gate the pd
       branches below; the role's values block flows in as .roleCfg from the
       pd templates. Non-pd callers pass neither. */}}
{{- $pdRole := or (hasPrefix "prefill-" $role) (hasPrefix "decode-" $role) }}
{{- $roleCfg := .roleCfg | default dict }}
{{- $worker := or (eq $role "worker") (hasSuffix "-worker" $role) }}
{{- $serves := not $worker }}
{{- /* Colocate-only identity: in the merged pod the two engine containers and
       their hang-watchers must not share a container name or a log
       glob, and each sidecar gets its own listen port. Decode is the offset
       side (idx/oc "1"); prefill keeps the plain names. Empty in every
       one-engine pod, so non-colocate renders are unchanged. */}}
{{- $oc := ternary "1" "" (and .colocate (hasPrefix "decode-" $role)) }}
{{- /* The engine's HTTP port is named after its role, not after $oc. Two
       reasons it is not "http" and "http1": "http1" reads as a second port of
       an unnamed thing rather than as decode, and the role Services that
       Prometheus scrapes already publish http-prefill / http-decode -- having
       the container agree removes the step where a reader has to know that
       targetPort http1 means decode. A non-pd pod keeps the plain "http",
       which is what service.yaml and every non-pd probe expect. */}}
{{- $pname := "http" }}
{{- if hasPrefix "prefill-" $role }}{{- $pname = "http-prefill" }}{{- end }}
{{- if hasPrefix "decode-" $role }}{{- $pname = "http-decode" }}{{- end }}
{{- $hwOffset := ternary 1 0 (eq $oc "1") }}
{{- $hwPort := add (int $root.Values.hangWatcher.port) $hwOffset }}
{{- $pobj := ternary $root.Values.pd.decode $root.Values.pd.prefill (hasPrefix "decode-" $role) }}
{{- $httpPort := ternary ($pobj.httpPort | default $root.Values.service.port) $root.Values.service.port $pdRole }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- $cache := $root.Values.cache | default dict }}
{{- /* Defined -- including as [] -- takes the container over, and nothing below
       is built. [] renders no command at all: the image's ENTRYPOINT. */}}
{{- $cmd := $root.Values.commandOverride }}
{{- $override := not (kindIs "invalid" $cmd) }}
{{- $cacheEnabled := and ($cache.enabled | default false) (not $override) }}
{{- $cacheSuffix := ternary $cache.hostPathSuffix (include "sglang.cacheModelDir" $root) (not (kindIs "invalid" $cache.hostPathSuffix)) }}
{{- $cacheBaseHostPath := $cache.hostPath | default "/mnt/disk0/sglang-cache" | trimSuffix "/" }}
{{- $cacheFullHostPath := ternary (printf "%s/%s" $cacheBaseHostPath $cacheSuffix) $cacheBaseHostPath (ne (toString $cacheSuffix) "") }}
{{- /* Empty means no model volume: no hostPath, no mount. */}}
{{- $hasModel := ne (toString ($root.Values.model.localPath | default "")) "" }}
{{- if and $override $root.Values.extraArgs }}
{{- fail (printf "sglang: extraArgs is set (%v) but commandOverride replaces the command line the chart would append it to, so these flags would reach nothing. Fold them into commandOverride, or drop it" $root.Values.extraArgs) }}
{{- end }}
{{- if and (not $override) (not $hasModel) }}
{{- fail "sglang: model.localPath is empty while the chart is still building SGLang's command line, and SGLang cannot start without --model-path. Set commandOverride to run a non-SGLang image, or point model.localPath at the weights" }}
{{- end }}
{{- /* The cache manager replaces ~/.cache/sglang with a symlink to the slot it
       leases (wire_cache uses expanduser("~")), so a volume mounted there --
       and only there -- would collide. A mount on ~/.cache itself is fine: the
       symlink is made inside it.

       Resolve ~ the same way the chart can see it: env HOME if set, else /root
       (empty securityContext → image root). Non-root runAsUser without HOME is
       refused so this guard cannot silently check the wrong path. */}}
{{- if $cacheEnabled }}
{{- $homeFromEnv := false }}
{{- $homeFromValueFrom := false }}
{{- range $root.Values.env }}
{{- if eq .name "HOME" }}
{{- if and (hasKey . "value") (ne (toString .value) "") }}
{{- $homeFromEnv = true }}
{{- else if hasKey . "valueFrom" }}
{{- $homeFromValueFrom = true }}
{{- end }}
{{- end }}
{{- end }}
{{- $sc := $root.Values.securityContext | default dict }}
{{- $nonRoot := and (hasKey $sc "runAsUser") (ne (int $sc.runAsUser) 0) }}
{{- if and $nonRoot (not $homeFromEnv) }}
{{- fail "sglang: cache.enabled with securityContext.runAsUser != 0 requires env HOME (a plain value, not valueFrom) so the managed-cache collision check matches wire_cache's expanduser(\"~\"); set env HOME to the container home, or run as root" }}
{{- end }}
{{- if $homeFromValueFrom }}
{{- fail "sglang: cache.enabled cannot resolve env HOME from valueFrom at render time; set HOME to a plain value so the managed-cache collision check matches wire_cache's expanduser(\"~\")" }}
{{- end }}
{{- $cacheLink := printf "%s/.cache/sglang" (include "sglang.cacheHome" $root) }}
{{- range $vm := $root.Values.volumeMounts }}
{{- $mp := clean (toString $vm.mountPath) }}
{{- if or (eq $mp $cacheLink) (hasPrefix (printf "%s/" $cacheLink) $mp) }}
{{- fail (printf "sglang: cache.enabled is true, but volumeMounts carries a mount at %s (volume %q). That path (%s) is where the managed cache symlinks the host slot it leases; remove the manual volumeMount, or turn cache.enabled off and manage the directory yourself" $vm.mountPath ($vm.name | default "unnamed") $cacheLink) }}
{{- end }}
{{- end }}
{{- end }}
{{- /*
  The engine command line, built once so both command forms say the same thing. Skipped entirely under commandOverride.

  extraArgs stays last so it can override anything above it -- SGLang's argparse
  takes the last occurrence of a repeated flag.
*/}}
{{- /* The flags the chart itself derives from the LWS environment at runtime --
       the only ones the multi-node shell may expand. */}}
{{- $expand := list }}
{{- $flags := list
      (printf "--model-path=%s" $root.Values.model.mountPath)
      (printf "--served-model-name=%s" $root.Values.model.name)
      "--host=0.0.0.0"
      (printf "--port=%v" $httpPort) }}
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
{{- /* The trio is only derived for a group that spans more than one node:
       every non-pd multi-node role, and pd roles whose own size >= 2. At a pd
       roleSize of 1 there is exactly one pod, so the flags would only restate
       what the engine already knows. */}}
{{- $trio := and $multi (or (not $pdRole) (gt (int ($roleCfg.size | default 1)) 1)) }}
{{- if $trio }}
{{- /*
  The three flags that make one SGLang instance span the group. They are derived,
  not configured: nnodes IS the group size (lws.size, or a pd role's own size;
  a group is the instance), the rank IS the pod's position in the group, and the
  rendezvous address IS the leader. Anything
  the chart cannot derive -- how those GPUs are carved up, i.e. --tp / --pp-size
  -- belongs in extraArgs, and the check in lws.yaml rejects restating these
  three there rather than letting two sources of truth disagree.

  ${LWS_WORKER_INDEX} and ${LWS_LEADER_ADDRESS} are injected into every pod of the
  group by the LWS controller; the leader is index 0 by definition, so it is
  written literally rather than read back from the env.
*/}}
{{- $flags = append $flags (printf "--nnodes=%v" (ternary $roleCfg.size $lws.size $pdRole)) }}
{{- $flags = append $flags (printf "--node-rank=%s" (ternary "${LWS_WORKER_INDEX}" "0" $worker)) }}
{{- $expand = append $expand (last $flags) }}
{{- $flags = append $flags (printf "--dist-init-addr=${LWS_LEADER_ADDRESS}:%v" (ternary ($roleCfg.distPort | default $lws.distPort) $lws.distPort $pdRole)) }}
{{- $expand = append $expand (last $flags) }}
{{- end }}
{{- if $pdRole }}
{{- /* The mooncake wiring every pd engine carries. The mode is the role; the
       bootstrap port is the role's own; and the ib-device comes from the env the
       rdma-injector chain populates on THIS node. Double-quoted so bash expands
       it -- passing the literal string would tell mooncake to open a device
       named after a shell variable, which fails inside ibv, not at parse time. */}}
{{- $flags = append $flags (printf "--disaggregation-mode=%s" (ternary "prefill" "decode" (hasPrefix "prefill-" $role))) }}
{{- $flags = append $flags (printf "--disaggregation-transfer-backend=%s" $root.Values.pd.transferBackend) }}
{{- $flags = append $flags (printf "--disaggregation-bootstrap-port=%v" ($roleCfg.bootstrapPort | default 8998)) }}
{{- $flags = append $flags "--disaggregation-ib-device=${MOONCAKE_IB_DEVICE}" }}
{{- $expand = append $expand (last $flags) }}
{{- end }}
{{- /* localKVOffload.backend=hicache: append --enable-hierarchical-cache when
       enabled, and every user-set knob under hicache: verbatim as
       --hicache-<key>=<value> (the values key IS the argv suffix, so
       'write-policy' maps to --hicache-write-policy). Knobs the user leaves
       null simply do not appear -- sglang's engine defaults apply.
       Compatibility between knobs is the engine's argparse/hook check,
       not the chart's. */}}
{{- $l2 := and $root.Values.localKVOffload.enabled (eq ($root.Values.localKVOffload.backend | default "") "hicache") }}
{{- if $l2 }}
{{- $flags = append $flags "--enable-hierarchical-cache" }}
{{- range $key, $val := $root.Values.localKVOffload.hicache }}
{{- /* kindIs-invalid means the key is missing entirely (unset). Anything
       else -- including 0 / 0.0 / "" -- is what the user set, and lands
       on the wire verbatim. Truthiness checks would silently eat the
       "disabled with 0" class of values. */}}
{{- if not (kindIs "invalid" $val) }}
{{- $flags = append $flags (printf "--hicache-%s=%v" $key $val) }}
{{- end }}
{{- end }}
{{- end }}
{{- /* toString, so a YAML-typed entry (`- 8` under `- --tp`) reaches the pod as
       the string the API server requires rather than an int it rejects. */}}
{{- range $root.Values.extraArgs }}
{{- $flags = append $flags (toString .) }}
{{- end }}
{{- /* Role extraArgs append AFTER the top-level ones, so a repeated flag lands
       last and wins -- SGLang takes the last occurrence. This is how a pd role
       overrides a shared flag without the chart deduping. */}}
{{- if $pdRole }}
{{- range ($roleCfg.extraArgs | default list) }}
{{- $flags = append $flags (toString .) }}
{{- end }}
{{- end -}}
{{- toYaml (dict
      "role" $role
      "roleCfg" $roleCfg
      "worker" $worker
      "serves" $serves
      "multi" $multi
      "pdRole" $pdRole
      "oc" $oc
      "pname" $pname
      "hwPort" $hwPort
      "httpPort" $httpPort
      "hasModel" $hasModel
      "override" $override
      "expand" $expand
      "flags" $flags
      "cacheEnabled" $cacheEnabled
      "cacheSuffix" $cacheSuffix
      "cacheBaseHostPath" $cacheBaseHostPath
      "cacheFullHostPath" $cacheFullHostPath) -}}
{{- end -}}

{{/*
  The engine's container list item, plus the hang-watcher sidecar that watches
  it. Consumes the identity dict from sglang.engineIdentity (one source of
  truth for the flags and the per-role ports). Emits list items ONLY -- no
  `containers:` key -- so the colocate template can interleave its router
  container between the two engines.

  Call it as:  include "sglang.engineContainers" (dict "root" $ "role" "prefill-leader" "roleCfg" $cfg "colocate" true)
*/}}
{{- define "sglang.engineContainers" -}}
{{- $root := .root }}
{{- $e := fromYaml (include "sglang.engineIdentity" .) }}
{{- $role := $e.role }}
{{- $roleCfg := $e.roleCfg }}
{{- $lws := $root.Values.lws }}
{{- $multi := $e.multi }}
{{- $pdRole := $e.pdRole }}
{{- $worker := $e.worker }}
{{- $serves := $e.serves }}
{{- $oc := $e.oc }}
{{- $pname := $e.pname }}
{{- $hwPort := $e.hwPort }}
{{- $httpPort := $e.httpPort }}
{{- $hasModel := $e.hasModel }}
{{- $override := $e.override }}
{{- $expand := $e.expand }}
{{- $flags := $e.flags }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- /* Host-level compile-cache management (see cache in values.yaml): when
       enabled, the engine command is wrapped in cache_manager.py, which leases
       a per-node slot and symlinks ~/.cache/sglang at it. Disabled under
       commandOverride, which owns the command line. */}}
{{- $cache := $root.Values.cache | default dict }}
{{- $cacheEnabled := and ($cache.enabled | default false) (not $override) }}
{{- /* /dev/shm: the chart mounts one unless the values already do. A user who
       mounts /dev/shm through volumeMounts keeps ownership of it -- emitting
       the chart's as well would put two mounts on the same path and the pod
       spec would be rejected. */}}
{{- $userShm := false }}
{{- range $root.Values.volumeMounts }}
{{- if eq (.mountPath | default "") "/dev/shm" }}{{ $userShm = true }}{{ end }}
{{- end }}
{{- $shmOn := and $root.Values.shm.enabled (not $userShm) }}
- name: sglang{{ $oc }}
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  {{- if $override }}
  {{- with $root.Values.commandOverride }}
  command:
    {{- range . }}
    - {{ toString . | quote }}
    {{- end }}
  {{- end }}
  {{- else if or $multi $pdRole }}
  # Shell form on purpose -- see the header of this file. `exec` keeps SGLang as
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
      {{- if $pdRole }}
      # The rdma-injector prepends `source /etc/gpu-node/nccl-ib.env`, so
      # NCCL_IB_HCA is already the healthy IB set on THIS node. Mooncake wants
      # the same answer; the flag below expands the env it is exported into.
      export MOONCAKE_IB_DEVICE="${NCCL_IB_HCA}"
      {{- end }}
      {{- if $cacheEnabled }}
      exec python3 /opt/sglang-cache/cache_manager.py -- \
        sglang serve{{ range $flags }} \
          {{ if has . $expand }}"{{ . }}"{{ else }}'{{ replace "'" "'\\''" . }}'{{ end }}{{ end }}
      {{- else }}
      exec sglang serve{{ range $flags }} \
        {{ if has . $expand }}"{{ . }}"{{ else }}'{{ replace "'" "'\\''" . }}'{{ end }}{{ end }}
      {{- end }}
  {{- else }}
  {{- if $cacheEnabled }}
  command: ["python3", "/opt/sglang-cache/cache_manager.py", "--", "sglang", "serve"]
  {{- else }}
  command: ["sglang", "serve"]
  {{- end }}
  args:
    {{- range $flags }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- /* Env is merged by sglang.mergeEnv: one entry per name, user value wins
       on collision. Order of $chartEnv is preserved verbatim by the merge
       helper, so the entries appear here in the same order the chart has
       always emitted them. */}}
  {{- /* false makes /health a plain status check. Left at SGLang's own
       default (true) it runs a real 1-token generation, sleeps at least 1s
       and can take 20s, which no sane probe timeout survives. */}}
  {{- $chartEnv := list
        (dict "name" "SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION" "value" (printf "%v" $root.Values.healthEndpointGeneration)) }}
  {{- /* Makes SGLang skip its drain and exit as soon as SIGTERM arrives.

       Both spellings, because upstream renamed it and the two live side by side
       across the images in use: 0.5.10 still reads SGL_FORCE_SHUTDOWN but warns
       ("deprecated, please use SGLANG_FORCE_SHUTDOWN"), and 0.5.15 has dropped it
       entirely -- grep the package and the string is not there, so on 0.5.15 the
       old name alone is a no-op and this whole switch does nothing. */}}
  {{- if $root.Values.lifecycle.forceShutdown }}
  {{- $chartEnv = concat $chartEnv (list
        (dict "name" "SGLANG_FORCE_SHUTDOWN" "value" "1")
        (dict "name" "SGL_FORCE_SHUTDOWN" "value" "1")) }}
  {{- end }}
  {{- /* The engine command runs under cache_manager.py (see the command forms
       above); these tune the host-side slot pool it manages. */}}
  {{- if $cacheEnabled }}
  {{- $chartEnv = concat $chartEnv (list
        (dict "name" "SGLANG_CACHE_HOST_DIR" "value" "/var/cache/sglang-host")
        (dict "name" "SGLANG_CACHE_TEMPLATE_HASH" "value" (include "sglang.cacheTemplateHash" $root))
        (dict "name" "SGLANG_CACHE_MAX_SLOTS" "value" (printf "%v" ($cache.maxSlotsPerNode | default 8)))
        (dict "name" "SGLANG_CACHE_HISTORY_LIMIT" "value" (printf "%v" ($cache.historyLimit | default 2)))) }}
  {{- end }}
  env:
  {{- include "sglang.mergeEnv" (dict "chart" $chartEnv "user" $root.Values.env "padding" 4) }}
  {{- if $serves }}
  ports:
  - containerPort: {{ $httpPort }}
    name: {{ $pname }}
  {{- end }}
  {{- /* rdma.enabled adds IPC_LOCK to whatever securityContext says, so the
         RDMA driver can pin its buffers (and the lws command form's
         `ulimit -l unlimited` actually takes). Added once, never duplicated. */}}
  {{- $sc := deepCopy ($root.Values.securityContext | default dict) }}
  {{- if and $root.Values.rdma.enabled (or $multi $pdRole) }}
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
  {{- if or $hasModel $cacheEnabled $root.Values.volumeMounts $shmOn }}
  volumeMounts:
  {{- if $hasModel }}
  - name: model-storage
    mountPath: {{ $root.Values.model.mountPath }}
    readOnly: true
  {{- end }}
  {{- if $cacheEnabled }}
  # The hostPath below carries the slot pool the cache manager leases from
  # (podSpec volumes); the configMap carries cache_manager.py itself.
  - name: host-cache
    mountPath: /var/cache/sglang-host
  - name: cache-manager-script
    mountPath: /opt/sglang-cache
    readOnly: true
  {{- end }}
  {{- if $shmOn }}
  - name: dshm
    mountPath: /dev/shm
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
  {{- /* In colocate a pd role's own gpus wins, so the two engines split one
         node's GPUs between them; unset or empty-string falls back to
         model.gpus. Detect set-ness with kindIs + toString, not with sprig
         `default`, because `default` treats integer 0 as empty and would
         silently rewrite `gpus: 0` to the fallback -- losing a GPU-less
         role. Outside colocate this is a no-op (roleCfg.gpus matches
         model.gpus). */}}
  {{- if and $pdRole (not (kindIs "invalid" $roleCfg.gpus)) (ne (toString $roleCfg.gpus) "") }}
  {{- $gpus = toString $roleCfg.gpus }}
  {{- end }}
  {{- if not (or (eq $gpus "") (eq $gpus "0")) }}
  {{- $res = mergeOverwrite (deepCopy $res) (dict "limits" (dict "nvidia.com/gpu" $gpus)) }}
  {{- end }}
  {{- /* rdma.enabled adds one RDMA device from the shared-device plugin
         (rdma/hca_shared), unless resources already asks for it -- the user's
         count stands. A null there counts as not asking: it is what a values
         overlay leaves behind when it removes a hand-written entry, and the
         point of such an overlay is to hand the job to this switch. */}}
  {{- if and $root.Values.rdma.enabled (or $multi $pdRole) }}
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
            {{- include "sglang.preStopScript" (dict "root" $root "serves" $serves "kill" (ternary $lws.leaderPreStopKill $root.Values.lifecycle.preStopKill $multi) "httpPort" $httpPort "hwPort" $hwPort) | nindent 14 }}
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
    {{- if $pdRole }}
    {{- include "sglang.probeOnPort" (dict "probe" . "port" $pname) | nindent 4 }}
    {{- else }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- with $root.Values.readinessProbe }}
  readinessProbe:
    {{- if $pdRole }}
    {{- include "sglang.probeOnPort" (dict "probe" . "port" $pname) | nindent 4 }}
    {{- else }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- if $root.Values.hangWatcher.enabled }}
  # hang-watcher owns liveness: probe the sidecar's /healthz on the shared
  # pod network; a 503 (hang) restarts THIS container. Replaces the
  # /health_generate check -- see hangWatcher in values.yaml for why.
  livenessProbe:
    httpGet:
      path: /healthz
      port: {{ $hwPort }}
    {{- with $root.Values.hangWatcher.livenessProbe }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- else }}
  {{- with $root.Values.livenessProbe }}
  livenessProbe:
    {{- if $pdRole }}
    {{- include "sglang.probeOnPort" (dict "probe" . "port" $pname) | nindent 4 }}
    {{- else }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
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
- name: hang-watcher{{ $oc }}
  image: "{{ $root.Values.hangWatcher.image.repository }}:{{ $root.Values.hangWatcher.image.tag }}"
  env:
  - name: ENGINE_URL
    value: "http://127.0.0.1:{{ $httpPort }}"
  - name: LISTEN
    value: ":{{ $hwPort }}"
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
    value: "/var/log/pods/$(POD_NS)_$(POD_NAME)_*/sglang{{ $oc }}/*.log"
  {{- with (($root.Values.hangWatcher.config).logHang | default dict).patterns }}
  {{- /* Join the list into one RE2 alternation. Each entry is wrapped in (?:...)
         so an entry that itself contains `|` stays self-contained instead of
         merging with the next one. Empty list -> env omitted -> sidecar default. */}}
  - name: LOG_HANG_PATTERN
    value: {{ (printf "(?:%s)" (join ")|(?:" .)) | quote }}
  {{- end }}
  {{- end }}
  ports:
  - containerPort: {{ $hwPort }}
    name: hang-hz{{ $oc }}
  {{- with $root.Values.hangWatcher.readinessProbe }}
  # Readiness on the sidecar itself: a hang verdict drops the POD out of the Service (an endpoint
  # needs every container ready), so traffic stops arriving before the kill/drain even starts.
  # The engine's own /v1/models readiness is untouched and still applies -- see values.yaml.
  readinessProbe:
    httpGet:
      path: /healthz
      port: {{ $hwPort }}
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
{{- end -}}

{{- define "sglang.podSpec" -}}
{{- $root := .root }}
{{- /* /dev/shm: the chart mounts one unless the values already do. A user who
       mounts /dev/shm through volumeMounts keeps ownership of it -- emitting
       the chart's as well would put two mounts on the same path and the pod
       spec would be rejected. */}}
{{- $userShm := false }}
{{- range $root.Values.volumeMounts }}
{{- if eq (.mountPath | default "") "/dev/shm" }}{{ $userShm = true }}{{ end }}
{{- end }}
{{- $shmOn := and $root.Values.shm.enabled (not $userShm) }}
{{- /* A values file may already use the name this chart gives its /dev/shm
       volume, for something else entirely. Two volumes cannot share a name, so
       say so here rather than let the API server reject the pod with a message
       that does not mention this chart. */}}
{{- if $shmOn }}
{{- range $root.Values.volumes }}
{{- if eq (.name | default "") "dshm" }}
{{- fail "volumes has an entry named \"dshm\", which is the name this chart gives the /dev/shm volume it adds by default. Rename that entry, or mount it at /dev/shm (the chart then leaves it alone), or set shm.enabled: false." }}
{{- end }}
{{- end }}
{{- end }}
{{- /* Colocate always renders the merged Deployment (pd-colocate.yaml); podSpec
       is the one-engine pod, so it is always the non-colocate identity. */}}
{{- $e := fromYaml (include "sglang.engineIdentity" (dict "root" $root "role" .role "roleCfg" (.roleCfg | default dict) "colocate" false)) }}
{{- $role := $e.role }}
{{- $roleCfg := $e.roleCfg }}
{{- $lws := $root.Values.lws }}
{{- $multi := $e.multi }}
{{- $pdRole := $e.pdRole }}
{{- $worker := $e.worker }}
{{- $serves := $e.serves }}
{{- $oc := $e.oc }}
{{- $pname := $e.pname }}
{{- $hwPort := $e.hwPort }}
{{- $httpPort := $e.httpPort }}
{{- $hasModel := $e.hasModel }}
{{- $override := $e.override }}
{{- $cacheEnabled := $e.cacheEnabled }}
{{- $cacheFullHostPath := $e.cacheFullHostPath }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- /* Shutdown budget: preStop + SGLang's post-SIGTERM drain, checked by
       sglang.shutdownBudget. Workers get their own, because they drain nothing
       and their whole group is being deleted with them -- a long grace only
       holds GPUs until the kubelet's SIGKILL. */}}
{{- $grace := $root.Values.terminationGracePeriodSeconds }}
{{- /* 0 is a real value (SIGKILL at once -- a worker drains nothing); only
       empty or null means "same as the leader's". */}}
{{- $wg := $lws.workerTerminationGracePeriodSeconds }}
{{- if and $worker (not (kindIs "invalid" $wg)) (ne (toString $wg) "") }}
{{- $grace = $wg }}
{{- end }}
terminationGracePeriodSeconds: {{ $grace }}
{{- /* Workers wait for the leader's rendezvous port; leaders wait for nothing.
       A pd size-1 role has no group to rendezvous with, so its sole pod waits
       for nothing either. */}}
{{- $waitLeader := and $worker $lws.waitForLeader (or (not $pdRole) (gt (int ($roleCfg.size | default 1)) 1)) }}
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
      {{- /* Under pd a role can override distPort; the wait has to hit the same
             port --dist-init-addr pointed at, not the lws-wide default. Outside
             pd this falls back to lws.distPort, matching pre-pd renders. */}}
      port={{ $roleCfg.distPort | default $lws.distPort }}
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
{{- include "sglang.engineContainers" (dict "root" $root "role" .role "roleCfg" (.roleCfg | default dict) "colocate" false) }}
{{- $hangVol := and $root.Values.hangWatcher.enabled $serves }}
{{- if or $hasModel $hangVol $cacheEnabled $root.Values.volumes $shmOn }}
volumes:
{{- if $shmOn }}
- name: dshm
  emptyDir:
    medium: Memory
    sizeLimit: {{ $root.Values.shm.sizeLimit }}
{{- end }}
{{- if $hasModel }}
- name: model-storage
  hostPath:
    path: {{ $root.Values.model.localPath }}
    type: {{ $root.Values.model.hostPathType }}
{{- end }}
{{- if $cacheEnabled }}
- name: host-cache
  hostPath:
    path: {{ $cacheFullHostPath }}
    type: DirectoryOrCreate
- name: cache-manager-script
  configMap:
    name: {{ include "sglang.fullname" $root }}-cache-manager
    defaultMode: 0755
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
{{- if $root.Values.hostNetwork }}
hostNetwork: true
{{- end }}
{{- with (ternary "ClusterFirstWithHostNet" $root.Values.dnsPolicy (and $root.Values.hostNetwork (not $root.Values.dnsPolicy))) }}
dnsPolicy: {{ . }}
{{- end }}
{{- /* A pd role's schedulerName / affinity fully REPLACES the top-level one
       (never merges): the two roles of a PD set often need to land on different
       GPU products, which affinities cannot express by union. NodeSelector gets
       no per-role override -- flat maps do not compose, and per-role nodeSelector
       degenerates into per-node pinning. */}}
{{- $sched := $root.Values.schedulerName }}
{{- if and $pdRole ($roleCfg.schedulerName | default "") }}
{{- $sched = $roleCfg.schedulerName }}
{{- end }}
{{- with $sched }}
schedulerName: {{ . }}
{{- end }}
{{- with $root.Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with $root.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- $aff := $root.Values.affinity }}
{{- if and $pdRole (not (kindIs "invalid" $roleCfg.affinityReplace)) ($roleCfg.affinityReplace) }}
{{- $aff = $roleCfg.affinityReplace }}
{{- end }}
{{- with $aff }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* The accelerator taint is tolerated by ADDING to the user's list, not by
       defaulting the list itself: Helm replaces lists, so a values file that
       sets `tolerations` would silently lose this entry and the engine would
       stop being schedulable on its own tainted nodes. A user entry for the
       same key wins, which is also how to narrow it (tolerate only
       value=compute-only, say). There is deliberately no on/off switch: the
       only thing one would add is no toleration at all, and a GPU engine has
       no use for that. */}}
{{- $tols := default (list) $root.Values.tolerations }}
{{- $hasGpuTol := false }}
{{- range $tols }}
{{- if eq (.key | default "") "nvidia.com/gpu" }}{{- $hasGpuTol = true }}{{- end }}
{{- end }}
{{- if not $hasGpuTol }}
{{- $tols = concat (list (dict "key" "nvidia.com/gpu" "operator" "Exists" "effect" "NoSchedule")) $tols }}
{{- end }}
{{- with $tols }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
  Rewrite a probe's httpGet.port onto a numeric port. pd roles serve on their
  own httpPort, so a probe values.yaml wrote against the default `http` name /
  service.port has to be pointed at the role's port. Everything else in the
  probe passes through unchanged. Non-pd callers never invoke this.
*/}}
{{- define "sglang.probeOnPort" -}}
{{- $probe := deepCopy .probe }}
{{- if hasKey $probe "httpGet" }}
{{- $hg := deepCopy $probe.httpGet }}
{{- $_ := set $hg "port" .port }}
{{- $_ := set $probe "httpGet" $hg }}
{{- end }}
{{- toYaml $probe }}
{{- end -}}

{{/*
  The pd router's readiness chain: only report the router as Ready when
  every engine role has at least one reachable upstream. The probe calls
  /health not /health_generate: the deep signal (wedged scheduler) is
  already enforced by each engine's own readinessProbe on /health_generate
  plus the hang-watcher sidecar, and here it would cost an engine ~1s of
  scheduler time per tick per router copy -- the chart already spends
  that once per tick on the engine's own readinessProbe. What this probe
  needs to answer is narrower: "is at least one engine process behind
  this router alive and taking HTTP", because during model load /health
  fails (the engines' own 90-min startup budget exists precisely because
  /health is unanswerable while loading), and after load it answers in
  ~3ms. Probe the engines directly, never the router's own port: asking
  the router cannot answer the question either -- a router holding a
  dead upstream list keeps its port open just the same.

  Known gap this does not close: after engines are healthy, a wedged
  scheduler keeps serving /health 200 from cached frontend state, and
  the headless Services publish not-ready addresses -- so a
  post-startup wedge is invisible to this probe. Hang-watcher owns
  that failure mode (it restarts the engine), and the new engine's IP
  eventually goes stale in the router's argv -- the staleness
  self-healing PR addresses that layer.

  Caller passes a dict role -> {host, port}:
    A/B      the slice's per-role headless FQDN -- script resolves every
             A-record IP and passes on the first 200.
    colocate 127.0.0.1 -- literal, skips resolution.
  Same probe spec, same shape both ways.

  Emits startupProbe and readinessProbe back-to-back at the caller's
  indent. startupProbe carries the engines' 90-minute load budget so a
  router pod scheduled before its engines have loaded is not
  liveness-restarted. readinessProbe ticks at 30s because each call
  costs an engine, even a shallow one -- the engines' own probes can
  afford 10s because the kubelet runs them; doubling the cadence by
  stacking a router copy on top is money for no signal.
*/ -}}
{{- define "sglang.pdRouterProbes" -}}
{{- $roles := .roles -}}
startupProbe:
  exec:
    command: ["bash", "-lc", {{ include "sglang.pdRouterProbeScript" (dict "roles" $roles) | quote }}]
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 180           # 180 x 30s = 90 minutes -- the engines' load budget
readinessProbe:
  exec:
    command: ["bash", "-lc", {{ include "sglang.pdRouterProbeScript" (dict "roles" $roles) | quote }}]
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
{{- end -}}

{{- define "sglang.pdRouterProbeScript" -}}
{{- $roles := .roles -}}
set -u
check() {
  local src=$1 port=$2
  # A name (any non-numeric character in src) -> resolve via DNS and try each.
  # Dotted-quad literal -> probe directly, no resolution step. python3 +
  # urllib, never curl or wget: the SGLang image ships neither (see the
  # preStop drain hook for the same constraint).
  case "$src" in
    *[!0-9.]*)
      for ip in $(getent hosts "$src" | awk '{print $1}' | sort -u); do
        python3 -c "import urllib.request; urllib.request.urlopen('http://$ip:$port/health', timeout=5)" >/dev/null 2>&1 && return 0
      done
      return 1
      ;;
    *)
      python3 -c "import urllib.request; urllib.request.urlopen('http://$src:$port/health', timeout=5)" >/dev/null 2>&1
      ;;
  esac
}
{{- range $role, $target := $roles }}
check {{ $target.host | quote }} {{ $target.port | quote }} || { echo "router not ready: role {{ $role }} has no reachable upstream" >&2; exit 1; }
{{- end }}
exit 0
{{- end -}}

{{- /* Liveness probe for the DisaggregatedSet router -- detects upstream-set
       drift. Strategy: restart on GROWTH only. getent re-resolves the slice
       headless Service on every tick; any IP it returns that was not baked
       into router argv at boot (recorded in /run/pd-router/<role>-ips by
       the boot script) means a new upstream appeared and the running router
       can never learn about it. Shrinkage is intentionally silent -- the
       router's own health checker already quarantines dead URLs, and
       crashing on shrinkage would crash-loop the router on a permanent,
       intentional scale-down. Missing argv-file is tolerated (pod still
       in boot loop).

       Cadence: 10s period, 2 failures = 20s of sustained drift before
       restart. Tight because false positives are essentially impossible
       (the headless Service selector is locked to this slice's leaders)
       and late detection costs real capacity. Drop straight in as the
       router container's livenessProbe; pair with the readinessProbe from
       sglang.pdRouterProbes -- separate concerns. */ -}}
{{- define "sglang.pdRouterLivenessProbe" -}}
{{- $roles := .roles -}}
livenessProbe:
  exec:
    command: ["bash", "-lc", {{ include "sglang.pdRouterLivenessProbeScript" (dict "roles" $roles) | quote }}]
  periodSeconds: 10
  timeoutSeconds: 10
  failureThreshold: 2
{{- end -}}

{{- define "sglang.pdRouterLivenessProbeScript" -}}
{{- $roles := .roles -}}
set -u
rc=0
check() {
  local role=$1 svc=$2 file="/run/pd-router/$3" port=$4
  [ -f "$file" ] || return 0
  local ip
  while read -r ip; do
    [ -n "$ip" ] || continue
    grep -qx "$ip" "$file" && continue
    # New IP not in argv. Only count drift once it is actually SERVING:
    # restarting into a still-loading engine is wasted (router can't route
    # to it) and on engines whose router blocks its own listener on a
    # per-upstream bootstrap handshake (vllm + mooncake), is actively
    # harmful -- the whole slice sits dark until the retry budget drains.
    # Short timeout so a slow engine never stalls the probe itself.
    if python3 -c "import urllib.request; urllib.request.urlopen('http://$ip:$port/health', timeout=2)" 2>/dev/null; then
      echo "router stale: $role upstream $ip serving but not in argv" >&2
      rc=1
    fi
  done < <(timeout 2 getent hosts "$svc" 2>/dev/null | awk '{print $1}' | sort -u)
  # If timeout(1) kills getent (124 = resolver blip), the awk|sort pipeline
  # emits empty input, the while loop never fires, rc stays 0 -- a CoreDNS
  # flake is treated as "no data", not "drift". Restarting every PD router
  # cluster-wide because of a 2s resolver stall would be the biggest self-
  # inflicted DoS the chart could ship.
}
{{- range $role, $target := $roles }}
check {{ $role | quote }} {{ $target.host | quote }} {{ $role }}-ips {{ $target.port | quote }}
{{- end }}
exit $rc
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
{{- /* pd roles serve on their own port; empty httpPort falls back to
       service.port, keeping the non-pd drain unchanged. */ -}}
{{- $httpPort := .httpPort | default $root.Values.service.port -}}
{{- $hwPort := .hwPort | default $root.Values.hangWatcher.port -}}
import time, urllib.request, urllib.error{{ if .kill }}, os, signal{{ end }}

METRICS = "http://127.0.0.1:{{ $httpPort }}/metrics"
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


HEALTHZ = "http://127.0.0.1:{{ $hwPort }}/healthz"


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
