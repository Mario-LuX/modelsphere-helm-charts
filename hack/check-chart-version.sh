#!/usr/bin/env bash
# Refuse a change to a chart's contract that does not also raise its Chart.yaml
# version.
#
# release.yml publishes with chart-releaser and `skip_existing: true`: a chart
# whose version is already released is skipped, and the run still succeeds. So a
# template or default change merged without a version bump is never published,
# and nothing says so -- the next person to bump the version ships it unknowingly,
# and the released version that was supposed to name one rendering names two.
#
# A chart's contract is what it renders and accepts: templates/, values.yaml,
# values.schema.json and its vendored subcharts (charts/). A schema edit can
# reject a values file that rendered yesterday, so it counts even if no template
# moved. README edits and Chart.yaml metadata (description, keywords) do not.
#
#   hack/check-chart-version.sh [base-ref]      default: origin/main
set -euo pipefail

base="${1:-origin/main}"
merge_base="$(git merge-base "${base}" HEAD)"
status=0

# The chart's own top-level `version:` -- not a dependency's, which is indented.
chart_version() { awk -F': *' '/^version:/{gsub(/["'"'"' ]/, "", $2); print $2; exit}'; }

for chart_dir in charts/*/; do
  chart="${chart_dir%/}"
  name="$(basename "${chart}")"
  [ -f "${chart}/Chart.yaml" ] || continue

  paths=("${chart}/templates" "${chart}/values.yaml" "${chart}/values.schema.json" "${chart}/charts")
  if git diff --quiet "${merge_base}" HEAD -- "${paths[@]}"; then
    continue
  fi

  old="$(git show "${merge_base}:${chart}/Chart.yaml" 2>/dev/null | chart_version || true)"
  new="$(chart_version < "${chart}/Chart.yaml")"

  if [ -z "${old}" ]; then
    echo "ok   ${name}: new chart at ${new}"
  elif [ "${old}" = "${new}" ]; then
    echo "::error file=${chart}/Chart.yaml::${name}: chart contract changed but version is still ${new}"
    git diff --name-only "${merge_base}" HEAD -- "${paths[@]}" | sed 's/^/       changed: /'
    status=1
  elif [ "$(printf '%s\n%s\n' "${old}" "${new}" | sort -V | tail -n1)" != "${new}" ]; then
    echo "::error file=${chart}/Chart.yaml::${name}: version went down, ${old} -> ${new}"
    status=1
  else
    echo "ok   ${name}: ${old} -> ${new}"
  fi
done

exit "${status}"
