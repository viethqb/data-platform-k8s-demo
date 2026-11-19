#!/usr/bin/env bash
# Render every app of an environment exactly like Argo CD does
# (charts/<chart> + values/common/<app>.yaml + environments/<env>/values/<app>.yaml).
# Offline: no cluster needed. Use it before pushing.
#
# Usage: ENV=uat ./scripts/render.sh            # summary per app
#        ENV=uat ./scripts/render.sh airflow    # full manifest of one app
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPS_VALUES="${ENV_DIR}/platform-apps.yaml"
ONLY="${1:-}"

# name|chart|namespace|releaseName for every app in platform-apps.yaml
apps="$(helm template platform-apps "${ROOT_DIR}/charts/platform-apps" -n argocd -f "${APPS_VALUES}" \
  | awk '
      /^kind: Application/        {name=""; chart=""; ns=""; rel=""}
      /^  name: /                 {name=$2}
      /^    path: charts\//       {sub("charts/", "", $2); chart=$2}
      /^      releaseName: /      {rel=$2}
      /^    namespace: / && name  {ns=$2; print name "|" chart "|" ns "|" rel}
  ')"

status=0
while IFS='|' read -r name chart ns rel; do
  [ -n "${name}" ] || continue
  [ -z "${ONLY}" ] || [ "${ONLY}" = "${name}" ] || continue
  args=()
  while IFS= read -r line; do args+=("${line}"); done < <(values_args "${name}")
  if out="$(helm template "${rel}" "${ROOT_DIR}/charts/${chart}" -n "${ns}" "${args[@]}" 2>&1)"; then
    if [ -n "${ONLY}" ]; then
      printf '%s\n' "${out}"
    else
      printf '%-16s OK   %3s objects  (charts/%s -> ns %s)\n' "${name}" "$(grep -c '^kind:' <<<"${out}")" "${chart}" "${ns}"
    fi
  else
    printf '%-16s FAIL\n%s\n' "${name}" "${out}" >&2
    status=1
  fi
done <<<"${apps}"
exit "${status}"
