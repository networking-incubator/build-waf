#!/usr/bin/env bash
#
# Stage the compiled Coraza Proxy-Wasm module and its provenance metadata for
# the operator image build.
#
# images/operator/Containerfile builds envoy-coraza from the coraza-rs
# submodule and then embeds it into the manager binary. Between those two
# steps the module has to be placed somewhere the Go stage can reach with a
# single COPY --from, alongside the two version values that the operator's
# bundle manifest records. This script does that placement.
#
# It does NOT write the bundle manifest. That is upstream's job, done by
# coraza-kubernetes-operator/hack/wasm.sh bundle, which also recomputes the
# SHA-256 the operator advertises to Envoy and re-verifies at startup.
#
# The two version values are read out of the coraza-rs workspace rather than
# passed in as build arguments. A literal would be a second source of truth
# that no build step can contradict, and it would go stale the next time the
# submodule moves. Both reads fail loudly when they come back empty rather
# than recording a blank provenance field.
#
# Runnable outside the container, which is the point: the wasm build itself
# needs an entitled machine, but this logic can be checked against a plain
# checkout.
#
# Usage:
#   hack/stage-wasm-module.sh <coraza-rs-dir> <target-triple> <out-dir>
#
# Example:
#   hack/stage-wasm-module.sh coraza-rs wasm32-wasip1 /tmp/out
#
# Writes into <out-dir>:
#   plugin.wasm               the raw module
#   coraza_version            workspace.package version from Cargo.toml
#   proxy_wasm_sdk_version    proxy-wasm git rev from Cargo.lock

set -euo pipefail

die() { echo "stage-wasm-module: $*" >&2; exit 1; }

[ "$#" -eq 3 ] || die "usage: $0 <coraza-rs-dir> <target-triple> <out-dir>"

src="$1"
target="$2"
out="$3"

[ -d "$src" ] || die "coraza-rs directory not found: $src"

module="$src/target/$target/release/envoy_coraza.wasm"
[ -f "$module" ] || die "module not found: $module (was cargo build run for $target?)"

manifest="$src/Cargo.toml"
lock="$src/Cargo.lock"
[ -f "$manifest" ] || die "not found: $manifest"
[ -f "$lock" ] || die "not found: $lock"

# The version shared by the workspace crates, including coraza. Scoped to the
# [workspace.package] table so a version key in any other table cannot match.
coraza_version="$(awk -F'"' '
  /^\[workspace\.package\]/ { in_table = 1; next }
  /^\[/                     { in_table = 0 }
  in_table && /^version[[:space:]]*=/ { print $2; exit }
' "$manifest")"
[ -n "$coraza_version" ] || die "cannot read workspace.package version from $manifest"

# The pinned Proxy-Wasm SDK revision. Cargo.lock records the git source as
# "git+<url>?rev=<rev>#<resolved-sha>"; the trailing SHA after '#' is the
# commit actually locked, which is the one worth recording.
sdk_version="$(awk '
  /^name = "proxy-wasm"$/   { found = 1 }
  found && /^source = /     { print; exit }
' "$lock" | sed -n 's/.*#\([0-9a-f]\{40\}\).*/\1/p')"
[ -n "$sdk_version" ] || die "cannot read proxy-wasm git rev from $lock"

mkdir -p "$out"
cp "$module" "$out/plugin.wasm"
printf '%s\n' "$coraza_version" > "$out/coraza_version"
printf '%s\n' "$sdk_version" > "$out/proxy_wasm_sdk_version"

echo "stage-wasm-module: plugin.wasm coraza=$coraza_version proxy-wasm=$sdk_version -> $out"
