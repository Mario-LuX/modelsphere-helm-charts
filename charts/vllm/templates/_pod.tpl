{{/*
  The pod spec every vLLM pod in this chart shares.

  There are three of them and they differ far less than they look:

    single   the Deployment's pod -- one node, serves traffic.
    leader   rank 0 of a LeaderWorkerSet group -- serves traffic AND drives the
             cross-node NCCL group.
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
      exec form (no shell). Multi-node pods need a shell, for two reasons
      that both matter:
        * --node-rank has to come from ${LWS_WORKER_INDEX} at runtime.
        * the rdma-injector webhook only prepends its
          `source /etc/gpu-node/nccl-ib.env` (the per-node NCCL_IB_HCA pipeline)
          to containers started as bash/sh -c. An exec-form container gets the
          hostPath mount and nothing else -- RDMA then silently falls back to
          the wrong HCA rather than failing.
      Neither form is built under commandOverride, which also frees
      model.localPath and model.gpus to be empty (see values.yaml).
    - --nnodes / --node-rank / --master-addr / --master-port /
      --distributed-executor-backend, added only for lws roles (and pd roles
      whose own size >= 2), plus --headless on workers.
    - probes, the hang-watcher sidecar and the container port: `serves` roles
      only. There is nothing listening on a worker to probe.
    - preStop: see vllm.preStopScript.

  Call it as:  include "vllm.podSpec" (dict "root" $ "role" "leader")

  The work is split into three defines so the pd colocate shape can put TWO
  engines (and two hang-watchers) into ONE pod without copying the engine
  container:

    vllm.engineIdentity   turns a role into everything the engine command and
                          its probes/preStop need -- the flags, the pd trio,
                          the colocate port-name offset -- as a YAML dict, so
                          a caller two hundred lines away reads ONE source of
                          truth instead of re-deriving it. Renders nothing on
                          its own; the dict is the whole output.
    vllm.engineContainers the engine's container list item, plus the
                          hang-watcher sidecar that watches it. Consumes the
                          identity dict. Emits list items only (no
                          `containers:` key) so colocate can interleave its
                          router container.
    vllm.podSpec          the whole one-engine pod: prologue, the identity,
                          initContainers, `containers:` + engineContainers,
                          then the volumes/scheduling scaffold.
*/}}
{{- define "vllm.engineIdentity" -}}
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
{{- /* A pd role's worker is "headless" in vllm parlance. The --headless flag
       below is added iff the role is a worker. The colocate shape never
       renders workers at all (size=1 by guard). */}}
{{- /* Colocate-only identity: in the merged pod the two engine containers and
       their hang-watchers must not share a container name or a
       side-channel port. Decode is the offset side (idx/oc "1"); prefill
       keeps the plain names. Empty in every one-engine pod, so non-colocate
       renders are unchanged. */}}
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
{{- /* Per-role nixl ports come from the role's nixl block; defaults from
       values.yaml diverge between prefill (5561/5597) and decode (5562/5598)
       so colocate needs nothing special. For non-pd renders these arenever
       read. */}}
{{- $nixl := dict }}
{{- if $pdRole }}{{ $nixl = $pobj.nixl | default dict }}{{ end }}
{{- $nixlScPort := ternary (int ($nixl.sideChannelPort | default 5561)) 0 $pdRole }}
{{- $nixlHttpPort := ternary (int ($nixl.httpPort | default 5597)) 0 $pdRole }}
{{- $nixlBackends := ternary ($nixl.backends | default (list "UCX")) (list) $pdRole }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- /* Defined -- including as [] -- takes the container over, and nothing below
       is built. [] renders no command at all: the image's ENTRYPOINT. */}}
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
      (printf "--port=%v" $httpPort) }}
{{- /* Without this flag vLLM leaves usage.prompt_tokens_details out of every
       response, so cached_tokens is absent rather than zero. The gateway's
       request log reads that field, which means a deployment that forgets the
       flag loses cached-token accounting for the entire chain while the engine
       goes on caching normally -- nothing reports an error, the number is just
       never there. Default on because it costs nothing; promptTokensDetails:
       false is for an engine image whose argparse does not know the flag, which
       would otherwise refuse to start. */}}
{{- if $root.Values.promptTokensDetails }}
{{- $flags = append $flags "--enable-prompt-tokens-details" }}
{{- end }}
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
{{- /* The trio is only derived for a group that spans more than one node:
       every non-pd multi-node role, and pd roles whose own size >= 2. At a
       pd roleSize of 1 there is exactly one pod, so the flags would only
       restate what the engine already knows. */}}
{{- $trio := and $multi (or (not $pdRole) (gt (int ($roleCfg.size | default 1)) 1)) }}
{{- if $trio }}
{{- /*
  The flags that make one vLLM instance span the group. They are derived, not
  configured: nnodes IS the group size (lws.size, or a pd role's own size;
  a group is the instance), the rank IS the pod's position in the group, and
  the rendezvous address IS the leader. Anything the chart cannot derive --
  how those GPUs are carved up, i.e. --tensor-parallel-size /
  --pipeline-parallel-size -- belongs in extraArgs, and the check in
  pd-guards / lws.yaml rejects restating these there rather than letting two
  sources of truth disagree.

  ${LWS_WORKER_INDEX} and ${LWS_LEADER_ADDRESS} are injected into every pod of
  the group by the LWS controller; the leader is index 0 by definition, so it
  is written literally rather than read back from the env.

  mp, not Ray: the multiprocessing executor spans nodes by itself, so there is
  no Ray cluster to stand up in front of vLLM. Spelled out because vLLM picks
  Ray on its own when the world size exceeds the node's GPUs.
*/}}
{{- $flags = append $flags "--distributed-executor-backend=mp" }}
{{- $flags = append $flags (printf "--nnodes=%v" (ternary $roleCfg.size $lws.size $pdRole)) }}
{{- $flags = append $flags (printf "--node-rank=%s" (ternary "${LWS_WORKER_INDEX}" "0" $worker)) }}
{{- $expand = append $expand (last $flags) }}
{{- $flags = append $flags "--master-addr=${LWS_LEADER_ADDRESS}" }}
{{- $expand = append $expand (last $flags) }}
{{- $flags = append $flags (printf "--master-port=%v" (ternary ($roleCfg.distPort | default $lws.distPort) $lws.distPort $pdRole)) }}
{{- if $worker }}
{{- $flags = append $flags "--headless" }}
{{- end }}
{{- end }}
{{- /* --kv-transfer-config is emitted when EITHER the engine is a pd role
       (the PD transfer connector is chart-derived from pd.<role>.<backend>.*)
       OR localKVOffload is on (MooncakeStoreConnector alone or wrapped with
       the PD connector). The two axes are independent; recent history had
       them coupled under pd.*, which was wrong -- l2 is an engine feature,
       not a pd feature. Combinations:

         pd off, l2 off     -> no flag at all (a plain vLLM engine).
         pd off, l2 on      -> MooncakeStoreConnector alone (plain
                               single-connector flag, no MultiConnector).
         pd on,  l2 off     -> NixlConnector or MooncakeConnector alone (the
                               pd.transferBackend-driven behavior).
         pd on,  l2 on      -> ONE MultiConnector wrapping [chart-derived PD
                               connector, MooncakeStoreConnector] emitted as
                               a single --kv-transfer-config.

       The store connector's extra_config is hard-coded
       ({load_async,lookup_async}=true -- the only values the reference
       deploy has been validated on); the connector's own knobs are
       snake_case wire keys and the chart deliberately does not enumerate
       them. */}}
{{- $pdKvCfg := "" }}
{{- if $pdRole }}
{{- /* The connector wiring every pd engine carries. kv_role is "kv_both"
       on both engines -- vLLM 0.24 has deprecated producer/consumer-split
       roles, and kv_both works symmetrically in both directions. The role
       (prefill vs decode) is implicit: it is whichever side the router pairs
       on a given request, not a flag the engine reads. The JSON is chart-
       derived from pd.<role>.<backend>.* and goes into the flag list BEFORE
       any user extraArgs, so a user's own --kv-transfer-config (e.g. for an
       L2-cache multi-connector config) can override it last-wins. */}}
{{- $backend := $root.Values.pd.transferBackend | default "nixl" }}
{{- if eq $backend "mooncake" }}
{{- /* MooncakeConnector.__init__ reads snake_case keys out of
       kv_connector_extra_config and drops unknown keys silently -- no
       validation. The keys it actually reads at vllm 0.30 are
       mooncake_protocol, device_name, num_workers. We also emit
       http_port, which the connector ignores at 0.30 (only
       moriio_connector.py reads it at that tag) -- kept in the JSON body
       so the wire shape stays nixl-compatible and is forward-compatible
       if a future connector release starts reading it. Chart values stay
       camelCase (see values.schema.json#definitions.pdRole.mooncake) so
       the template keeps the chart/wire rename in one place. Connector
       defaults (mooncake_connector.py:950-970): protocol="rdma",
       num_workers=10, device_name="". Match them below so an unset value
       on the chart produces the same engine behaviour as a user-set
       default; this matters because the mooncake gotcha was the engine
       silently running on defaults while looking tuned. */}}
{{- $mc := $pobj.mooncake | default dict }}
{{- $mcExtra := dict
      "http_port"         ($mc.httpPort         | default $nixlHttpPort)
      "mooncake_protocol" ($mc.protocol         | default "rdma")
      "num_workers"       ($mc.numSenderWorkers | default 10) }}
{{- with $mc.deviceName }}{{ $mcExtra = set $mcExtra "device_name" . }}{{ end }}
{{- $pdKvCfg = printf `{"kv_connector":"MooncakeConnector","kv_role":"kv_both","kv_connector_extra_config":%s}` ($mcExtra | mustToJson) }}
{{- else }}
{{- $backendsJson := "[" }}{{ range $i, $b := $nixlBackends }}{{ if $i }}{{ $backendsJson = printf "%s," $backendsJson }}{{ end }}{{ $backendsJson = printf "%s%q" $backendsJson $b }}{{ end }}{{ $backendsJson = printf "%s]" $backendsJson }}
{{- $pdKvCfg = printf `{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_connector_extra_config":{"backends":%s,"http_port":%d}}` $backendsJson $nixlHttpPort }}
{{- end }}
{{- end }}
{{- /* The store connector entry, plain. Emitted solo for pd-less offload,
       or wrapped with the PD connector in MultiConnector for pd+offload. */}}
{{- $l2 := and $root.Values.localKVOffload.enabled (eq ($root.Values.localKVOffload.backend | default "") "mooncakeStore") }}
{{- $storeKvCfg := `{"kv_connector":"MooncakeStoreConnector","kv_role":"kv_both","kv_connector_extra_config":{"load_async":true,"lookup_async":true}}` }}
{{- if or $pdRole $l2 }}
{{- $out := $pdKvCfg }}
{{- if $l2 }}
{{- if $pdRole }}
{{- $out = printf `{"kv_connector":"MultiConnector","kv_role":"kv_both","kv_connector_extra_config":{"connectors":[%s,%s]}}` $pdKvCfg $storeKvCfg }}
{{- else }}
{{- $out = $storeKvCfg }}
{{- end }}
{{- end }}
{{- $flags = append $flags (printf "--kv-transfer-config=%s" $out) }}
{{- end }}
{{- /* toString, so a YAML-typed entry (`- 2` under `- --tensor-parallel-size`)
       reaches the pod as the string the API server requires rather than an int
       it rejects. */}}
{{- range $root.Values.extraArgs }}
{{- $flags = append $flags (toString .) }}
{{- end }}
{{- /* Role extraArgs append AFTER the top-level ones, so a repeated flag lands
       last and wins -- vLLM takes the last occurrence. This is also how a
       user's own --kv-transfer-config can override the chart-derived one
       above without the chart deduplicating. */}}
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
      "nixlScPort" $nixlScPort
      "nixlHttpPort" $nixlHttpPort
      "hasModel" $hasModel
      "override" $override
      "expand" $expand
      "l2" $l2
      "flags" $flags) -}}
{{- end -}}

