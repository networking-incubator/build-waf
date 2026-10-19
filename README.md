# build-waf

Build repository for the Red Hat Web Application Firewall product.

This repository contains no application source. It tracks the upstream
projects as git submodules and holds everything needed to turn them into
container images: Containerfiles, the OLM bundle, the file-based catalog, and
the CI pipeline definitions.

Upstream is never modified. Everything product specific - UBI base images,
image labels, `relatedImages`, OLM channel naming - lives here.

Upstream projects:

- [coraza-kubernetes-operator](https://github.com/networking-incubator/coraza-kubernetes-operator)
- [coraza-proxy-wasm](https://github.com/networking-incubator/coraza-proxy-wasm)

## Structure

```
images/                         shipped artifacts, one directory per image
  operator/Containerfile          the operator
  proxy-wasm/Containerfile        the Coraza WebAssembly plugin
  bundle/Containerfile            OLM bundle
    manifests/ metadata/ tests/     generated and committed; see hack/
  catalog/                        FBC fragments, one dir per OCP version
tools/                          build-time only, never shipped
  tinygo-builder/Containerfile    Go + TinyGo toolchain for the plugin
hack/
  generate-bundle.sh              regenerates images/bundle/ from upstream
  bundle-overlay.yaml             product additions merged into the CSV
coraza-kubernetes-operator/     submodule
coraza-proxy-wasm/              submodule
```

`images/` versus `tools/` is the "does this get released?" line. Only
`images/` entries are shipped, and only they carry product labels.

Directories are named after the artifact they produce, not after the upstream
repository they build from. Upstream names belong to the submodules.

## Building

All builds take the **repository root** as context, never the image
directory, because the Containerfiles copy from the submodules.

```bash
make submodules
make images             # all four, in dependency order
make help               # individual targets
```

The Makefile only launches the same Containerfiles that CI builds, with the
same context and no extra build arguments. It is a convenience wrapper, not a
build definition. The equivalent by hand:

```bash
podman build -t localhost/waf-tinygo-builder:0.34.0 -f tools/tinygo-builder/Containerfile .
podman build -t waf-operator:dev   -f images/operator/Containerfile .
podman build -t waf-proxy-wasm:dev -f images/proxy-wasm/Containerfile .
podman build -t waf-bundle:dev     -f images/bundle/Containerfile .
```

`image.proxy-wasm` depends on `image.tinygo-builder`, and the builder must be
tagged exactly as the `BUILDER_IMAGE` default in
`images/proxy-wasm/Containerfile` or the plugin build will not find it.

### The plugin the operator defaults to

Upstream compiles in a `ghcr.io` reference to the plugin, used when an Engine
omits `spec.driver.wasm.image`. `images/operator/Containerfile` replaces it
by baking `CORAZA_DEFAULT_WASM_IMAGE` into the image from the digest-pinned
`DEFAULT_WASM_IMAGE` build argument, so a default install never reaches
outside the product's own registry and works in a disconnected cluster.

That argument is a pullspec, not a URL: the `oci://` scheme is added around
it in the `ENV`. Keep it that way and keep it digest-pinned, or
digest-rewriting automation will no longer recognise the line and it will
silently go stale.

The precedence upstream defines is unchanged - per-Engine
`spec.driver.wasm.image`, then `--default-wasm-image`, then
`CORAZA_DEFAULT_WASM_IMAGE`, then the compiled-in default - so a cluster
admin can still override it. The bundle passes the flag explicitly, so in an
OLM install the CSV wins; the baked value is what the image resolves to on
its own.

### Regenerating the bundle

Not part of the pipeline. Run it when the bundle changes structurally - a new
version, a new related image, changed annotations, or an upstream chart
change - then review and commit the result.

```bash
make bundle.generate \
    VERSION=0.7.0 \
    CHANNEL=dev-preview \
    OPERATOR_IMAGE=<registry>/<repo>@sha256:... \
    WASM_IMAGE=<registry>/<repo>@sha256:...
```

or call `./hack/generate-bundle.sh` directly with the equivalent flags.

The script wraps the upstream generator unmodified and overlays the product
additions from `hack/bundle-overlay.yaml`. It refuses pullspecs that are not
digest-pinned, and cross-checks that the OLM labels in
`images/bundle/Containerfile` still agree with the generated
`metadata/annotations.yaml`.

## Status

| Artifact | State |
|---|---|
| `tools/tinygo-builder` | builds; compiles the plugin |
| `images/operator` | builds; placeholder `cpe`, `url`, `version` |
| `images/proxy-wasm` | builds; wasm import patch verified |
| `images/bundle` | builds; **generated with placeholder digests, do not ship** |
| `images/catalog` | not started |
| `.tekton/` | not started |

## Outstanding

- [ ] FBC Containerfiles, one per supported OCP version. Upstream's
      `catalog/Dockerfile` cannot be reused: it runs `opm render` against a
      registry during the build, which a network-isolated build forbids.
      Fragments must be pre-rendered and committed. The parent image selects
      the OCP target and must be referenced **by tag** - digest-pinning it
      fails the build.
- [ ] Rename the catalog channel from `alpha` and add the bundle entry. The
      upstream channel is currently empty (`entries: []`), and pre-release
      channels must be named `*-candidate-*`, `*-dev-preview-*` or
      `*-pre-ga-*`.
- [ ] `.tekton/` pipeline definitions, with path-based trigger filters so the
      components do not trigger each other in a rebuild loop.
- [ ] Wire the version build args. All three images currently label
      `version=unknown`.
- [ ] Enable network-isolated builds and dependency prefetching. The module
      paths are inside submodules, and `coraza-proxy-wasm` is a Go
      *workspace*, so the prefetch must cover `go.work` and the `magefiles`
      module or `mage` will not resolve.
- [ ] Regenerate `images/bundle/` against real digests before any release.
- [ ] Verify each `features.operators.openshift.io/*` value in
      `hack/bundle-overlay.yaml`. They are placeholders and are shown to
      users as OperatorHub filters.
- [ ] Set `--replaces` for the upgrade graph, needed from 0.8 onward.
- [ ] Multi-arch build platforms for the operator. The plugin is
      architecture independent; this affects the operator and the builder
      image only.
- [ ] Fill in the `cpe` and `url` labels once the product values are known.
      They are deliberately empty today - see below.

## Gotchas

- **Base image labels are inherited, not absent.** `ubi-minimal` sets `cpe`,
  `url`, `description`, `io.k8s.description` and `version`. Omitting any of
  them does not produce an empty label, it ships UBI's value - the inherited
  `cpe` claims the image is RHEL 9 AppStream. Override every one explicitly.
  Unknown values are set to empty on purpose, so a policy check fails loudly
  rather than passing something that is present but wrong.
- **`description` and `io.k8s.description` must carry the same text**, as
  they do on the UBI images, with `summary` holding the short form. They are
  duplicated as literals deliberately, so no `--build-arg` can substitute
  product copy.
- **The wasm toolchain versions are locked together**, at Go 1.23.12 and
  TinyGo 0.34.0. `ubi9/go-toolset` cannot target wasm at all, and TinyGo
  cannot be bumped. The full reasoning, with the exact errors, is in
  `tools/tinygo-builder/Containerfile`.
- **The bundle is generated, then committed.** Digest-rewriting automation
  can only update pullspecs that exist in a file in git, so the CSV has to
  live in the repository rather than being produced during the build.
- **Bundles must be single-arch.** A bundle must be a single OCI image
  manifest, never an image index.
- **The plugin build invokes the upstream magefile** rather than
  reimplementing its TinyGo invocation. The magefile also rewrites specific
  wasm imports after compiling; copying that logic here would drift silently,
  and the failure mode is a plugin that builds cleanly and misbehaves at
  runtime.
