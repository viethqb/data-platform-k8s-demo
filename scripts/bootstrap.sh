#!/usr/bin/env bash
# Bootstrap one environment end to end (the tutorial in docs/ does the same
# steps one at a time):
#   1. kind cluster                   environments/<env>/kind-cluster.yaml
#   2. image cache                    scripts/registry-cache.sh  (pull-through mirrors, default)
#                                     or scripts/preload-images.sh (kind load, PRELOAD_IMAGES=1)
#   3. TLS certificate                scripts/tls.sh
#   4. namespaces
#   5. ingress-nginx + Argo CD        Helm, from charts/ (Argo CD adopts both later)
#   6. root app-of-apps               charts/platform-apps + environments/<env>/platform-apps.yaml
#   7. Vault init/unseal/config/seed  scripts/vault-setup.sh
#
# Usage: ENV=uat ./scripts/bootstrap.sh
#   REVISION=<branch|tag|sha>  Git revision Argo CD syncs (default: main)
#   GITHUB_TOKEN=...           only needed if the repo is private
#   HELM_TIMEOUT=20m           helm --wait timeout
#   REGISTRY_CACHE=0           do not use the local pull-through registry caches
#   PRELOAD_IMAGES=1           also kind-load every image (slow on Docker Desktop)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="${ROOT_DIR}/scripts"

REVISION="${REVISION:-main}"
REPO_URL="$(awk '/^repoURL:/ {print $2}' "${ENV_DIR}/platform-apps.yaml")"
NAMESPACES="argocd ingress-nginx vault external-secrets cnpg-system postgres silo polaris airflow metabase ranger"

helm_install() { # release chart namespace
  local args=() line
  while IFS= read -r line; do args+=("${line}"); done < <(values_args "$1")
  helm --kube-context "${CONTEXT}" upgrade --install "$1" "${ROOT_DIR}/charts/$2" \
    -n "$3" ${args[@]+"${args[@]}"} --wait --timeout "${HELM_TIMEOUT:-20m}"
}

for bin in kind kubectl helm openssl docker; do
  command -v "${bin}" >/dev/null || { echo "missing required tool: ${bin}" >&2; exit 1; }
done

log "environment ${ENV}: cluster ${CLUSTER_NAME}, ${BASE_URL}, revision ${REVISION}"

log "1. kind cluster"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster already exists"
else
  kind create cluster --config "${ENV_DIR}/kind-cluster.yaml"
fi

if [ "${REGISTRY_CACHE:-1}" != "0" ]; then
  log "2. registry cache + locally built images"
  "${SCRIPTS}/registry-cache.sh"
  "${SCRIPTS}/build-images.sh"      # no-op when the image is already in localhost:5001
fi
if [ "${PRELOAD_IMAGES:-0}" = "1" ]; then
  log "2b. preload images (kind load)"
  "${SCRIPTS}/preload-images.sh"
fi

log "3. TLS certificate"
"${SCRIPTS}/tls.sh"

log "4. namespaces"
for ns in ${NAMESPACES}; do
  kc create namespace "${ns}" --dry-run=client -o yaml | kc apply -f - >/dev/null
done
echo "${NAMESPACES}"

log "5. ingress-nginx + Argo CD"
helm_install ingress-nginx ingress-nginx ingress-nginx
helm_install argocd argo-cd argocd

GIT_TOKEN="${GITHUB_TOKEN:-}"
if [ -n "${GIT_TOKEN}" ]; then
  kc -n argocd create secret generic platform-repo \
    --from-literal=type=git --from-literal=url="${REPO_URL}" \
    --from-literal=username=git --from-literal=password="${GIT_TOKEN}" \
    --dry-run=client -o yaml \
    | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kc apply -f - >/dev/null
  echo "registered ${REPO_URL} with GITHUB_TOKEN"
fi

log "6. root app-of-apps"
kc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  labels:
    platform.env: ${ENV}
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: charts/platform-apps
    helm:
      releaseName: platform-apps
      valueFiles:
        - ../../environments/${ENV}/platform-apps.yaml
      parameters:
        - name: targetRevision
          value: ${REVISION}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # Waves wait for child apps to be Healthy; retry if one is still Degraded.
    retry:
      limit: 20
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
EOF

log "7. Vault"
"${SCRIPTS}/vault-setup.sh"

cat <<EOF

Done. Argo CD is syncing ${ENV}; apps start as soon as their secrets exist.
Watch progress:  kubectl --context ${CONTEXT} -n argocd get applications
URLs + logins:   ENV=${ENV} ${SCRIPTS}/credentials.sh
EOF
