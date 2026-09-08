# Deploy entry points. Thin wrappers -- the inventory itself is helmfile.yaml,
# and this file deliberately holds no second copy of the release list.
#
#   make releases        the release names this repo manages
#   make verify          what helmfile.yaml claims, next to what the cluster has
#   make diff            what would change in the cluster (read-only)
#   make apply           diff, then sync only the releases that changed
#   make render          write helmfile's output to rendered/, one file per release
#   make check           render + fail if rendered/ is stale (for CI)
#   make lint            helm lint each release with the values helmfile gives it
#   make chart-version   fail if a chart's contract changed without a version bump
#
# SELECTING A SUBSET
#
# Every target above works on all three releases by default. Narrow it with R
# (release names) or L (a helmfile label):
#
#   make diff   R=kimi-k25
#   make apply  R=kimi-k25,modelforge-01-glm
#   make render L=topology=lws
#   make lint   L=model=kimi-k25
#
# R takes a comma-separated list and expands to one `-l name=...` per entry.
# helmfile ORs repeated -l flags and ANDs the terms inside a single one, so a
# comma here means "or" -- which is what you want, and is NOT what you would get
# from passing the list to one -l yourself. `make releases` prints the names,
# `helmfile list` prints the labels.

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

# ---- release selection ------------------------------------------------------
R ?=
L ?=
empty :=
space := $(empty) $(empty)
comma := ,
SELECT := $(strip $(foreach r,$(subst $(comma),$(space),$(R)),-l name=$(r)) $(if $(L),-l $(L)))

# Release names always come from helmfile.yaml. A second list here is exactly
# the drift this repo is trying to stop having.
list_releases = $(HELMFILE) $(SELECT) list --output json | jq -r '.[].name'

.PHONY: releases verify diff apply render check lint chart-version

releases:
	@$(HELMFILE) $(SELECT) list --output json | jq -r '.[] | "\(.name)\t\(.namespace)"'

# Step 0 of adoption, and worth re-running whenever someone deploys by hand.
# The two lists must line up name-for-name AND namespace-for-namespace.
#
# R/L narrow the claimed side only. The cluster side stays whole on purpose: a
# release that exists live but is missing from helmfile.yaml is exactly what
# this is looking for, and filtering it out would hide it.
verify:
	@echo "== helmfile.yaml claims =="
	@$(HELMFILE) $(SELECT) list
	@echo
	@echo "== live releases rendered from the sglang chart =="
	@live=$$($(HELM) list -A -o json 2>&1) \
	  && echo "$$live" | jq -r '.[] | select(.chart | startswith("sglang-")) | "\(.name)\t\(.namespace)\t\(.chart)\t\(.app_version)"' \
	  || echo "  unavailable: $$live"

diff:
	$(HELMFILE) $(SELECT) diff $(HELMFILE_FLAGS)

apply:
	$(HELMFILE) $(SELECT) apply --interactive $(HELMFILE_FLAGS)

# One file per release, so a chart bump's blast radius across all three shows up
# as an ordinary git diff instead of having to be simulated in your head.
#
# A FULL render owns the directory and prunes files for releases that no longer
# exist. A SELECTIVE one must not: it would delete the renders it was never
# asked to regenerate, and `make check` would then report them as removed.
render:
	@if [ -z "$(SELECT)" ]; then rm -rf $(RENDER_DIR); fi; mkdir -p $(RENDER_DIR)
	@$(list_releases) | while read -r r; do \
	  echo "  render $$r"; \
	  $(HELMFILE) -l name=$$r template $(HELMFILE_FLAGS) > $(RENDER_DIR)/$$r.yaml; \
	done

# Looks at the whole directory even under a selection, so a stale file for a
# release you did not select still fails the check.
#
# git status, not git diff: diff only sees TRACKED files, so the render of a
# newly added release -- the case most worth catching -- would be untracked and
# would slip through silently. status reports added, modified and deleted alike.
check: render
	@if [ -n "$$(git status --porcelain -- $(RENDER_DIR))" ]; then \
	  echo "rendered/ does not match helmfile.yaml -- run 'make render' and commit the result:"; \
	  git status --short -- $(RENDER_DIR); \
	  exit 1; \
	fi

# helmfile lint rather than a hand-rolled loop over production/*.yaml: it lints
# each release with the exact values combination helmfile.yaml gives it, so it
# cannot disagree with what gets deployed. Schema validation runs as part of it.
lint:
	$(HELMFILE) $(SELECT) lint $(HELMFILE_FLAGS)

# Charts, not releases -- R/L do not apply.
chart-version:
	@./hack/check-chart-version.sh
