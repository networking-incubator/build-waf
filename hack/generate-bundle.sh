#!/usr/bin/env bash
#
# Regenerate the downstream OLM bundle into images/bundle/.
#
# SKELETON - the overlay content in hack/bundle-overlay.yaml still has TODOs,
# and the product label values are not settled. The mechanics below work.
#
# This is NOT a pipeline step. Digest-rewriting automation keeps the operator
# and plugin digests in the committed CSV current. Run this only when the
# bundle changes structurally: a new version, a new related image, changed
# annotations, or an upstream chart change. The output is committed and
# reviewed in a PR.
#
# Why a wrapper rather than our own generator: the upstream
# hack/generate_bundle.py renders the CSV from the Helm chart and tracks it as
# the chart evolves. Forking it would drift. We only overlay the Red Hat
# productization bits on top.
#
# Usage:
#   hack/generate-bundle.sh \
#       --version 0.7.0 \
#       --channel dev-preview \
#       --operator-image quay.io/.../waf-operator@sha256:... \
#       --wasm-image     quay.io/.../waf-proxy-wasm@sha256:...
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${REPO_ROOT}/coraza-kubernetes-operator"
OUT_DIR="${REPO_ROOT}/images/bundle"
OVERLAY="${REPO_ROOT}/hack/bundle-overlay.yaml"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

VERSION=""
CHANNEL=""
OPERATOR_IMAGE=""
WASM_IMAGE=""
REPLACES=""
PACKAGE_NAME="coraza-kubernetes-operator"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        VERSION="$2"; shift 2 ;;
        --channel)        CHANNEL="$2"; shift 2 ;;
        --operator-image) OPERATOR_IMAGE="$2"; shift 2 ;;
        --wasm-image)     WASM_IMAGE="$2"; shift 2 ;;
        --replaces)       REPLACES="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]]        || die "--version is required"
[[ -n "${CHANNEL}" ]]        || die "--channel is required"
[[ -n "${OPERATOR_IMAGE}" ]] || die "--operator-image is required"
[[ -n "${WASM_IMAGE}" ]]     || die "--wasm-image is required"

for tool in python3 yq helm; do
    command -v "${tool}" >/dev/null || die "${tool} not found on PATH"
done

# --------------------------------------------------------------------------
# Guard rails. These are the mistakes that surface at release time, not now.
# --------------------------------------------------------------------------

# Bundles are never rebuilt when released, so a tag-based reference here ships
# to customers and cannot be corrected later.
for img in "${OPERATOR_IMAGE}" "${WASM_IMAGE}"; do
    [[ "${img}" == *"@sha256:"* ]] || die "not digest-pinned: ${img}"
done

# Pre-release channels must match one of these, or the build and the release
# policy checks fail. 'alpha', the upstream default, does not.
case "${CHANNEL}" in
    *candidate*|*dev-preview*|*pre-ga*) ;;
    *) echo "warning: '${CHANNEL}' is not a pre-release channel name" >&2
       echo "         expected *-candidate-*, *-dev-preview-* or *-pre-ga-*" >&2 ;;
esac

# --------------------------------------------------------------------------
# 1. Generate, using the upstream generator unmodified
# --------------------------------------------------------------------------

mkdir -p "${WORK_DIR}/bundle"
cp -r "${UPSTREAM}/bundle/base" "${WORK_DIR}/bundle/base"

# Called directly rather than via "make bundle" so that the 'helm.sync'
# prerequisite does not write into the submodule's tracked files.
( cd "${UPSTREAM}" && python3 hack/generate_bundle.py \
    --chart-dir      "charts/${PACKAGE_NAME}" \
    --bundle-dir     "${WORK_DIR}/bundle" \
    --version        "v${VERSION}" \
    --image          "${OPERATOR_IMAGE}" \
    --channels       "${CHANNEL}" \
    --default-channel "${CHANNEL}" \
    --package-name   "${PACKAGE_NAME}" \
    ${REPLACES:+--replaces "${REPLACES}"} )

CSV="${WORK_DIR}/bundle/manifests/${PACKAGE_NAME}.clusterserviceversion.yaml"
[[ -f "${CSV}" ]] || die "generator did not produce ${CSV}"

# --------------------------------------------------------------------------
# 2. Overlay the downstream additions
# --------------------------------------------------------------------------

OPERATOR_IMAGE="${OPERATOR_IMAGE}" WASM_IMAGE="${WASM_IMAGE}" \
    envsubst < "${OVERLAY}" > "${WORK_DIR}/overlay.yaml"

yq eval-all 'select(fi==0) * select(fi==1)' \
    "${CSV}" "${WORK_DIR}/overlay.yaml" > "${CSV}.merged"
