# Deploy entry points. Thin wrappers -- the inventory itself is helmfile.yaml,
# and this file deliberately holds no second copy of the release list.
#
#   make verify    what helmfile.yaml claims, next to what the cluster has
#   make diff      what would change in the cluster (read-only)
#   make apply     diff, then sync only the releases that changed
#   make render    write helmfile's output to rendered/, one file per release
#   make check     render + fail if rendered/ is stale (for CI)
#   make lint      helm lint the chart against each production values file
#   make chart-version   fail if templates/values changed without a Chart.yaml bump

HELMFILE   ?= helmfile
HELM       ?= helm
RENDER_DIR := rendered

# --skip-deps suppresses the `helm repo update` + `helm dependency build` that
# helmfile runs before every command. The sglang chart vendors CART under
# charts/sglang/charts/cart precisely so it resolves offline (see the note in
# Chart.yaml), so that pass reaches out to every configured chart repo, takes
# seconds, and leaves a Chart.lock behind for a dependency that was never going
# to be downloaded.
#
# Drop this flag when the chart itself moves to harbor -- at that point helmfile
# does need a repo refresh to see a newly pushed version.
HELMFILE_FLAGS ?= --skip-deps

# Release names always come from helmfile.yaml. A second list here is exactly
# the drift this repo is trying to stop having.
list_releases = $(HELMFILE) list --output json | jq -r '.[].name'

.PHONY: verify diff apply render check lint chart-version

# Step 0 of adoption, and worth re-running whenever someone deploys by hand.
# The two lists must line up name-for-name AND namespace-for-namespace.
verify:
	@echo "== helmfile.yaml claims =="
	@$(HELMFILE) list
	@echo
	@echo "== live releases rendered from the sglang chart =="
	@$(HELM) list -A -o json \
	  | jq -r '.[] | select(.chart | startswith("sglang-")) | "\(.name)\t\(.namespace)\t\(.chart)\t\(.app_version)"' \
	  || echo "(cluster unreachable)"

diff:
	$(HELMFILE) diff $(HELMFILE_FLAGS)

apply:
	$(HELMFILE) apply $(HELMFILE_FLAGS)

# One file per release, so a chart bump's blast radius across all three shows up
# as an ordinary git diff instead of having to be simulated in your head.
render:
	@rm -rf $(RENDER_DIR); mkdir -p $(RENDER_DIR)
	@$(list_releases) | while read -r r; do \
	  echo "  render $$r"; \
	  $(HELMFILE) -l name=$$r template $(HELMFILE_FLAGS) > $(RENDER_DIR)/$$r.yaml; \
	done

check: render
	@git diff --exit-code -- $(RENDER_DIR) \
	  || { echo; echo "rendered/ is stale -- run 'make render' and commit the result"; exit 1; }

lint:
	@for f in charts/sglang/production/*.yaml; do \
	  echo "== $$f"; \
	  $(HELM) lint charts/sglang --values $$f || exit 1; \
	done

chart-version:
	@./hack/check-chart-version.sh
