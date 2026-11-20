#!/usr/bin/env bash
# Build context for images/polaris-console: apache/polaris-tools at the pinned
# commit with base-path.patch applied.
# Usage: prepare.sh <image dir> <context dir>
set -euo pipefail
dir="$1" ctx="$2"
# shellcheck source=/dev/null
source "${dir}/image.env"
git clone -q "${SOURCE_REPO}" "${ctx}/src"
git -C "${ctx}/src" checkout -q "${SOURCE_COMMIT}"
git -C "${ctx}/src" apply "${dir}/base-path.patch"
echo "VITE_BASE_PATH=${BASE_PATH}"  # build args for build-images.sh
