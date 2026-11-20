#!/usr/bin/env bash
# Build the images in images/<name>/ and push them to the local registry
# (localhost:5001, started by scripts/registry-cache.sh).
#
# Each images/<name>/ has:
#   image.env    IMAGE, TAG, DOCKERFILE (relative to the context), optional CONTEXT
#   prepare.sh   <image dir> <context dir>: fills the build context and prints
#                build args as KEY=VALUE lines
#
#   polaris-console  Polaris Console patched to run under a sub-path
#   ranger-admin     Ranger Admin + StarRocks lookup plugin
#
# Usage: ./scripts/build-images.sh [name...]     # build + push when the tag is missing
#        FORCE=1 ./scripts/build-images.sh        # rebuild
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY=localhost:5001

curl -sf "http://${REGISTRY}/v2/" >/dev/null || {
  echo "local registry ${REGISTRY} is not running: run scripts/registry-cache.sh first" >&2
  exit 1
}

build() {
  local dir="$1" ctx args=() line
  (
    # shellcheck source=/dev/null
    source "${dir}/image.env"
    local ref="${IMAGE}:${TAG}"
    if [ "${FORCE:-0}" != "1" ] && curl -sf "http://${REGISTRY}/v2/${IMAGE#*/}/manifests/${TAG}" \
         -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' >/dev/null; then
      echo "${ref} already in the local registry"
      exit 0
    fi
    ctx="$(mktemp -d)"
    trap 'rm -rf "${ctx}"' EXIT
    while IFS= read -r line; do
      [ -n "${line}" ] && args+=(--build-arg "${line}")
    done < <(bash "${dir}/prepare.sh" "${dir}" "${ctx}")
    docker build -q -t "${ref}" ${args[@]+"${args[@]}"} \
      -f "${ctx}/${DOCKERFILE}" "${ctx}/${CONTEXT:-.}" >/dev/null
    docker push -q "${ref}" >/dev/null
    echo "pushed ${ref}"
  )
}

names=("$@")
if [ "${#names[@]}" -eq 0 ]; then
  for d in "${ROOT_DIR}"/images/*/; do names+=("$(basename "${d}")"); done
fi
for name in "${names[@]}"; do
  build "${ROOT_DIR}/images/${name}"
done
