# Developer convenience targets.
#
# IMPORTANT: this Makefile only launches the same Containerfiles that CI
# builds, with the same context. It is not a build definition. If a build
# needs a new argument, it belongs in the Containerfile or in the pipeline,
# never only here - otherwise local builds and CI silently diverge.
#
# One documented exception: image.proxy-wasm passes BUILDER_IMAGE, so the
# plugin is compiled by the toolchain image you just built locally instead of
# pulling the published one. CI sets the same argument via the Containerfile
# default, which digest-rewriting automation keeps current.

CONTAINER_TOOL ?= podman

TAG ?= dev

# Must match the ARG BUILDER_IMAGE default in images/proxy-wasm/Containerfile,
# so that building the plugin locally needs no extra arguments.
TINYGO_BUILDER_IMAGE ?= localhost/waf-tinygo-builder:0.34.0

OPERATOR_TAG   ?= localhost/waf-operator:$(TAG)
PROXY_WASM_TAG ?= localhost/waf-proxy-wasm:$(TAG)
BUNDLE_TAG     ?= localhost/waf-operator-bundle:$(TAG)

# The bundle image is built from committed manifests rather than generated at
# build time, so the CSV is a real prerequisite.
BUNDLE_CSV := images/bundle/manifests/coraza-kubernetes-operator.clusterserviceversion.yaml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9._-]+:.*##/ \
		{ printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "  Builds run from the repository root as context, because the"
	@echo "  Containerfiles copy from the submodules, so run 'make submodules'"
	@echo "  first on a fresh clone."

# Submodule state is the developer's to control. The build targets
# deliberately do NOT depend on this: an implicit update would change which
# upstream commit you are building, or reset work in progress, without
# asking. Run it when you mean to.
.PHONY: submodules
submodules: ## Check out or update the upstream submodules
	git submodule update --init --recursive

.PHONY: images
images: image.operator image.proxy-wasm image.bundle ## Build every image

.PHONY: image.tinygo-builder
image.tinygo-builder: ## Build the Go + TinyGo toolchain (build-time only, not shipped)
	$(CONTAINER_TOOL) build -t $(TINYGO_BUILDER_IMAGE) -f tools/tinygo-builder/Containerfile .

.PHONY: image.operator
image.operator: ## Build the operator image
	$(CONTAINER_TOOL) build -t $(OPERATOR_TAG) -f images/operator/Containerfile .

.PHONY: image.proxy-wasm
image.proxy-wasm: image.tinygo-builder ## Build the Coraza WebAssembly plugin image
	$(CONTAINER_TOOL) build -t $(PROXY_WASM_TAG) \
		--build-arg BUILDER_IMAGE=$(TINYGO_BUILDER_IMAGE) \
		-f images/proxy-wasm/Containerfile .

.PHONY: image.bundle
image.bundle: $(BUNDLE_CSV) ## Build the OLM bundle image from the committed manifests
	$(CONTAINER_TOOL) build -t $(BUNDLE_TAG) -f images/bundle/Containerfile .

.PHONY: bundle.generate
bundle.generate: ## Regenerate images/bundle/ (VERSION, CHANNEL, OPERATOR_IMAGE, WASM_IMAGE)
	./hack/generate-bundle.sh \
		--version "$(VERSION)" \
		--channel "$(CHANNEL)" \
		--operator-image "$(OPERATOR_IMAGE)" \
		--wasm-image "$(WASM_IMAGE)" \
		$(if $(REPLACES),--replaces "$(REPLACES)",)

.PHONY: clean
clean: ## Remove locally built images
	-$(CONTAINER_TOOL) rmi -f \
		$(OPERATOR_TAG) $(PROXY_WASM_TAG) $(BUNDLE_TAG) $(TINYGO_BUILDER_IMAGE)
