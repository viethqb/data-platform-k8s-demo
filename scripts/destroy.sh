#!/usr/bin/env bash
# Delete the lab cluster (all data and generated credentials are lost).
set -euo pipefail
kind delete cluster --name "${CLUSTER_NAME:-data-platform}"
