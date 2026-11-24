#!/usr/bin/env bash
# Read-only SSH deploy key for Airflow git-sync (private DAG repository).
#
#   1. reuse the private key stored in Vault (secret/platform/airflow-git ->
#      ssh-private-key), or generate an ed25519 key and store it there
#   2. register its public key as a read-only deploy key of the DAG repository
#      (GitHub API through `gh`), unless that key is already registered
#
# External Secrets turns the Vault value into Secret airflow/airflow-git-ssh
# (key gitSshKey), which the chart's git-sync containers mount.
# Idempotent. Needs: Vault initialised and unsealed (scripts/vault-setup.sh),
# `gh` logged in with admin access to the repository.
#
# Usage: ENV=uat ./scripts/airflow-git-deploy-key.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="${AIRFLOW_DAGS_REPO:?set AIRFLOW_DAGS_REPO in environments/${ENV}/env.sh}"
TITLE="data-platform ${ENV} airflow git-sync"
VAULT_PATH=platform/airflow-git

command -v gh >/dev/null || { echo "gh is required to register the deploy key" >&2; exit 1; }
ROOT_TOKEN="$(secret_value vault vault-init root-token)"
[ -n "${ROOT_TOKEN}" ] || { echo "Vault is not initialised: run scripts/vault-setup.sh first" >&2; exit 1; }

vault_exec() { # stdin: extra lines after the token
  kc -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; '"$1"
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

log "deploy key for ${REPO}"
private_key="$(printf '%s\n' "${ROOT_TOKEN}" \
  | vault_exec "vault kv get -mount=secret -field=ssh-private-key ${VAULT_PATH} 2>/dev/null" || true)"
if [ -n "${private_key}" ]; then
  printf '%s\n' "${private_key}" > "${tmp}/key"
  echo "reusing the key stored in Vault (secret/${VAULT_PATH})"
else
  ssh-keygen -q -t ed25519 -N "" -C "${TITLE}" -f "${tmp}/key"
  { printf '%s\n' "${ROOT_TOKEN}"; cat "${tmp}/key"; } \
    | vault_exec "vault kv put -mount=secret ${VAULT_PATH} ssh-private-key=- >/dev/null"  # '-': rest of stdin, verbatim (keeps the final newline OpenSSH needs)
  echo "generated an ed25519 key and stored it in Vault (secret/${VAULT_PATH})"
fi
chmod 600 "${tmp}/key"
public_key="$(ssh-keygen -y -f "${tmp}/key" | awk '{print $1" "$2}')"

if gh api "repos/${REPO}/keys" --paginate --jq '.[].key' | grep -qxF "${public_key}"; then
  echo "deploy key already registered on ${REPO}"
else
  gh api -X POST "repos/${REPO}/keys" -f title="${TITLE}" -f key="${public_key}" -F read_only=true \
    --jq '"registered deploy key id \(.id) (read_only=\(.read_only)) on '"${REPO}"'"'
fi
