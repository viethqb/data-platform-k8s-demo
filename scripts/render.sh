#!/usr/bin/env bash
# Render every app of an environment exactly like Argo CD does
# (charts/<chart> + values/common/<app>.yaml + environments/<env>/values/<app>.yaml).
# Offline: no cluster needed. Use it before pushing.
#
# Usage: ENV=uat ./scripts/render.sh            # summary per app
#        ENV=uat ./scripts/render.sh airflow    # full manifest of one app
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ONLY="${1:-}"
status=0
while IFS='|' read -r name chart ns rel; do
  [ -n "${name}" ] || continue
  [ -z "${ONLY}" ] || [ "${ONLY}" = "${name}" ] || continue
  if out="$(render_app "${name}" "${chart}" "${ns}" "${rel}" 2>&1)"; then
    if [ -n "${ONLY}" ]; then
      printf '%s\n' "${out}"
    else
      printf '%-17s OK   %3s objects  (charts/%s -> ns %s)\n' "${name}" "$(grep -c '^kind:' <<<"${out}")" "${chart}" "${ns}"
    fi
  else
    printf '%-17s FAIL\n%s\n' "${name}" "${out}" >&2
    status=1
  fi
done < <(list_apps)
exit "${status}"
