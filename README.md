# build-waf

Build repository for the Red Hat Web Application Firewall product.

This repository contains no application source. It tracks the upstream
projects as git submodules and holds everything needed to turn them into
container images: Containerfiles, the OLM bundle, the file-based catalog, and
the CI pipeline definitions.

Upstream is never modified. Everything product specific - UBI base images,
image labels, `relatedImages`, OLM channel naming - lives here.

Images are built by Konflux, not locally; this repository holds the build
definitions, not a standalone build.

Upstream projects:

- [coraza-kubernetes-operator](https://github.com/networking-incubator/coraza-kubernetes-operator)
- [coraza-rs](https://github.com/networking-incubator/coraza-rs)

## Structure

```
images/                         shipped artifacts, one directory per image
  operator/Containerfile          the operator
  bundle/Containerfile            OLM bundle
    manifests/ metadata/ tests/     generated and committed; see hack/
  catalog/                        FBC fragments, one dir per OCP version
hack/
  generate-bundle.sh              regenerates images/bundle/ from upstream
  bundle-overlay.yaml             product additions merged into the CSV
.tekton/                        CI PipelineRuns, one per component x event
  pipelines/                      shared Pipeline definitions, see below
coraza-kubernetes-operator/     submodule
coraza-rs/                      submodule
```

`images/` versus `tools/` is the "does this get released?" line. Only
`images/` entries are shipped, and only they carry product labels.

Directories are named after the artifact they produce, not after the upstream
repository they build from. Upstream names belong to the submodules.

## CI pipelines (.tekton/)

Each component has a pull-request and a push `PipelineRun`, both referencing
one of two shared `Pipeline` definitions under `.tekton/pipelines/` via the
Tekton git resolver, rather than embedding a `pipelineSpec` - this keeps the
pull-request and push variants (which differ only in trigger and output tag)
from drifting apart. The two shared pipelines match Konflux's multi-arch and
single-arch build templates, used respectively by the operator (architecture-
specific binary) and the bundle (`FROM scratch`, not architecture-specific).

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
- **The bundle is generated, then committed.** Digest-rewriting automation
  can only update pullspecs that exist in a file in git, so the CSV has to
  live in the repository rather than being produced during the build.
- **Bundles must be single-arch.** A bundle must be a single OCI image
  manifest, never an image index.
