#!/usr/bin/env bash
# Print every UI URL with its login, read from the cluster secrets.
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

App          URL                                         Login
-----------  ------------------------------------------  ------------------------------
Argo CD      ${BASE_URL}/argocd             admin / $(sv argocd argocd-initial-admin-secret password)
Airflow      ${BASE_URL}/airflow/           admin / $(sv airflow airflow-admin password)
Metabase     ${BASE_URL}/metabase/          (create admin on first visit)
Lakekeeper   ${BASE_URL}/lakekeeper/ui/     (no auth)
Silo console ${BASE_URL}/silo/              $(sv silo silo-root MINIO_ROOT_USER) / $(sv silo silo-root MINIO_ROOT_PASSWORD)
Ranger       ${BASE_URL}/ranger/            admin / $(sv ranger ranger-secrets admin-password)

In-cluster endpoints
  Silo S3 API         http://silo.silo.svc:9000
  Lakekeeper catalog  http://lakekeeper.lakekeeper.svc:8181/catalog
  Ranger policy URL   http://ranger-admin.ranger.svc:6080/ranger
  PostgreSQL          pg-rw.postgres.svc:5432
EOF
