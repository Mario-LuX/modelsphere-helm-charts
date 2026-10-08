#!/usr/bin/env bash
# Refuse to publish a chart whose default render names an image that does not exist.
#
# Merging to main publishes every chart whose version moved, immediately. On
# 2026-09-25 autoconfig 0.4.0, llmscaleoperator 0.3.0 and llm-slo-decision-gen 0.2.0
# went out that way while the images they point at had not been released yet, and
# anyone installing them in that window got ImagePullBackOff. This check runs on the
# pull request, before that can happen, and again right before chart-releaser.
#
# For each chart that would be released (its Chart.yaml version differs from BASE, or
# the chart is new), render it with its defaults, collect every `image:` it asks for,
# and ask the registry for each one. Any image that cannot be resolved fails the run.
#
#   hack/check-chart-images.sh <base-ref>   charts whose version changed since <base-ref>
#   hack/check-chart-images.sh --all        every chart
#
# Needs helm and crane on PATH. Anonymous pulls only: the images are public.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mode=${1:?usage: $0 <base-ref> | --all}

version_of() { sed -n 's/^version:[[:space:]]*//p' | head -1 | tr -d "\"'"; }

charts=()
for d in charts/*/; do
  c=$(basename "$d")
  if [ "$mode" = --all ]; then charts+=("$c"); continue; fi
  new=$(version_of < "charts/$c/Chart.yaml")
  old=$(git show "$mode:charts/$c/Chart.yaml" 2>/dev/null | version_of || true)
  [ "$new" != "$old" ] && charts+=("$c")
done
if [ ${#charts[@]} -eq 0 ]; then echo "no chart changes version since $mode: nothing would be released"; exit 0; fi

# Values a chart refuses to render without. They only satisfy the chart's own guards;
# no switch that changes which images are rendered is touched.
extra_values() {
  case "$1" in
    sglang|vllm)      echo "--set modelRoute.nginx.outputConfigMap=ci/openresty-conf" ;;
    bodylog-exporter) echo "--set data.hostPath=/ci --set nodeSelector.ci=ci" ;;
    continuation-gateway) echo "--set config.continuationModel=ci" ;;
    *)                echo "" ;;
  esac
}

missing=0
for c in "${charts[@]}"; do
  if grep -q '^dependencies:' "charts/$c/Chart.yaml"; then helm dependency update "charts/$c" >/dev/null; fi
  # shellcheck disable=SC2046
  render=$(helm template ci "charts/$c" $(extra_values "$c")) \
    || { echo "FAIL $c: does not render with its defaults"; missing=$((missing+1)); continue; }
  images=$(printf '%s\n' "$render" | sed -nE 's/^[[:space:]-]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' | sort -u)
  if [ -z "$images" ]; then echo "FAIL $c: renders no image at all -- the check would be meaningless"; missing=$((missing+1)); continue; fi
  echo "== $c $(version_of < "charts/$c/Chart.yaml")"
  for img in $images; do
    if digest=$(crane digest "$img" 2>/tmp/crane.err); then
      echo "   ok       $img  ($digest)"
    else
      echo "   MISSING  $img  -- $(tail -1 /tmp/crane.err)"
      missing=$((missing+1))
    fi
  done
done

if [ "$missing" -gt 0 ]; then
  echo
  echo "$missing image(s) cannot be pulled. Release the images first (the component repos"
  echo "publish on a version tag), then merge the chart change."
  exit 1
fi
echo; echo "every image the released charts ask for exists"
