#!/usr/bin/env bash
# Print every UI URL with its login. App credentials are read from the
# Kubernetes Secrets that External Secrets syncs from Vault.
# Usage: ENV=uat ./scripts/credentials.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sv() {
  local v
  v="$(secret_value "$1" "$2" "$3")"
  printf '%s' "${v:-<missing>}"
}

cat <<EOF
Environment: ${ENV} (context ${CONTEXT})

App          URL                                              Login
-----------  -----------------------------------------------  ------------------------------
Argo CD      ${BASE_URL}/argocd          admin / $(sv argocd argocd-initial-admin-secret password)
Vault        ${BASE_URL}/ui              admin / $(sv vault vault-init admin-password)   (Username method)
Airflow      ${BASE_URL}/airflow/        admin / $(sv airflow airflow-admin password)
Metabase     ${BASE_URL}/metabase/       (create admin on first visit)
Polaris      ${BASE_URL}/polaris/        $(sv polaris polaris-root client-id) / $(sv polaris polaris-root client-secret)   (realm POLARIS)
Silo console ${BASE_URL}/silo/           $(sv silo silo-root MINIO_ROOT_USER) / $(sv silo silo-root MINIO_ROOT_PASSWORD)
Ranger       ${BASE_URL}/ranger/         admin / $(sv ranger ranger-secrets admin-password)
StarRocks    mysql -h 127.0.0.1 -P 9030  root / $(sv starrocks starrocks-root password)   (catalog: lakehouse)

In-cluster endpoints
  Vault               http://vault.vault.svc:8200
  Silo S3 API         http://silo.silo.svc:9000
  Polaris catalog     http://polaris.polaris.svc:8181/api/catalog   (warehouse: lakehouse, OAuth2 client credentials)
  Ranger policy URL   http://ranger-admin.ranger.svc:6080/ranger
  PostgreSQL          pg-rw.postgres.svc:5432
  StarRocks (MySQL)   starrocks-fe-service.starrocks.svc:9030
EOF
