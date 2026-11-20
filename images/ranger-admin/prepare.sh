#!/usr/bin/env bash
# Build context for images/ranger-admin: Dockerfile + the two jars, checksum-verified.
# Usage: prepare.sh <image dir> <context dir>
set -euo pipefail
dir="$1" ctx="$2"
# shellcheck source=/dev/null
source "${dir}/image.env"

fetch() { # url sha256 target
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch for $1" >&2; exit 1; }
}
cp "${dir}/Dockerfile" "${ctx}/Dockerfile"
fetch "${STARROCKS_PLUGIN_URL}" "${STARROCKS_PLUGIN_SHA256}" "${ctx}/ranger-starrocks-plugin.jar"
fetch "${MYSQL_CONNECTOR_URL}" "${MYSQL_CONNECTOR_SHA256}" "${ctx}/mysql-connector-j.jar"
echo "BASE_IMAGE=${BASE_IMAGE}"     # build args for build-images.sh
