#!/bin/bash
#
# Container entrypoint.
#
# At every container start:
#   1. Detect the host UID/GID (env USER_UID, or stat the workspace mount)
#   2. Remap dev's UID/GID in /etc/passwd if it differs from bake-time 1000
#   3. chown the few directories the dev user needs to own
#   4. ssh-keygen
#   5. exec the CMD via `gosu dev`
#
# AI CLIs are installed on demand via /usr/local/bin/setup-ai inside the
# container, not at boot.
#
# Root-as-runtime is not a separate image; use `docker exec -u root <ct>`
# for one-off privileged commands.

set -e

# If the CUDA base image provides NVIDIA's entrypoint, run it first and have it
# exec back into this script. Compose overrides image ENTRYPOINT, so without this
# the base image's entrypoint.d hooks are skipped. The guard prevents recursion
# when NVIDIA's script re-enters here.
if [ -z "${NVIDIA_ENTRYPOINT_CHAINED:-}" ]; then
    for nvidia_entrypoint in \
        /opt/nvidia/nvidia_entrypoint.sh \
        /usr/local/bin/nvidia_entrypoint.sh; do
        if [ -x "$nvidia_entrypoint" ] && [ "$nvidia_entrypoint" != "$0" ]; then
            export NVIDIA_ENTRYPOINT_CHAINED=1
            exec "$nvidia_entrypoint" "$0" "$@"
        fi
    done
fi

# Image always uses dev. UID/GID are reconciled below.
USERNAME="dev"
TARGET_HOME="/home/dev"

# ---- main flow ------------------------------------------------------------
# Image USER is `dev` so that `docker exec` (Attach, manual exec, etc.) lands
# as dev by default. PID 1 still needs root for UID remap, ssh-keygen, and
# system setup, so we self-elevate via dev's NOPASSWD sudo. The env_keep
# rule baked into /etc/sudoers.d/entrypoint-env preserves USER_UID etc.

if [ "$(id -u)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E env \
            NVIDIA_ENTRYPOINT_CHAINED="${NVIDIA_ENTRYPOINT_CHAINED:-}" \
            "$0" "$@"
    fi
    echo "[entrypoint] not root and sudo unavailable; exec'ing CMD as-is." >&2
    exec "$@"
fi

# Generate sshd host keys if missing. Done here (not at image build) so
# each container instance gets its own identity and image rebuilds don't
# break clients' known_hosts. ssh-keygen -A is idempotent: existing keys
# are left alone.
if [ -d /etc/ssh ]; then
    ssh-keygen -A 2>/dev/null || true
fi

# UID/GID detection. Prefer explicit USER_UID, fall back to stat'ing the
# mounted workspace so the container always matches the host's file owner.
if [ -z "$USER_UID" ] || [ "$USER_UID" = "1000" ]; then
    if [ -n "$WORKSPACE_DIR" ] && [ -d "$WORKSPACE_DIR" ]; then
        DETECTED_UID=$(stat -c '%u' "$WORKSPACE_DIR")
        DETECTED_GID=$(stat -c '%g' "$WORKSPACE_DIR")
        if [ "$DETECTED_UID" != "0" ]; then
            USER_UID=$DETECTED_UID
            USER_GID=$DETECTED_GID
        fi
    fi
fi
USER_UID=${USER_UID:-1000}
USER_GID=${USER_GID:-1000}

CURRENT_UID=$(id -u "${USERNAME}")
CURRENT_GID=$(id -g "${USERNAME}")

# Always create runtime dirs that some apps (jupyter, vllm, npm) expect.
mkdir -p \
    "${TARGET_HOME}/.local/bin" \
    "${TARGET_HOME}/.local/npm/bin" \
    "${TARGET_HOME}/.local/npm/lib/node_modules" \
    "${TARGET_HOME}/.local/share/jupyter/runtime" \
    "${TARGET_HOME}/.local/state" \
    "${TARGET_HOME}/.npm" \
    "${TARGET_HOME}/.cache" \
    "${TARGET_HOME}/.config/vllm" \
    2>/dev/null || true

# Remap dev's UID/GID if the host differs.
if [ "${CURRENT_UID}" != "${USER_UID}" ] || [ "${CURRENT_GID}" != "${USER_GID}" ]; then
    sed -i "s/^${USERNAME}:x:${CURRENT_UID}:${CURRENT_GID}:/${USERNAME}:x:${USER_UID}:${USER_GID}:/" /etc/passwd
    sed -i "s/^${USERNAME}:x:${CURRENT_GID}:/${USERNAME}:x:${USER_GID}:/" /etc/group
fi

# chown only the dirs the dev user needs to write to. Avoid recursing into
# the workspace mount (NAS-backed, slow) or /opt/venv (already chown'd at
# build time and full of small files).
for dir in \
    "${TARGET_HOME}/.ssh" \
    "${TARGET_HOME}/.local" \
    "${TARGET_HOME}/.npm" \
    "${TARGET_HOME}/.cache" \
    "${TARGET_HOME}/.config"; do
    [ -e "$dir" ] && chown ${USER_UID}:${USER_GID} "$dir" 2>/dev/null || true
done
for dir in \
    "${TARGET_HOME}/.local/bin" \
    "${TARGET_HOME}/.local/npm/bin" \
    "${TARGET_HOME}/.local/npm/lib/node_modules" \
    "${TARGET_HOME}/.local/share" \
    "${TARGET_HOME}/.local/state" \
    "${TARGET_HOME}/.npm"; do
    [ -d "$dir" ] && chown -R ${USER_UID}:${USER_GID} "$dir" 2>/dev/null || true
done
chown ${USER_UID}:${USER_GID} "${TARGET_HOME}" 2>/dev/null || true
chmod 755 "${TARGET_HOME}" 2>/dev/null || true

exec gosu ${USERNAME} "$@"
