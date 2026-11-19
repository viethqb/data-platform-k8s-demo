#!/usr/bin/env bash
# Create/update the Argo CD Application of ONE component (step-by-step install).
# Renders charts/platform-apps with only=<app> and applies it.
#
# Usage: ENV=uat ./scripts/apply-app.sh silo
#        ENV=uat REVISION=my-branch ./scripts/apply-app.sh silo
#        ENV=uat ./scripts/apply-app.sh silo --wait     # block until Synced/Healthy
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP="${1:?usage: apply-app.sh <app> [--wait]}"
REVISION="${REVISION:-main}"

manifest="$(helm template platform-apps "${ROOT_DIR}/charts/platform-apps" -n argocd \
  -f "${ENV_DIR}/platform-apps.yaml" --set only="${APP}" --set targetRevision="${REVISION}")"

if ! grep -q '^kind: Application' <<<"${manifest}"; then
  echo "app '${APP}' not found in ${ENV_DIR}/platform-apps.yaml" >&2
  exit 1
fi
kc apply -f - <<<"${manifest}"

if [ "${2:-}" = "--wait" ]; then
  echo "waiting for ${APP} to be Synced/Healthy ..."
  until [ "$(kc -n argocd get application "${APP}" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" = "Synced/Healthy" ]; do
    sleep 10
  done
  echo "${APP}: Synced/Healthy"
fi
