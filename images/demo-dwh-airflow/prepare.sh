#!/usr/bin/env bash
# Build context for images/demo-dwh-airflow: the demo-dwh repository at the
# pinned commit (the Dockerfile's build context is the repository root).
# Usage: prepare.sh <image dir> <context dir>
set -euo pipefail
dir="$1" ctx="$2"
# shellcheck source=/dev/null
source "${dir}/image.env"
token="${GITHUB_TOKEN:-}"
if [ -z "${token}" ] && command -v gh >/dev/null; then token="$(gh auth token 2>/dev/null || true)"; fi
[ -n "${token}" ] || { echo "private repo ${SOURCE_REPO}: set GITHUB_TOKEN or log in with gh" >&2; exit 1; }
git -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "${token}" | base64 | tr -d '\n')" \
  clone -q "https://${SOURCE_REPO}" "${ctx}/src"
git -C "${ctx}/src" checkout -q "${SOURCE_COMMIT}"