{{/*
  The engine's container list item, plus the hang-watcher sidecar that watches
  it. Consumes the identity dict from vllm.engineIdentity (one source of truth
  for the flags and the per-role ports). Emits list items ONLY -- no
  `containers:` key -- so the colocate template can interleave its router
  container between the two engines.

  Call it as:  include "vllm.engineContainers" (dict "root" $ "role" "prefill-leader" "roleCfg" $cfg "colocate" true)
*/}}
{{- define "vllm.engineContainers" -}}
{{- $root := .root }}
{{- $e := fromYaml (include "vllm.engineIdentity" .) }}
{{- $role := $e.role }}
{{- $roleCfg := $e.roleCfg }}
{{- $lws := $root.Values.lws }}
{{- $multi := $e.multi }}
{{- $pdRole := $e.pdRole }}
{{- $worker := $e.worker }}
{{- $serves := $e.serves }}
{{- /* Engine container-side L2 side-effects (env + volumeMount) come from
       the identity dict, not re-derived here -- one derivation, one truth.
       Gated on L2 being ON; the colocate render's merged pod bypasses
       podSpec's volume plumbing entirely and mc-guards rejects the
       combination upstream, so this branch never fires under colocate. */}}
{{- $l2 := $e.l2 }}
{{- $oc := $e.oc }}
{{- $pname := $e.pname }}
{{- $hwPort := $e.hwPort }}
{{- $httpPort := $e.httpPort }}
{{- $nixlScPort := $e.nixlScPort }}
{{- $nixlHttpPort := $e.nixlHttpPort }}
{{- $hasModel := $e.hasModel }}
{{- $override := $e.override }}
{{- $expand := $e.expand }}
{{- $flags := $e.flags }}
{{- $preStop := $root.Values.lifecycle.preStop }}
{{- /* /dev/shm: the chart mounts one unless the values already do. A user who
       mounts /dev/shm through volumeMounts keeps ownership of it -- emitting
       the chart's as well would put two mounts on the same path and the pod
       spec would be rejected. */}}
{{- $userShm := false }}
{{- range $root.Values.volumeMounts }}
{{- if eq (.mountPath | default "") "/dev/shm" }}{{ $userShm = true }}{{ end }}
{{- end }}
{{- $shmOn := and $root.Values.shm.enabled (not $userShm) }}
{{- /* Colocate diverges from the other shapes: cross-node NIXL needs IB
       (and therefore rdma/hca_shared + IPC_LOCK + the rdma-ib label's
       NCCL_IB_HCA env); same-pod NIXL over cuda_ipc does not. .colocate is
       the caller's signal that this engine container is going inside the
       merged pod. */}}
{{- $colocate := .colocate | default false }}
{{- $needsRdma := and $root.Values.rdma.enabled (or $multi (and $pdRole (not $colocate))) }}
- name: vllm{{ $oc }}
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  {{- if $override }}
  {{- with $root.Values.commandOverride }}
  command:
    {{- range . }}
    - {{ toString . | quote }}
    {{- end }}
  {{- end }}
  {{- else if or $multi $pdRole }}
  # Shell form on purpose -- see the header of this file. `exec` keeps vLLM as
  # PID 1, which SIGTERM handling and the leader preStop below both depend on.
  #
  # ulimit -l lifts the locked-memory cap so the RDMA driver can pin its
  # buffers; without it NCCL falls back to a slower path or fails outright on
  # an IB fabric. Guarded, because a container without CAP_IPC_LOCK cannot
  # raise it and that is not a reason to refuse to start.
  #
  # Every flag reaches the engine exactly as written. The ones the chart
  # derives from the LWS environment (the rank and the leader's address) are
  # double-quoted so bash expands their ${...}; everything else -- extraArgs
  # included -- is single-quoted with any ' inside escaped, so spaces, quotes,
  # $ and JSON survive the trip through bash untouched, the same as in the
  # single-pod exec form. To reference the container's env from extraArgs,
  # use Kubernetes' $(VAR) syntax: the kubelet expands it in either form.
  #
  # extraInitShell runs in the same shell between `ulimit` and `exec`. It is
  # the only place a pod can run arbitrary bash before vLLM takes over -- the
  # GLOO_SOCKET_IFNAME auto-detect loop needed on hostNetwork is the canonical
  # example (finding the NIC that owns the pod's 172.28.x.x IP would otherwise
  # require commandOverride, which forfeits every chart-derived flag). The
  # block is inserted verbatim, so anything exported here -- including
  # overridden ${LWS_LEADER_ADDRESS} -- is visible when the flags below are
  # expanded.
  command: ["bash", "-lc"]
  args:
    - |
      ulimit -l unlimited 2>/dev/null || true
  {{- with $root.Values.extraInitShell }}
      {{ . | nindent 6 | trim }}
  {{- end }}
      exec vllm serve{{ range $flags }} \
        {{ if has . $expand }}"{{ . }}"{{ else }}'{{ replace "'" "'\\''" . }}'{{ end }}{{ end }}
  {{- else }}
  command: ["vllm", "serve"]
  args:
    {{- range $flags }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- /* Env is merged by vllm.mergeEnv: one entry per name, user value wins
       on collision. Chart's pd-only entries are load-bearing for NixlConnector
       and torch; users overriding them take responsibility for the connector
       coming up. */}}
  {{- $engineEnv := list }}
  {{- if $pdRole }}
  {{- /* THE load-bearing env for vllm pd. The NIXL handshake embeds this pod's
         IP into kv_transfer_params.remote_host, which the peer DIALS. status.podIP
         via the downward API is the only correct source -- 0.0.0.0 makes the
         peer bind-listen successfully but then accept traffic only on the pod's
         own netns (so cross-pod gets zmq.error.Again), and "localhost" is
         unreachable across pods by definition. Never ship a static value here. */}}
  {{- $engineEnv = concat $engineEnv (list
        (dict "name" "VLLM_NIXL_SIDE_CHANNEL_HOST" "valueFrom" (dict "fieldRef" (dict "fieldPath" "status.podIP")))
        (dict "name" "VLLM_NIXL_SIDE_CHANNEL_PORT" "value" (printf "%v" $nixlScPort))
        (dict "name" "TORCH_DISABLE_ADDR2LINE" "value" "1")
        (dict "name" "NVIDIA_DISABLE_REQUIRE" "value" "1")
        (dict "name" "VLLM_USE_V1" "value" "1")
        (dict "name" "VLLM_LOGGING_LEVEL" "value" "INFO")) }}
  {{- /* UCX_TLS: which transports NIXL's UCX backend may pick. Colocate has
         no IB in its pod netns, so rc_verbs would fail at createBackend --
         least-dangerous known-good list is "tcp,self,cuda_copy,cuda_ipc"
         (TCP for the AM/control path, cuda_ipc for VRAM bulk transfer over
         NVLink). Cross-node pods have IB, so "all" lets UCX pick rc_verbs
         when it is healthy. */}}
  {{- if $colocate }}
  {{- $engineEnv = concat $engineEnv (list
        (dict "name" "UCX_TLS" "value" "tcp,self,cuda_copy,cuda_ipc")
        (dict "name" "NCCL_IB_DISABLE" "value" "1")) }}
  {{- else }}
  {{- $engineEnv = concat $engineEnv (list
        (dict "name" "UCX_TLS" "value" "all")
        (dict "name" "UCX_NET_DEVICES" "value" "all")
        (dict "name" "NCCL_IB_DISABLE" "value" "0")
        (dict "name" "NCCL_DEBUG" "value" "WARN")) }}
  {{- end }}
  {{- /* MOONCAKE_CONFIG_PATH: where the MooncakeStoreConnector reads its
         per-instance JSON. Chart-set when the offload is on so the values
         file only carries the shape knobs and not the delivery plumbing.
         Placed BEFORE the user's top-level env, which is appended after and
         wins on any duplicate name (Kubernetes env is last-wins). */}}
  {{- if $l2 }}
  {{- $engineEnv = concat $engineEnv (list
        (dict "name" "MOONCAKE_CONFIG_PATH" "value" "/etc/mooncake/store.json")) }}
  {{- end }}
  {{- end }}
  {{- if or $engineEnv $root.Values.env }}
  env:
  {{- include "vllm.mergeEnv" (dict "chart" $engineEnv "user" $root.Values.env "padding" 4) }}
  {{- end }}
  {{- if $serves }}
  ports:
  - containerPort: {{ $httpPort }}
    name: {{ $pname }}
  {{- if $pdRole }}
  - containerPort: {{ $nixlScPort }}
    name: nixl-sc{{ $oc }}
  - containerPort: {{ $nixlHttpPort }}
    name: nixl-http{{ $oc }}
  {{- end }}
  {{- end }}
  {{- /* rdma.enabled adds IPC_LOCK to whatever securityContext says, so the
         RDMA driver can pin its buffers (and the multi-node shell form's
         `ulimit -l unlimited` actually takes). Added once, never duplicated.
         Colocate pd skips this: same-pod NIXL needs no IB. */}}
  {{- $sc := deepCopy ($root.Values.securityContext | default dict) }}
  {{- if $needsRdma }}
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
  {{- if or $hasModel $root.Values.volumeMounts $shmOn $l2 }}
  volumeMounts:
  {{- if $hasModel }}
  - name: model-storage
    mountPath: {{ $root.Values.model.mountPath }}
    readOnly: true
  {{- end }}
  {{- if $shmOn }}
  - name: dshm
    mountPath: /dev/shm
  {{- end }}
  {{- if $l2 }}
  - name: mc-store
    mountPath: /etc/mooncake
    readOnly: true
  {{- end }}
  {{- with $root.Values.volumeMounts }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- end }}
  {{- /* The GPU limit stays derived from model.gpus (or pd.<role>.gpus under
         pd) -- the one place this chart names a GPU count -- and is merged
         over whatever else is in .Values.resources, so cpu/memory/ephemeral-
         storage can be set without restating it. A second way to say "2
         GPUs" would only drift, so naming it under resources is refused
         rather than silently ignored.

         nvidia.com/gpu is an extended resource: it belongs in limits
         only, and the kubelet sets the request equal to it. Empty or 0
         leaves the key out altogether rather than asking for zero of it.

         Under lws.enabled this is per POD: a group holds lws.size x
         model.gpus GPUs. Under pd A/B it is per pod of the role's group,
         so a role with size: 2 + gpus: 8 is 16 GPUs across 2 pods. */}}
  {{- $res := $root.Values.resources | default dict }}
  {{- range $section := list "limits" "requests" }}
  {{- if hasKey (index $res $section | default dict) "nvidia.com/gpu" }}
  {{- fail (printf "vllm: set the GPU count with model.gpus, not resources.%s -- model.gpus is what renders nvidia.com/gpu and what the rest of the chart refers to" $section) }}
  {{- end }}
  {{- end }}
  {{- $gpus := toString ($root.Values.model.gpus | default "") }}
  {{- /* In pd a role's own gpus wins, so the two engines split the GPU
         budget between them; unset or empty-string falls back to model.gpus.
         Detect set-ness with kindIs + toString, not with sprig `default`,
         because `default` treats integer 0 as empty and would silently
         rewrite `gpus: 0` to the fallback -- losing a GPU-less role.
         Outside pd this is a no-op. */}}
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
         point of such an overlay is to hand the job to this switch. Colocate
         pd skips this: same-pod NIXL needs no HCA. */}}
  {{- if $needsRdma }}
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
          # break a collective whose workers are already gone; a single pod through
          # lifecycle.preStopKill.
          - |
            {{- include "vllm.preStopScript" (dict "root" $root "kill" (ternary $lws.leaderPreStopKill $root.Values.lifecycle.preStopKill $multi) "httpPort" $httpPort "hwPort" $hwPort) | nindent 12 }}
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
    {{- if $pdRole }}
    {{- include "vllm.probeOnPort" (dict "probe" . "port" $pname) | nindent 4 }}
    {{- else }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- with $root.Values.readinessProbe }}
  readinessProbe:
    {{- if $pdRole }}
    {{- include "vllm.probeOnPort" (dict "probe" . "port" $pname) | nindent 4 }}
    {{- else }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- if $root.Values.hangWatcher.enabled }}
  # hang-watcher owns liveness: probe the sidecar's /healthz on the shared
  # pod network; a 503 (hang) restarts THIS container. Replaces the default
  # livenessProbe -- see hangWatcher in values.yaml for why.
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
    {{- include "vllm.probeOnPort" (dict "probe" . "port" $pname) | nindent 4 }}
    {{- else }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
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
- name: hang-watcher{{ $oc }}
  image: "{{ $root.Values.hangWatcher.image.repository }}:{{ $root.Values.hangWatcher.image.tag }}"
  env:
  - name: ENGINE_URL
    value: "http://127.0.0.1:{{ $httpPort }}"
  - name: LISTEN
    value: ":{{ $hwPort }}"
  - name: CONFIG_FILE
    value: /etc/hang-watcher/config.json
  ports:
  - containerPort: {{ $hwPort }}
    name: hang-hz{{ $oc }}
  {{- with $root.Values.hangWatcher.readinessProbe }}
  # Readiness on the sidecar itself: a pod is an endpoint only while every container is
  # ready, so a hang verdict drops the POD out of the Service before the restart even
  # starts. The engine's own readinessProbe is untouched and still applies.
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
  {{- with $root.Values.hangWatcher.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "vllm.podSpec" -}}
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
{{- /* Colocate always renders the merged Deployment (pd-colocate.yaml);
       podSpec is the one-engine pod, so it is always the non-colocate
       identity. */}}
{{- $e := fromYaml (include "vllm.engineIdentity" (dict "root" $root "role" .role "roleCfg" (.roleCfg | default dict) "colocate" false)) }}
{{- $role := $e.role }}
{{- $roleCfg := $e.roleCfg }}
{{- $lws := $root.Values.lws }}
{{- $multi := $e.multi }}
{{- $pdRole := $e.pdRole }}
{{- $worker := $e.worker }}
{{- $serves := $e.serves }}
{{- $hasModel := $e.hasModel }}
{{- $l2 := $e.l2 }}
{{- $preStop := $root.Values.lifecycle.preStop }}
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
{{- /* The leader's rendezvous port opens an image pull and a process start
       after the leader POD exists, which is all startupPolicy: LeaderCreated
       promises. A worker that races it and gives up first EXITS, which under
       RecreateGroupOnPodRestart restarts the whole group into the same cold
       start. Unbounded: a waiting worker is a late group, an exiting one is a
       loop -- at the cost of holding the pod's GPUs meanwhile. Reuses the
       engine image; bash's /dev/tcp does the probing. Under pd a role can
       override distPort; the wait has to hit the same port --master-port
       pointed at, not the lws-wide default. Outside pd this falls back to
       lws.distPort, matching pre-pd renders. */}}
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
{{- include "vllm.engineContainers" (dict "root" $root "role" .role "roleCfg" (.roleCfg | default dict) "colocate" false) }}
{{- $hangVol := and $root.Values.hangWatcher.enabled $serves }}
{{- /* hostNetwork / IPC_LOCK / rdma/hca_shared come from $needsRdma inside
       engineContainers. But the pod-level fields (hostNetwork, dnsPolicy,
       hostIPC) live here and have to make the same call: a pd-colocate pod
       never makes it to podSpec (it renders merged from pd-colocate.yaml),
       so $multi and pd's A/B shape both still want hostNetwork when
       hostNetwork is set in values. */}}
{{- if or $hasModel $hangVol $root.Values.volumes $shmOn $l2 }}
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
{{- if $hangVol }}
- name: hang-watcher-config
  configMap:
    name: {{ $root.Release.Name }}-hang-watcher
{{- end }}
{{- if $l2 }}
- name: mc-store
  configMap:
    name: {{ include "vllm.fullname" $root }}-mc-store-config
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
       (never merges): the two roles of a PD set often need to land on
       different GPU products, which affinities cannot express by union.
       NodeSelector gets no per-role override -- flat maps do not compose,
       and per-role nodeSelector degenerates into per-node pinning. */}}
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
{{- define "vllm.probeOnPort" -}}
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
  /health on the engines directly, never the router's own port: asking the
  router cannot answer the question -- a router holding a dead upstream
  list keeps its port open just the same. /health on vllm calls
  engine_client.check_health(), deeper than the sglang equivalent; the
  engines' own readinessProbe and the hang-watcher sidecar still own the
  "wedged scheduler" verdict, so this probe only needs the shallowest
  question answered: "is at least one engine process behind this router
  alive and taking HTTP". During model load /health fails (which is
  precisely why the engines' own startupProbe carries the 90-minute
  budget), so the router correctly reads not-Ready throughout the load.

  Known gap this does not close: after engines are healthy, a wedged
  scheduler keeps serving /health 200 from cached frontend state, and
  the headless Services publish not-ready addresses -- so a post-
  startup wedge is invisible to this probe. Hang-watcher owns that
  failure mode (it restarts the engine), and the new engine's IP
  eventually goes stale in the router's argv -- the staleness self-
  healing PR addresses that layer.

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

  The probe runs python3+urllib, never curl or wget: vllm/vllm-router
  is a Rust-binary image that ships neither (same constraint the
  preStop drain hook on the engine pod documents). python3 + urllib is
  the lowest-common-denominator HTTP client in vllm-derived images.
