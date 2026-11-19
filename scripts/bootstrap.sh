#!/usr/bin/env bash
# Bootstrap the data platform lab on kind:
#   1. create the kind cluster
#   2. generate credentials as Kubernetes Secrets (kept out of Git; reruns reuse them)
#   3. install ingress-nginx + Argo CD with Helm (Argo CD adopts both afterwards)
#   4. register the Git repo and apply the root app-of-apps
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-data-platform}"
REPO_URL="${REPO_URL:-https://github.com/viethqb/data-platform-k8s-demo.git}"
CONTEXT="kind-${CLUSTER_NAME}"
DOMAIN="data.127.0.0.1.nip.io:8080"

INGRESS_NGINX_CHART_VERSION="4.15.1"
ARGOCD_CHART_VERSION="10.18.2"

kc() { kubectl --context "${CONTEXT}" "$@"; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
rand() { openssl rand -hex "${1:-16}"; }

# Read one key of a secret (empty if the secret or key is missing).
secret_value() {
  kc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}

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

require() {
  for bin in "$@"; do
    command -v "${bin}" >/dev/null || { echo "missing required tool: ${bin}" >&2; exit 1; }
  done
}

require kind kubectl helm openssl

log "kind cluster ${CLUSTER_NAME}"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster already exists"
else
  kind create cluster --config "${ROOT_DIR}/kind/cluster.yaml"
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
helm --kube-context "${CONTEXT}" upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx --version "${INGRESS_NGINX_CHART_VERSION}" \
  -n ingress-nginx -f "${ROOT_DIR}/values/ingress-nginx.yaml" --wait --timeout 5m

log "argo cd"
helm --kube-context "${CONTEXT}" upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "${ARGOCD_CHART_VERSION}" \
  -n argocd -f "${ROOT_DIR}/values/argocd.yaml" --wait --timeout 10m

log "git repository credentials"
GIT_TOKEN="${GITHUB_TOKEN:-}"
if [ -z "${GIT_TOKEN}" ] && command -v gh >/dev/null; then
  GIT_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -n "${GIT_TOKEN}" ]; then
  kc -n argocd create secret generic repo-data-platform-k8s-demo \
    --from-literal=type=git --from-literal=url="${REPO_URL}" \
    --from-literal=username=git --from-literal=password="${GIT_TOKEN}" \
    --dry-run=client -o yaml \
    | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kc apply -f - >/dev/null
  echo "registered ${REPO_URL}"
else
  echo "no GITHUB_TOKEN / gh login found; using ${REPO_URL} anonymously (public repo)"
fi

log "root app-of-apps"
kc apply -f "${ROOT_DIR}/argocd/root.yaml"

ARGOCD_PW="$(secret_value argocd argocd-initial-admin-secret password)"
cat <<EOF

Done. Argo CD is now syncing the platform (first sync takes ~5-10 minutes).
Watch progress:  kubectl --context ${CONTEXT} -n argocd get applications

Show all URLs and logins:  ${ROOT_DIR}/scripts/credentials.sh

Argo CD   http://${DOMAIN}/argocd    admin / ${ARGOCD_PW}
EOF
