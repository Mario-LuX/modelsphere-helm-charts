#!/usr/bin/env bash
# Run the PD router's drift liveness probe, as the chart renders it, against
# fake DNS and engines, and check when it asks for a router restart.
#
# The probe is a shell script inside a template, and its contract is
# behavioural: restart on growth only once the new engine serves; restart on
# shrink only once the dropped address is down or serves another engine; never
# restart on a resolver blip or a DNS flicker over a live engine. A regex on the
# rendered text cannot tell those apart, so this runs the script itself, with
# getent and python3 replaced by stubs reading a fake world:
#
#   dns/<fqdn>     one IP per line; no file = resolver failure, empty = no pods
#   serving/<ip>   present = /health on that IP answers
#   id/<ip>        the hang-watcher /engine identity tuple; no file = no answer
#   state/<role>-ips   the boot snapshot the router wrote ("ip|restarts|ts")
#
#   hack/test-pd-router-probe.sh charts/sglang [charts/vllm ...]
#
# Needs helm (with chart dependencies built) and python3 with PyYAML.
set -uo pipefail

python3 -c 'import yaml' 2>/dev/null || { echo "python3 with PyYAML is required" >&2; exit 2; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state" "$W/dns" "$W/serving" "$W/id"

cat >"$W/bin/getent" <<EOF
#!/usr/bin/env bash
f="$W/dns/\$2"; [ -f "\$f" ] || exit 2
while read -r ip; do [ -n "\$ip" ] && echo "\$ip    \$2"; done <"\$f"
exit 0
EOF
cat >"$W/bin/python3" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ]; then   # serving(): urlopen('http://<ip>:<port><path>')
  ip=\$(printf '%s' "\$2" | sed -E "s#.*http://([0-9.]+):.*#\\1#")
  echo "\$ip" >>"$W/calls"
  [ -f "$W/serving/\$ip" ]; exit
fi
cat >/dev/null              # live_id(): python3 - <ip> <port> <<heredoc
[ -f "$W/id/\$2" ] || exit 2
cat "$W/id/\$2"
EOF
chmod +x "$W/bin/getent" "$W/bin/python3"

PF=ci-prefill-hl-s0.ci.svc.cluster.local.
DC=ci-decode-hl-s0.ci.svc.cluster.local.
VALUES=(-n ci --set modelRoute.nginx.outputConfigMap=ci/openresty-conf
  --set pd.enabled=true --set rdma.enabled=true --set scaler.enabled=false
  --set pd.prefill.gpus=4 --set pd.decode.gpus=4)

# render <chart> <out> [helm args...]: the router's liveness script, with its
# state dir pointed at the fake one.
render() {
  local chart=$1 out=$2; shift 2
  helm template ci "$chart" "${VALUES[@]}" "$@" | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == "ci-router-s0":
        c = [c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "router"][0]
        print(c["livenessProbe"]["exec"]["command"][2].replace("/tmp/pd-router", sys.argv[1]))
        break
else:
    sys.exit("ci-router-s0 not rendered")
' "$W/state" >"$out"
}

