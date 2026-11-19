#!/usr/bin/env bash
# (Re)vendor upstream Helm charts into charts/ at the pinned versions below.
# Bump a version here, run the script, review `git diff charts/<name>`, commit.
#
# Usage: ./scripts/vendor-charts.sh            # all charts
#        ./scripts/vendor-charts.sh airflow    # one chart
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# name|repo|version
CHARTS="
ingress-nginx|https://kubernetes.github.io/ingress-nginx|4.15.1
argo-cd|https://argoproj.github.io/argo-helm|10.18.2
cloudnative-pg|https://cloudnative-pg.github.io/charts|0.29.2
lakekeeper|https://lakekeeper.github.io/lakekeeper-charts/|0.15.0
airflow|https://airflow.apache.org|1.22.0
vault|https://helm.releases.hashicorp.com|0.34.1
external-secrets|https://charts.external-secrets.io|2.15.0
"

ONLY="${1:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

while IFS='|' read -r name repo version; do
  [ -n "${name}" ] || continue
  [ -z "${ONLY}" ] || [ "${ONLY}" = "${name}" ] || continue
  echo "==> ${name} ${version}"
  helm pull "${name}" --repo "${repo}" --version "${version}" --untar -d "${tmp}"
  rm -rf "${ROOT_DIR}/charts/${name}"
  mv "${tmp}/${name}" "${ROOT_DIR}/charts/${name}"
done <<<"${CHARTS}"
