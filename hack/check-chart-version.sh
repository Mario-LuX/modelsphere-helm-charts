#!/usr/bin/env bash
# Refuse a change to a chart's templates or default values that does not also
# bump its Chart.yaml version.
#
# Why this exists: charts/sglang sat at 0.4.0 while f0283da (schedulerName,
# 46 lines of _pod.tpl), 736e9f0 (priority class, CART affinity), 8b1d01a (the
# LWS startup fix) and two more all changed templates/. "0.4.0" therefore named
# at least six different renderings, which makes `--version 0.4.0` in
# helmfile.yaml a decoration rather than a pin: you cannot say which templates a
# given release was rendered from.
#
#   ./hack/check-chart-version.sh [base-ref]      default: origin/master
set -euo pipefail

base="${1:-origin/master}"
merge_base="$(git merge-base "$base" HEAD)"
status=0

for chart_dir in charts/*/; do
  chart="${chart_dir%/}"
  name="$(basename "$chart")"
  [ -f "$chart/Chart.yaml" ] || continue

  # The chart's contract: what it renders, its default values, its vendored
  # subcharts, and the schema that decides which inputs it will even accept -- a
  # schema edit can reject a values file that rendered yesterday, which is a
  # breaking change whether or not a template moved. A values file under
  # production/ or examples/ is a deployment fact, not part of the contract, and
  # must NOT force a bump.
  if git diff --quiet "$merge_base" HEAD -- \
       "$chart/templates" "$chart/values.yaml" "$chart/values.schema.json" "$chart/charts"; then
    continue
  fi

  old="$(git show "$merge_base:$chart/Chart.yaml" 2>/dev/null | yq -r '.version' || echo "")"
  new="$(yq -r '.version' "$chart/Chart.yaml")"

  if [ "$old" = "$new" ]; then
    echo "FAIL $name: chart contract changed but Chart.yaml version is still $new"
    echo "     changed:"
    git diff --name-only "$merge_base" HEAD -- \
      "$chart/templates" "$chart/values.yaml" "$chart/values.schema.json" "$chart/charts" | sed 's/^/       /'
    status=1
  else
    echo "ok   $name: $old -> $new"
  fi
done

exit $status
