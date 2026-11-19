# Shared helpers for scripts/*.sh. Usage: ENV=<env> (default uat).
# shellcheck shell=bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="${ENV:-uat}"
ENV_DIR="${ROOT_DIR}/environments/${ENV}"

if [ ! -f "${ENV_DIR}/env.sh" ]; then
  echo "unknown environment '${ENV}': ${ENV_DIR}/env.sh not found" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_DIR}/env.sh"

CONTEXT="kind-${CLUSTER_NAME}"
BASE_URL="${PUBLIC_URL}"

kc() { kubectl --context "${CONTEXT}" "$@"; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Read one key of a secret (empty if the secret or key is missing).
secret_value() {
  kc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# helm -f arguments for an app: shared values first, then the environment's.
values_args() {
  local name="$1" f
  for f in "${ROOT_DIR}/values/common/${name}.yaml" "${ENV_DIR}/values/${name}.yaml"; do
    [ -f "${f}" ] && printf -- '-f\n%s\n' "${f}"
  done
}

# One line per app of the environment: name|chart|namespace|releaseName
list_apps() {
  helm template platform-apps "${ROOT_DIR}/charts/platform-apps" -n argocd \
    -f "${ENV_DIR}/platform-apps.yaml" \
    | awk '
        /^kind: Application/        {name=""; chart=""; ns=""; rel=""}
        /^  name: /                 {name=$2}
        /^    path: charts\//       {sub("charts/", "", $2); chart=$2}
        /^      releaseName: /      {rel=$2}
        /^    namespace: / && name  {ns=$2; print name "|" chart "|" ns "|" rel}
    '
}

# Render one app exactly like Argo CD: render_app <name> <chart> <namespace> <release>
render_app() {
  local args=() line
  while IFS= read -r line; do args+=("${line}"); done < <(values_args "$1")
  helm template "$4" "${ROOT_DIR}/charts/$2" -n "$3" "${args[@]}"
}
