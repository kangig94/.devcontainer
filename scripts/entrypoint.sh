#!/bin/bash
#
# Repo-local entrypoint wrapper. Keep image-portable bootstrap in
# scripts/baked_entrypoint.sh; put host/workspace specific setup here, then
# chain to the baked devcontainer entrypoint.

set -e

BAKED_ENTRYPOINT=${BAKED_ENTRYPOINT:-/usr/local/bin/devcontainer-entrypoint}

if [ "$(id -u)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E "$0" "$@"
    fi
    echo "[entrypoint] not root and sudo unavailable; chaining to baked entrypoint." >&2
    exec "$BAKED_ENTRYPOINT" "$@"
fi

# Optional: pick up host CA certs dropped into the workspace .devcontainer dir.
if [ -n "$CERT_DIR" ] && ls "${CERT_DIR}"/*.crt 1>/dev/null 2>&1; then
    cp "${CERT_DIR}"/*.crt /usr/local/share/ca-certificates/
    update-ca-certificates
fi

exec "$BAKED_ENTRYPOINT" "$@"