*/ -}}
{{- define "vllm.pdRouterProbes" -}}
{{- $roles := .roles -}}
startupProbe:
  exec:
    command: ["bash", "-lc", {{ include "vllm.pdRouterProbeScript" (dict "roles" $roles) | quote }}]
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 180           # 180 x 30s = 90 minutes -- the engines' load budget
readinessProbe:
  exec:
    command: ["bash", "-lc", {{ include "vllm.pdRouterProbeScript" (dict "roles" $roles) | quote }}]
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
{{- end -}}

{{- define "vllm.pdRouterProbeScript" -}}
{{- $roles := .roles -}}
set -u
check() {
  local src=$1 port=$2
  # A name (any non-numeric character in src) -> resolve via DNS and try each.
  # Dotted-quad literal -> probe directly, no resolution step. python3 +
  # urllib, never curl or wget: vllm/vllm-router ships neither (see the
  # preStop drain hook on the engine pod for the same constraint).
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
       vllm.pdRouterProbes -- separate concerns. */ -}}
{{- define "vllm.pdRouterLivenessProbe" -}}
{{- $roles := .roles -}}
livenessProbe:
  exec:
    command: ["bash", "-lc", {{ include "vllm.pdRouterLivenessProbeScript" (dict "roles" $roles) | quote }}]
  periodSeconds: 10
  timeoutSeconds: 10
  failureThreshold: 2
{{- end -}}

