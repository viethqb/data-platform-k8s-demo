#!/usr/bin/env bash
# Pull every image the environment uses into the host Docker cache once, then
# load it into the kind node. Rebuilding a cluster then needs no registry pulls.
#
# Image list = every image:/imageName: in the rendered charts of the environment.
#
# Usage: ENV=uat ./scripts/preload-images.sh          # pull (if missing) + load
#        ENV=uat ./scripts/preload-images.sh --list   # only print the image list
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "$(docker info --format '{{.Architecture}}')" in
  x86_64|amd64) PLATFORM=linux/amd64 ;;
  aarch64|arm64) PLATFORM=linux/arm64 ;;
  *) echo "unsupported docker architecture" >&2; exit 1 ;;
esac

images() {
  while IFS='|' read -r name chart ns rel; do
    [ -n "${name}" ] || continue
    render_app "${name}" "${chart}" "${ns}" "${rel}"
  done < <(list_apps) \
    | awk '$1 ~ /^-?(image|imageName):$/ {print $NF}' \
    | tr -d "\"'" \
    | grep -v ':$' \
    | grep -E '^[a-z0-9.-]+(\.[a-z]+|:[0-9]+)?/|^[a-z0-9-]+/|^[a-z0-9-]+:' \
    | sort -u
}

if [ "${1:-}" = "--list" ]; then
  images
  exit 0
fi

kind get clusters | grep -qx "${CLUSTER_NAME}" || {
  echo "kind cluster ${CLUSTER_NAME} does not exist yet" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Drop "@sha256:..." pins for the local cache; kind/containerd keeps the tag.
list="$(images)"
count="$(grep -c . <<<"${list}")"
i=0
while IFS= read -r image; do
  i=$((i + 1))
  ref="${image%@sha256:*}"
  printf '[%2d/%d] %s\n' "${i}" "${count}" "${ref}"
  if ! docker image inspect "${ref}" >/dev/null 2>&1; then
    docker pull --quiet --platform "${PLATFORM}" "${ref}" >/dev/null
  fi
  # Single-platform archive: avoids "content digest not found" when loading
  # multi-arch images from Docker's containerd image store.
  docker save --platform "${PLATFORM}" -o "${tmp}/image.tar" "${ref}"
  kind load image-archive "${tmp}/image.tar" --name "${CLUSTER_NAME}" >/dev/null
done <<<"${list}"

echo "loaded ${count} images into ${CLUSTER_NAME}"