mv "${CSV}.merged" "${CSV}"

# Carry the chart's namespaced Role into spec.install.spec.permissions.
#
# WORKAROUND for an upstream generator bug: hack/generate_bundle.py extracts
# only the ClusterRole, so the chart's Role - which holds the networkpolicies
# rules the Engine controller needs - is silently dropped. An operator
# installed from the bundle then fails at runtime with "cannot list resource
# networkpolicies".
#
# The rules are re-derived from the same chart with the same render arguments
# rather than copied, so they cannot drift from upstream. Remove this once the
# generator emits permissions itself.
ROLE_RULES="${WORK_DIR}/role-rules.yaml"
( cd "${UPSTREAM}" && helm template "${PACKAGE_NAME}" \
    "charts/${PACKAGE_NAME}" \
    --namespace coraza-system \
    --kube-version 1.32.0 \
    --version "${VERSION}" \
    --set openshift.enabled=true \
    --set istio.revision=openshift-gateway \
    2>/dev/null ) \
  | yq ea '[select(.kind == "Role") | .rules] | flatten(1)' > "${ROLE_RULES}"

# eval-all matters: plain yq processes each rendered document separately and
# would silently produce an empty list, so this guard is load-bearing.
if [[ ! -s "${ROLE_RULES}" ]] || grep -qx '\[\]' "${ROLE_RULES}"; then
    die "no Role rules found in the chart render; the permissions workaround needs revisiting"
fi

SA="$(yq '.spec.install.spec.clusterPermissions[0].serviceAccountName' "${CSV}")"
SA="${SA}" ROLE_RULES="${ROLE_RULES}" yq -i '
  .spec.install.spec.permissions = [{
    "serviceAccountName": strenv(SA),
    "rules": load(strenv(ROLE_RULES))
  }]
' "${CSV}"

# Point the operator at the shipped plugin instead of its compiled-in
# ghcr.io default. Handled here rather than in the overlay because appending
# to a list is not a merge: we replace any existing flag, then add ours.
#
# NOTE: the operator also accepts CORAZA_DEFAULT_WASM_IMAGE, and an Engine can
# override per-resource via spec.driver.wasm.image. Using the flag keeps the
# downstream source identical to upstream.
WASM_IMAGE="${WASM_IMAGE}" yq -i '
  .spec.install.spec.deployments[0].spec.template.spec.containers
    |= map(
        select(.name == "manager").args =
          ((.args // []) | map(select(test("^--default-wasm-image=") | not)))
          + ["--default-wasm-image=oci://" + strenv(WASM_IMAGE)]
        // .
      )
' "${CSV}"

# --------------------------------------------------------------------------
# 3. Publish into images/bundle/ for commit
# --------------------------------------------------------------------------

rm -rf "${OUT_DIR}/manifests" "${OUT_DIR}/metadata" "${OUT_DIR}/tests"
cp -r "${WORK_DIR}/bundle/manifests" "${OUT_DIR}/manifests"
cp -r "${WORK_DIR}/bundle/metadata"  "${OUT_DIR}/metadata"
cp -r "${WORK_DIR}/bundle/tests"     "${OUT_DIR}/tests"

# The upstream-generated bundle.Dockerfile is deliberately not copied; the
# reviewed images/bundle/Containerfile is used instead.

# --------------------------------------------------------------------------
# 4. Verify the Containerfile's OLM labels still match metadata/annotations.yaml
# --------------------------------------------------------------------------
#
# OLM reads the labels from the image and the annotations from the file. If
# they disagree the bundle is subtly broken - wrong channel, wrong package -
# in a way nothing else checks.

CF="${OUT_DIR}/Containerfile"
if [[ -f "${CF}" ]]; then
    fail=0
    while IFS= read -r key; do
        want="$(yq ".annotations.\"${key}\"" "${OUT_DIR}/metadata/annotations.yaml")"
        grep -qF "${key}=${want}" "${CF}" || {
            echo "error: ${CF} is missing or disagrees on ${key}=${want}" >&2
            fail=1
        }
    done < <(yq '.annotations | keys | .[]' "${OUT_DIR}/metadata/annotations.yaml")
    [[ "${fail}" -eq 0 ]] || die "Containerfile OLM labels are out of sync"
else
    echo "warning: ${CF} not found, skipping label cross-check" >&2
fi

echo
echo "Bundle written to ${OUT_DIR}"
echo "  version  ${VERSION}"
echo "  channel  ${CHANNEL}"
echo "  operator ${OPERATOR_IMAGE}"
echo "  wasm     ${WASM_IMAGE}"
echo
echo "Review the diff and commit. Remember that pullspecs above must point at"
echo "registry.redhat.io before release; during onboarding quay.io is expected."
