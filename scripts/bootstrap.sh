#!/usr/bin/env bash
# Bootstrap one environment of the data platform on kind:
#   1. create the kind cluster        (environments/<env>/kind-cluster.yaml)
#   2. generate credentials as Kubernetes Secrets (kept out of Git; reruns reuse them)
#   3. install ingress-nginx + Argo CD from charts/ (Argo CD adopts both afterwards)
#   4. apply the root app-of-apps     (charts/platform-apps + environments/<env>/platform-apps.yaml)
#
# Usage: ENV=uat ./scripts/bootstrap.sh
#   REVISION=<branch|tag|sha>  Git revision Argo CD syncs (default: main)
#   GITHUB_TOKEN=...           only needed if the repo is private
#   HELM_TIMEOUT=20m           helm --wait timeout (image pulls can be slow)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVISION="${REVISION:-main}"
REPO_URL="$(awk '/^repoURL:/ {print $2}' "${ENV_DIR}/platform-apps.yaml")"

rand() { openssl rand -hex "${1:-16}"; }

# Create a secret only if it does not exist yet, so reruns keep existing passwords.
ensure_secret() {
  local ns="$1" name="$2"; shift 2
  if kc -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
    return
  fi
  kc -n "${ns}" create secret generic "${name}" "$@" >/dev/null
  echo "created secret ${ns}/${name}" >&2
}

# Postgres role password: reuse the one CNPG already uses, otherwise generate.
role_password() {
  local role="$1" pw
  pw="$(secret_value postgres "pg-role-${role}" password)"
  [ -n "${pw}" ] || pw="$(rand)"
  ensure_secret postgres "pg-role-${role}" --type=kubernetes.io/basic-auth \
    --from-literal=username="${role}" --from-literal=password="${pw}"
  printf '%s' "${pw}"
}

helm_install() { # release chart namespace
  local args=()
  while IFS= read -r line; do args+=("${line}"); done < <(values_args "$1")
  helm --kube-context "${CONTEXT}" upgrade --install "$1" "${ROOT_DIR}/charts/$2" \
    -n "$3" "${args[@]}" --wait --timeout "${HELM_TIMEOUT:-20m}"
}

for bin in kind kubectl helm openssl; do
  command -v "${bin}" >/dev/null || { echo "missing required tool: ${bin}" >&2; exit 1; }
done

log "environment ${ENV}: cluster ${CLUSTER_NAME}, ${BASE_URL}, revision ${REVISION}"

log "kind cluster"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster already exists"
else
  kind create cluster --config "${ENV_DIR}/kind-cluster.yaml"
fi

log "namespaces"
for ns in argocd ingress-nginx cnpg-system postgres silo lakekeeper airflow metabase ranger; do
  kc create namespace "${ns}" --dry-run=client -o yaml | kc apply -f - >/dev/null
done

log "secrets"
ensure_secret postgres pg-superuser --type=kubernetes.io/basic-auth \
  --from-literal=username=postgres --from-literal=password="$(rand)"

PG_HOST="pg-rw.postgres.svc.cluster.local"

LAKEKEEPER_DB_PW="$(role_password lakekeeper)"
ensure_secret lakekeeper lakekeeper-db --from-literal=password="${LAKEKEEPER_DB_PW}"
ensure_secret lakekeeper lakekeeper-encryption --from-literal=encryptionKey="$(rand 32)"

AIRFLOW_DB_PW="$(role_password airflow)"
ensure_secret airflow airflow-metadata \
  --from-literal=connection="postgresql://airflow:${AIRFLOW_DB_PW}@${PG_HOST}:5432/airflow?sslmode=disable"
ensure_secret airflow airflow-fernet-key \
  --from-literal=fernet-key="$(openssl rand -base64 32 | tr '+/' '-_')"
ensure_secret airflow airflow-api-secret-key --from-literal=api-secret-key="$(rand)"
ensure_secret airflow airflow-jwt-secret --from-literal=jwt-secret="$(rand 32)"
ensure_secret airflow airflow-admin --from-literal=password="$(rand 8)"

METABASE_DB_PW="$(role_password metabase)"
ensure_secret metabase metabase-db --from-literal=password="${METABASE_DB_PW}"

RANGER_DB_PW="$(role_password ranger)"
# Ranger requires >= 8 chars with both letters and digits.
ensure_secret ranger ranger-secrets \
  --from-literal=db-password="${RANGER_DB_PW}" \
  --from-literal=admin-password="Rgr$(rand 6)1"

ensure_secret silo silo-root \
  --from-literal=MINIO_ROOT_USER=admin --from-literal=MINIO_ROOT_PASSWORD="$(rand)"

log "ingress-nginx"
helm_install ingress-nginx ingress-nginx ingress-nginx

log "argo cd"
helm_install argocd argo-cd argocd

log "git repository credentials"
GIT_TOKEN="${GITHUB_TOKEN:-}"
if [ -n "${GIT_TOKEN}" ]; then
  kc -n argocd create secret generic platform-repo \
    --from-literal=type=git --from-literal=url="${REPO_URL}" \
    --from-literal=username=git --from-literal=password="${GIT_TOKEN}" \
    --dry-run=client -o yaml \
    | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kc apply -f - >/dev/null
  echo "registered ${REPO_URL} with GITHUB_TOKEN"
else
  echo "no GITHUB_TOKEN; reading ${REPO_URL} anonymously (public repo)"
fi

log "root app-of-apps"
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
EOF

ARGOCD_PW="$(secret_value argocd argocd-initial-admin-secret password)"
cat <<EOF

Done. Argo CD is now syncing ${ENV} (first sync takes ~20 minutes).
Watch progress:  kubectl --context ${CONTEXT} -n argocd get applications

Show all URLs and logins:  ENV=${ENV} ${ROOT_DIR}/scripts/credentials.sh

Argo CD   ${BASE_URL}/argocd    admin / ${ARGOCD_PW}
EOF