{{- define "vllm.pdRouterLivenessProbeScript" -}}
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
  The preStop hook's drain script.

  Stage 1a (endpointSyncSeconds) always waits: Kubernetes removes the pod from
  the EndpointSlice and runs this hook at the SAME time, and the pod has no way
  to observe that removal. Stage 1b then watches vLLM's own metrics and returns
  as soon as the server goes idle, so a quiet pod shuts down in about
  endpointSyncSeconds rather than always burning drainSeconds.

  Two cases the loop has to tell apart, because both look like "no number":

    a blip          one unreadable scrape. Keep waiting -- cutting a drain short
                    on a transient error is exactly what the drain is for.
    no server       /metrics unreadable for ~30s running. Nothing to drain (the
                    port never bound, or the engine is already gone), and sitting
                    out the rest of drainSeconds would only hold the GPUs while
                    the replacement waits for them.

  Missing series are the same class of mistake in the other direction: summing
  over nothing yields 0.0, which reads as "idle" and ends the drain immediately.
  inflight() reports None instead, so a renamed or unmounted metric makes the
  hook wait rather than silently skip.

  The tail (`kill`) exists because of how LWS tears a group down. It deletes the leader FIRST, so the leader takes SIGTERM while its
  workers are still running and still expecting it in the next collective. If
  vLLM's shutdown then blocks inside cross-node NCCL, the pod burns the entire
  terminationGracePeriodSeconds before the kubelet SIGKILLs it -- holding its
  GPUs the whole time, which on a full cluster is exactly what the replacement
  group is waiting for.

  What the tail may NOT do is SIGKILL PID 1. A process inside a PID namespace
  cannot kill that namespace's init: the kernel drops signals the init has no
  handler for, and SIGKILL can never have one (man 7 pid_namespaces). kill(2)
  still returns 0, so it reads as success while doing nothing.

  What works is the pair below. SIGTERM to PID 1 IS delivered, because vLLM
  installs a handler for it -- so the hook starts the real shutdown itself,
  inside the grace period. Then it waits: if PID 1 exits, the kernel tears the
  PID namespace down and takes this hook with it, so simply surviving that sleep
  means vLLM is wedged. At that point its CHILDREN get SIGKILLed -- they carry no
  such protection -- and their death lets PID 1 exit on its own.

  Why the kill half exists at all: vLLM deleted mid-load misses SIGTERM (uvicorn has
  not installed its handler yet), finishes booting, and then holds its GPUs until the
  kubelet SIGKILLs it at terminationGracePeriodSeconds -- an hour, for these values.
  Both roles hit that, which is why `kill` is not lws-only; the caller decides.

  Call it as: include "vllm.preStopScript" (dict "root" $ "kill" false)
