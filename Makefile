# End-to-end test of the sglang and vllm host compile cache on a kind cluster.
# See test/e2e/kind/README.md.

KIND ?= kind
# The node is <cluster>-control-plane. One node, so replicas share the hostPath.
KIND_CLUSTER ?= cache-e2e
# Empty uses the node image pinned in test/e2e/kind/kind-config.yaml.
KIND_NODE_IMAGE ?=
# Extra arguments to go test, for example -ginkgo.focus=exhausted.
E2E_ARGS ?=
E2E_TIMEOUT ?= 40m
# sglang, vllm, or empty to run both in sequence.
E2E_CHART ?=
# 1 or true: print helm output, pod lists, the hostPath tree, engine env and
# cache-mgr log lines. Off by default. CI sets 1.
E2E_VERBOSE ?=

.PHONY: setup-test-e2e-kind test-e2e-kind cleanup-test-e2e-kind

setup-test-e2e-kind:
	@command -v $(KIND) >/dev/null 2>&1 || { \
		echo "kind is not installed. Install kind and retry." >&2; \
		exit 1; \
	}
	@if $(KIND) get clusters 2>/dev/null | grep -qx '$(KIND_CLUSTER)'; then \
		echo "Kind cluster '$(KIND_CLUSTER)' already exists. Skipping creation."; \
	else \
		echo "Creating Kind cluster '$(KIND_CLUSTER)'..."; \
		$(KIND) create cluster --name $(KIND_CLUSTER) \
			--config test/e2e/kind/kind-config.yaml \
			$(if $(KIND_NODE_IMAGE),--image $(KIND_NODE_IMAGE),) \
			--wait 120s; \
	fi

# Deletes the cluster on success unless KEEP_CLUSTER=1. A failure leaves it up.
test-e2e-kind: setup-test-e2e-kind
	cd test/e2e/kind && KIND=$(KIND) KIND_CLUSTER=$(KIND_CLUSTER) E2E_VERBOSE=$(E2E_VERBOSE) E2E_CHART=$(E2E_CHART) \
		go test -tags=e2e . -v -ginkgo.v -timeout $(E2E_TIMEOUT) $(E2E_ARGS)
ifeq ($(KEEP_CLUSTER),1)
	@echo "KEEP_CLUSTER=1: leaving $(KIND_CLUSTER) up (kubectl --context kind-$(KIND_CLUSTER))"
else
	$(MAKE) cleanup-test-e2e-kind
endif

cleanup-test-e2e-kind:
	$(KIND) delete cluster --name $(KIND_CLUSTER)
