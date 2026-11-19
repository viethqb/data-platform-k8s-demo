#!/usr/bin/env bash
# Pull-through registry caches for kind.
#
# One registry:3 container per upstream registry runs next to the kind node on
# the "kind" Docker network, with its storage in a Docker volume. containerd in
# the node is pointed at these mirrors, so:
#   - the first cluster pulls from the internet once (through the cache),
#   - every later cluster (same or other environment) pulls over the local
#     Docker network, and the cache survives `kind delete cluster`.
#
# Usage: ENV=uat ./scripts/registry-cache.sh            # start caches + configure the node
#        ./scripts/registry-cache.sh --status            # show caches and their size
#        ./scripts/registry-cache.sh --delete            # remove caches and their volumes
set -euo pipefail

REGISTRY_IMAGE="docker.io/library/registry:3.1.2"

# name|upstream host|remote URL
MIRRORS="
dockerio|docker.io|https://registry-1.docker.io
quay|quay.io|https://quay.io
ghcr|ghcr.io|https://ghcr.io
k8s|registry.k8s.io|https://registry.k8s.io
ecr-public|ecr-public.aws.com|https://ecr-public.aws.com
"

case "${1:-}" in
  --status)
    docker ps -a --filter name=kind-registry- --format '{{.Names}}\t{{.Status}}'
    docker system df -v 2>/dev/null | awk '/kind-registry-/ {print "  volume " $1 "\t" $NF}'
    exit 0 ;;
  --delete)
    while IFS='|' read -r name _ _; do
      [ -n "${name}" ] || continue
      docker rm -f "kind-registry-${name}" >/dev/null 2>&1 || true
      docker volume rm "kind-registry-${name}" >/dev/null 2>&1 || true
      echo "removed kind-registry-${name}"
    done <<<"${MIRRORS}"
    exit 0 ;;
esac

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null

while IFS='|' read -r name upstream remote; do
  [ -n "${name}" ] || continue
  container="kind-registry-${name}"
  if [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null)" != "true" ]; then
    docker rm -f "${container}" >/dev/null 2>&1 || true
    docker run -d --name "${container}" --restart=always --network kind \
      -v "${container}:/var/lib/registry" \
      -e REGISTRY_PROXY_REMOTEURL="${remote}" \
      -e OTEL_TRACES_EXPORTER=none \
      "${REGISTRY_IMAGE}" >/dev/null
    echo "started ${container} -> ${remote}"
  fi
done <<<"${MIRRORS}"

# Point containerd in every node at the caches (needs config_path, set in
# environments/<env>/kind-cluster.yaml). hosts.toml is read on every pull,
# so no containerd restart is needed.
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  while IFS='|' read -r name upstream remote; do
    [ -n "${name}" ] || continue
    docker exec -i "${node}" sh -c "mkdir -p /etc/containerd/certs.d/${upstream} && cat > /etc/containerd/certs.d/${upstream}/hosts.toml" <<EOF
server = "${remote}"

[host."http://kind-registry-${name}:5000"]
  capabilities = ["pull", "resolve"]
EOF
  done <<<"${MIRRORS}"
  echo "configured mirrors in ${node}"
done
