#!/usr/bin/env bash
# Build images that have no usable upstream release and push them to the local
# registry (localhost:5001, started by scripts/registry-cache.sh).
#
#   images/polaris-console   Polaris Console (apache/polaris-tools) patched to
#                            run under a sub-path (base-path.patch)
#
# Usage: ./scripts/build-images.sh            # build + push if the tag is missing
#        FORCE=1 ./scripts/build-images.sh    # rebuild
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY=localhost:5001

curl -sf "http://${REGISTRY}/v2/" >/dev/null || {
  echo "local registry ${REGISTRY} is not running: run scripts/registry-cache.sh first" >&2
  exit 1
}

build_polaris_console() {
  local dir="${ROOT_DIR}/images/polaris-console"
  # shellcheck source=/dev/null
  source "${dir}/image.env"
  local ref="${IMAGE}:${TAG}"
  if [ "${FORCE:-0}" != "1" ] && curl -sf "http://${REGISTRY}/v2/${IMAGE#*/}/manifests/${TAG}" \
       -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' >/dev/null; then
    echo "${ref} already in the local registry"
    return
  fi
  local src
  src="$(mktemp -d)"
  trap 'rm -rf "${src}"' RETURN
  git clone -q "${SOURCE_REPO}" "${src}"
  git -C "${src}" checkout -q "${SOURCE_COMMIT}"
  git -C "${src}" apply "${dir}/base-path.patch"
  docker build -q -t "${ref}" --build-arg VITE_BASE_PATH="${BASE_PATH}" \
    -f "${src}/console/docker/Dockerfile" "${src}/console"
  docker push -q "${ref}"
  echo "pushed ${ref}"
}

build_polaris_console
