#!/usr/bin/env bash
# Initialise, unseal and configure Vault for the platform. Idempotent: safe to
# rerun, and required after the cluster restarts (Vault starts sealed).
#
#   1. vault operator init (1 key share) -> Secret vault/vault-init      [LAB ONLY]
#   2. unseal
#   3. KV v2 at secret/, Kubernetes auth, policy + role for External Secrets
#   4. seed secret/platform/* with random values (existing values are kept)
#
# Storing the unseal key and root token in a Kubernetes Secret is only
# acceptable for a local lab. Real environments use auto-unseal (cloud KMS /
# Transit) and do not keep a root token around.
#
# Usage: ENV=uat ./scripts/vault-setup.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=vault
POD=vault-0
ESO_SA=external-secrets
ESO_NS=external-secrets

rand() { openssl rand -hex "${1:-16}"; }

# Run a vault CLI command in the pod. The token is passed on stdin, not argv.
vault_cmd() {
  printf '%s\n' "${ROOT_TOKEN:-}" \
    | kc -n "${NS}" exec -i "${POD}" -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; '"$1"
}

log "waiting for ${NS}/${POD}"
until kc -n "${NS}" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
  sleep 5
done
# The vault process answers `vault status` (exit 2 = sealed) once it listens.
until kc -n "${NS}" exec "${POD}" -- vault status >/dev/null 2>&1 || [ $? -eq 2 ]; do
  sleep 3
done

status_field() {
  kc -n "${NS}" exec "${POD}" -- vault status -format=json 2>/dev/null \
    | sed -n "s/.*\"$1\": *\([a-z]*\).*/\1/p" | head -1
}

log "init"
if [ "$(status_field initialized)" != "true" ]; then
  init_json="$(kc -n "${NS}" exec "${POD}" -- vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  unseal_key="$(sed -n 's/.*"unseal_keys_b64": *\[ *"\([^"]*\)".*/\1/p' <<<"$(tr -d '\n' <<<"${init_json}")")"
  root_token="$(sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' <<<"$(tr -d '\n' <<<"${init_json}")")"
  kc -n "${NS}" create secret generic vault-init \
    --from-literal=unseal-key="${unseal_key}" --from-literal=root-token="${root_token}" >/dev/null
  echo "initialised; unseal key + root token stored in Secret ${NS}/vault-init (lab only)"
else
  echo "already initialised"
fi

UNSEAL_KEY="$(secret_value "${NS}" vault-init unseal-key)"
ROOT_TOKEN="$(secret_value "${NS}" vault-init root-token)"
if [ -z "${UNSEAL_KEY}" ] || [ -z "${ROOT_TOKEN}" ]; then
  echo "Vault is initialised but Secret ${NS}/vault-init is missing; cannot continue" >&2
  exit 1
fi

log "unseal"
if [ "$(status_field sealed)" = "true" ]; then
  printf '%s\n' "${UNSEAL_KEY}" \
    | kc -n "${NS}" exec -i "${POD}" -- sh -c 'read -r k; vault operator unseal "$k" >/dev/null'
  echo "unsealed"
else
  echo "already unsealed"
fi

log "configure"
vault_cmd 'vault secrets list -format=json | grep -q "\"secret/\"" \
  || vault secrets enable -path=secret -version=2 kv'
vault_cmd 'vault auth list -format=json | grep -q "\"kubernetes/\"" \
  || vault auth enable kubernetes'
# Vault runs in-cluster: it uses its own ServiceAccount token and CA for TokenReview.
vault_cmd 'vault write -f auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null'
vault_cmd 'vault policy write platform-read - >/dev/null <<EOF
path "secret/data/platform/*"     { capabilities = ["read"] }
path "secret/metadata/platform/*" { capabilities = ["read", "list"] }
EOF'
vault_cmd "vault write auth/kubernetes/role/${ESO_SA} \
  bound_service_account_names=${ESO_SA} bound_service_account_namespaces=${ESO_NS} \
  audience=vault policies=platform-read ttl=1h >/dev/null"
echo "kv-v2 secret/, auth kubernetes, policy platform-read, role ${ESO_SA}"

# Human login for the UI: userpass user "admin". The UI deliberately does not
# keep a root token across page reloads, so day-to-day use goes through this.
ADMIN_PW="$(secret_value "${NS}" vault-init admin-password)"
if [ -z "${ADMIN_PW}" ]; then
  ADMIN_PW="$(rand 12)"
  kc -n "${NS}" patch secret vault-init --type merge \
    -p "{\"stringData\":{\"admin-password\":\"${ADMIN_PW}\"}}" >/dev/null
fi
vault_cmd 'vault auth list -format=json | grep -q "\"userpass/\"" || vault auth enable userpass'
vault_cmd 'vault policy write admin - >/dev/null <<EOF
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF'
printf '%s\n%s\n' "${ROOT_TOKEN}" "${ADMIN_PW}" | kc -n "${NS}" exec -i "${POD}" -- sh -c '
  read -r VAULT_TOKEN; export VAULT_TOKEN; read -r pw
  vault write auth/userpass/users/admin password="$pw" token_policies=admin >/dev/null'
echo "userpass user admin (policy admin)"

log "seed secret/platform/*"
# seed <path> <key=value>...
# Creates the path, or adds the keys it does not have yet. Existing values are
# never overwritten, so reruns keep every password that is in use.
seed() {
  local path="$1"; shift
  local existing missing=() kv
  existing="$(vault_cmd "vault kv get -mount=secret -format=json ${path} 2>/dev/null" || true)"
  for kv in "$@"; do
    grep -q "\"${kv%%=*}\":" <<<"${existing}" || missing+=("${kv}")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "keep   secret/${path}"
    return
  fi
  local op=put verb=create
  if [ -n "${existing}" ]; then op=patch; verb="add ${#missing[@]} key(s) to"; fi
  # Values go through stdin as KEY=VALUE lines, then into `vault kv put|patch`.
  printf '%s\n' "${missing[@]}" | {
    printf '%s\n' "${ROOT_TOKEN}"
    cat
  } | kc -n "${NS}" exec -i "${POD}" -- sh -c '
      read -r VAULT_TOKEN; export VAULT_TOKEN
      set --
      while IFS= read -r kv; do set -- "$@" "$kv"; done
      vault kv '"${op}"' -mount=secret '"${path}"' "$@" >/dev/null'
  echo "${verb} secret/${path}"
}

seed platform/postgres/superuser "password=$(rand)"
for app in airflow metabase ranger polaris; do
  seed "platform/postgres/${app}" "password=$(rand)"
done
seed platform/airflow \
  "fernet-key=$(openssl rand -base64 32 | tr '+/' '-_')" \
  "api-secret-key=$(rand)" \
  "jwt-secret=$(rand 32)" \
  "admin-password=$(rand 8)"
# Ranger requires >= 8 chars with both letters and digits.
seed platform/ranger "admin-password=Rgr$(rand 6)1"
seed platform/silo "root-user=admin" "root-password=$(rand)"
seed platform/polaris "root-client-secret=$(rand)" "token-key=$(rand 32)"
seed platform/starrocks "root-password=$(rand)" "analyst-password=$(rand 8)" "ranger-lookup-password=$(rand)"

echo
echo "Vault UI: ${BASE_URL}/ui  ->  method Username, user admin, password:"
echo "  kubectl -n ${NS} get secret vault-init -o jsonpath='{.data.admin-password}' | base64 -d"
