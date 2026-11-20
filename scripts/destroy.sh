#!/usr/bin/env bash
# Delete an environment's kind cluster (all data and generated credentials are lost).
# Usage: ENV=uat ./scripts/destroy.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kind delete cluster --name "${CLUSTER_NAME}"
