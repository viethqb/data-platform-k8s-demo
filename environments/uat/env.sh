# UAT environment settings, sourced by scripts/*.sh.
# The host also appears in values/*.yaml of this environment; keep them in sync.
CLUSTER_NAME=data-platform-uat
HOST=data-uat.127.0.0.1.nip.io
PUBLIC_URL=https://data-uat.127.0.0.1.nip.io
# TLS certificate for HOST (mkcert if installed, else a self-signed CA).
TLS_SECRET=platform-tls