# Boot snapshot prefill {.1, .2}, decode {.9}; all in DNS, serving, same identity.
reset() {
  rm -f "$W"/dns/* "$W"/serving/* "$W"/id/*
  : >"$W/calls"
  printf '10.0.0.1|0|t1\n10.0.0.2|0|t2\n' >"$W/state/prefill-ips"
  printf '10.0.0.9|0|t9\n' >"$W/state/decode-ips"
  printf '10.0.0.1\n10.0.0.2\n' >"$W/dns/$PF"
  printf '10.0.0.9\n' >"$W/dns/$DC"
  local ip
  for ip in 10.0.0.1 10.0.0.2 10.0.0.9; do touch "$W/serving/$ip"; done
  echo '0|t1' >"$W/id/10.0.0.1"; echo '0|t2' >"$W/id/10.0.0.2"; echo '0|t9' >"$W/id/10.0.0.9"
}
fail=0
# expect <script> <want-rc> <case>
expect() {
  local out rc
  out=$(PATH="$W/bin:$PATH" bash "$1" 2>&1); rc=$?
  if [ "$rc" -eq "$2" ]; then
    printf 'ok    %-58s %s\n' "$3" "$(tr '\n' ' ' <<<"$out")"
  else
    printf 'FAIL  %-58s rc=%d want=%d %s\n' "$3" "$rc" "$2" "$(tr '\n' ' ' <<<"$out")"
    fail=1
  fi
}
dead() { rm -f "$W/serving/$1" "$W/id/$1"; }

for chart in "$@"; do
  echo "== $chart"
  P="$W/probe.sh"; render "$chart" "$P" || { echo "FAIL  $chart does not render" >&2; fail=1; continue; }

  reset;                                                     expect "$P" 0 "steady state"
  reset; rm "$W/state/prefill-ips" "$W/state/decode-ips";    expect "$P" 0 "no snapshot yet (booting)"
  # Resolver trouble is never drift.
  reset; rm "$W/dns/$PF";                                    expect "$P" 0 "resolver failure"
  reset; : >"$W/dns/$PF"; dead 10.0.0.1; dead 10.0.0.2;      expect "$P" 0 "role empty (atomic re-roll), engines gone"
  # Growth.
  reset; echo 10.0.0.3 >>"$W/dns/$PF"; touch "$W/serving/10.0.0.3"; expect "$P" 1 "growth: new IP serving"
  reset; echo 10.0.0.3 >>"$W/dns/$PF";                       expect "$P" 0 "growth: new IP still loading"
  reset; echo '1|t1b' >"$W/id/10.0.0.1";                     expect "$P" 1 "engine restarted in place (identity changed)"
  reset; dead 10.0.0.2;                                      expect "$P" 0 "engine down but still in DNS"
  # Shrink.
  reset; echo 10.0.0.1 >"$W/dns/$PF";                        expect "$P" 0 "DNS flicker: dropped IP alive, same identity"
  reset; echo 10.0.0.1 >"$W/dns/$PF"; rm "$W/id/10.0.0.2";   expect "$P" 0 "DNS flicker: dropped IP alive, identity silent"
  reset; echo 10.0.0.1 >"$W/dns/$PF"; dead 10.0.0.2;         expect "$P" 1 "scale-down: dropped IP dead"
  reset; echo 10.0.0.1 >"$W/dns/$PF"; echo '3|x' >"$W/id/10.0.0.2"; expect "$P" 1 "IP reuse: dropped IP serves another engine"
  reset; echo 10.0.0.1 >"$W/dns/$PF"; dead 10.0.0.2; : >"$W/dns/$DC"; dead 10.0.0.9
                                                             expect "$P" 0 "scale-down while the other role is empty"
  reset; for n in 1 2 3 4 5; do echo "10.0.0.$n|0|t$n"; done >"$W/state/prefill-ips"
  echo 10.0.0.1 >"$W/dns/$PF"; dead 10.0.0.2
  expect "$P" 1 "large scale-down: several dropped IPs dead"
  calls=$(grep -cv '^10\.0\.0\.1$' "$W/calls")
  if [ "$calls" -eq 1 ]; then echo "ok    large scale-down probes one dead IP, not each"
  else echo "FAIL  large scale-down probed $calls dead IPs, want 1"; fail=1; fi

  # Without hang-watcher there is no identity: shrink still works on "down",
  # a reused address that serves cannot be told from the original engine.
  render "$chart" "$P" --set hangWatcher.enabled=false || { fail=1; continue; }
  reset; echo 10.0.0.1 >"$W/dns/$PF";                        expect "$P" 0 "no hang-watcher: DNS flicker, engine alive"
  reset; echo 10.0.0.1 >"$W/dns/$PF"; dead 10.0.0.2;         expect "$P" 1 "no hang-watcher: scale-down"
done
exit $fail
