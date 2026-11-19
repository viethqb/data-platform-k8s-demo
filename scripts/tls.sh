#!/usr/bin/env bash
# Create the TLS certificate for the environment host and store it as the
# ingress-nginx default certificate (Secret ingress-nginx/<TLS_SECRET>).
#
# - mkcert installed: certificate signed by mkcert's local CA. Run `mkcert -install`
#   once so browsers trust it.
# - otherwise: a self-signed local CA under .certs/<env>/ (import ca.crt manually).
#
# Certificates are written to .certs/<env>/ (git-ignored) and reused on reruns.
#
# Usage: ENV=uat ./scripts/tls.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CERT_DIR="${ROOT_DIR}/.certs/${ENV}"
mkdir -p "${CERT_DIR}"
CRT="${CERT_DIR}/tls.crt"
KEY="${CERT_DIR}/tls.key"

if [ ! -s "${CRT}" ] || [ ! -s "${KEY}" ]; then
  if command -v mkcert >/dev/null; then
    echo "issuing ${HOST} with mkcert (CA: $(mkcert -CAROOT))"
    mkcert -cert-file "${CRT}" -key-file "${KEY}" "${HOST}" >/dev/null 2>&1
  else
    echo "mkcert not found; issuing ${HOST} from a self-signed CA in ${CERT_DIR}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=data-platform local CA (${ENV})" \
      -keyout "${CERT_DIR}/ca.key" -out "${CERT_DIR}/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=${HOST}" \
      -keyout "${KEY}" -out "${CERT_DIR}/tls.csr" 2>/dev/null
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "${HOST}" > "${CERT_DIR}/ext.cnf"
    openssl x509 -req -in "${CERT_DIR}/tls.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
      -CAcreateserial -days 825 -extfile "${CERT_DIR}/ext.cnf" -out "${CRT}" 2>/dev/null
    echo "trust ${CERT_DIR}/ca.crt in your OS/browser to avoid certificate warnings"
  fi
else
  echo "reusing ${CRT}"
fi

kc create namespace ingress-nginx --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n ingress-nginx create secret tls "${TLS_SECRET}" --cert="${CRT}" --key="${KEY}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
echo "secret ingress-nginx/${TLS_SECRET} ready"