*/}}
{{- define "vllm.preStopScript" -}}
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
# Gauges for what vLLM is serving right now and what it has queued.
BUSY = ("vllm:num_requests_running", "vllm:num_requests_waiting")
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
    return total if found else None


# Keep serving while the cluster takes this pod out of rotation, so no new requests are sent here.
time.sleep({{ $preStop.endpointSyncSeconds }})
{{- if $root.Values.hangWatcher.enabled }}


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
    {{- if $root.Values.hangWatcher.enabled }}
    # A hung engine's counters are frozen, not falling: they sit at whatever they were when it
    # wedged and never reach 0, so this loop would burn the full drainSeconds waiting for a
    # number that cannot move. The verdict costs nothing to be wrong about -- by the time
    # preStop runs the container is already being terminated.
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
{{- $wait := add (int $root.Values.lifecycle.shutdownTimeout) (int $root.Values.lifecycle.shutdownReserveSeconds) }}

# Drained (or out of time). Drive the shutdown from here rather than let the
# kubelet's SIGTERM find vLLM blocked in a collective its workers will never
# join. SIGTERM reaches PID 1 because vLLM installs a handler for it; SIGKILL
# never would. See the comment above this script.
log("SIGTERM -> PID 1")
os.kill(1, signal.SIGTERM)

# If PID 1 exits, the kernel tears down the PID namespace and this hook dies with
# it -- so getting past this sleep means vLLM is stuck in its own shutdown.
time.sleep({{ $wait }})

log("still up after {{ $wait }}s -- killing PID 1's children")
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
