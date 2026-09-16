{{/*
  The name every resource this chart owns is called.

  Defaults to the release name, unadorned. One release serves one model, so the
  release name IS the name, and nothing needs a suffix to stay unique -- the two
  components that would otherwise collide, the metrics mock and the CART
  subchart, keep their own suffixed identity and are deliberately NOT routed
  through this helper.

  fullnameOverride exists for one reason: releases installed before the resource
  names were simplified, when the engine Deployment was <release>-vllm.
  Renaming a live Deployment is a delete-and-create, not a rolling update, and on
  a GPU node the replacement cannot even schedule until the old pod releases its
  GPU -- so the upgrade costs the full termination grace period plus a cold model
  load, rather than a rolling restart. Pinning

      fullnameOverride: <release>-vllm

  keeps that Deployment exactly where it is and makes the upgrade ordinary.

  It does not restore the older Service (<release>-vllm-svc) or LLMScaler
  (<release>-scaler): those carried different suffixes, and one value cannot be
  three names. Both are still recreated, which costs a new ClusterIP and an
  operator re-adopt but no pod restart -- and the route survives it, because the
  ModelRoute's top peer tier is direct pod IPs rather than the Service.

  Leave it empty on new releases.
*/}}
{{- define "vllm.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  The id this service is known by OUTSIDE the cluster's object graph: what the
  decision server, the SLO operator and the route all index it under. Not a
  Kubernetes name and never looked up from an object, which is why it gets its
  own value rather than reusing vllm.fullname directly -- but fullname is the
  sensible default, so an unset serviceId costs nothing.
*/}}
{{- define "vllm.serviceId" -}}
{{- .Values.serviceId | default (include "vllm.fullname" .) -}}
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
*/}}
{{- define "vllm.preStopScript" -}}
{{- $preStop := .Values.lifecycle.preStop -}}
{{- $poll := int ($preStop.pollIntervalSeconds | default 2) -}}
{{- /* ~30s of consecutive unreadable metrics, whatever the poll interval. */ -}}
{{- $streak := max 3 (div 30 $poll) -}}
{{- $streakSecs := mul $streak $poll -}}
import time, urllib.request, urllib.error

METRICS = "http://127.0.0.1:{{ .Values.service.port }}/metrics"
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
{{- if .Values.hangWatcher.enabled }}


HEALTHZ = "http://127.0.0.1:{{ .Values.hangWatcher.port }}/healthz"


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
    {{- if .Values.hangWatcher.enabled }}
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
{{- end -}}
