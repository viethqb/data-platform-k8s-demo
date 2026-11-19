#!/usr/bin/env bash
# Print every UI URL with its login, read from the cluster secrets.
set -euo pipefail

CONTEXT="kind-${CLUSTER_NAME:-data-platform}"
BASE="http://data.127.0.0.1.nip.io:8080"

sv() {
  kubectl --context "${CONTEXT}" -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null \
    | base64 -d 2>/dev/null || echo "<missing>"
}

cat <<EOF
App          URL                                   Login
-----------  ------------------------------------  ------------------------------
Argo CD      ${BASE}/argocd             admin / $(sv argocd argocd-initial-admin-secret password)
Airflow      ${BASE}/airflow/           admin / $(sv airflow airflow-admin password)
Metabase     ${BASE}/metabase/          (create admin on first visit)
Lakekeeper   ${BASE}/lakekeeper/ui/     (no auth in the lab)
Silo console ${BASE}/silo/              $(sv silo silo-root MINIO_ROOT_USER) / $(sv silo silo-root MINIO_ROOT_PASSWORD)
Ranger       ${BASE}/ranger/            admin / $(sv ranger ranger-secrets admin-password)

In-cluster endpoints
  Silo S3 API         http://silo.silo.svc:9000
  Lakekeeper catalog  http://lakekeeper.lakekeeper.svc:8181/catalog
  Ranger policy URL   http://ranger-admin.ranger.svc:6080/ranger
  PostgreSQL          pg-rw.postgres.svc:5432
EOF
