#!/usr/bin/env bash
# Create/update the Argo CD Application of ONE component (step-by-step install).
# Renders charts/platform-apps with only=<app> and applies it.
#
# Usage: ENV=uat ./scripts/apply-app.sh silo
#        ENV=uat REVISION=my-branch ./scripts/apply-app.sh silo
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP="${1:?usage: apply-app.sh <app>}"
REVISION="${REVISION:-main}"

manifest="$(helm template platform-apps "${ROOT_DIR}/charts/platform-apps" -n argocd \
  -f "${ENV_DIR}/platform-apps.yaml" --set only="${APP}" --set targetRevision="${REVISION}")"

if ! grep -q '^kind: Application' <<<"${manifest}"; then
  echo "app '${APP}' not found in ${ENV_DIR}/platform-apps.yaml" >&2
  exit 1
fi
kc apply -f - <<<"${manifest}"
