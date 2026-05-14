#!/bin/bash
#
# Container entrypoint.
#
# At every container start:
#   1. Detect the host UID/GID (env USER_UID, or stat the workspace mount)
#   2. Remap dev's UID/GID in /etc/passwd if it differs from bake-time 1000
#   3. Normalize /opt/venv permissions once when UID/GID remap needs it
#   4. chown the few directories the dev user needs to own
#   5. ssh-keygen
#   6. exec the CMD via `gosu dev`
#
# AI CLIs are installed on demand via /usr/local/bin/setup-ai inside the
# container, not at boot.
#
# Root-as-runtime is not a separate image; use `docker exec -u root <ct>`
# for one-off privileged commands.

set -e

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
        exec sudo -E "$0" "$@"
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

# UID/GID detection. Prefer explicit USER_UID, then stat the mounted workspace
# so the container matches the host's file owner. WORKSPACE_DIR is the most
# precise signal, but older compose files may omit it; fall back to common
# workspace paths without treating /home/dev itself as a workspace.
detect_uid_gid_from_dir() {
    local dir="$1"
    local detected_uid detected_gid

    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    detected_uid=$(stat -c '%u' "$dir") || return 1
    detected_gid=$(stat -c '%g' "$dir") || return 1
    [ "$detected_uid" != "0" ] || return 1

    USER_UID=$detected_uid
    USER_GID=$detected_gid
    return 0
}

detect_uid_gid_from_pwd() {
    case "${PWD:-}" in
        /home/dev/workspace|/home/dev/workspace/*|/workspace|/workspace/*|/workspaces|/workspaces/*)
            detect_uid_gid_from_dir "$PWD"
            ;;
        *)
            return 1
            ;;
    esac
}

if [ -z "${USER_UID:-}" ] || [ "${USER_UID:-}" = "1000" ]; then
    if ! detect_uid_gid_from_dir "${WORKSPACE_DIR:-}" && ! detect_uid_gid_from_pwd; then
        FOUND_WORKSPACE_OWNER=0
        for candidate in /home/dev/workspace/* /workspace/* /workspaces/*; do
            if detect_uid_gid_from_dir "$candidate"; then
                FOUND_WORKSPACE_OWNER=1
                break
            fi
        done
        if [ "$FOUND_WORKSPACE_OWNER" = "0" ]; then
            detect_uid_gid_from_dir "/home/dev/workspace" || true
        fi
    fi
fi
USER_UID=${USER_UID:-1000}
USER_GID=${USER_GID:-1000}

CURRENT_UID=$(id -u "${USERNAME}")
CURRENT_GID=$(id -g "${USERNAME}")
NEEDS_ID_REMAP=0

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
    NEEDS_ID_REMAP=1
    # Keep the bake-time group available as a supplemental group. Files baked as
    # dev:dev, including /opt/venv, remain writable after dev's primary GID is
    # remapped to the host workspace owner.
    if [ "${CURRENT_GID}" != "${USER_GID}" ]; then
        BAKED_GROUP="${USERNAME}-baked"
        if ! grep -q "^${BAKED_GROUP}:x:" /etc/group; then
            echo "${BAKED_GROUP}:x:${CURRENT_GID}:${USERNAME}" >> /etc/group
        fi
    fi
    sed -i "s/^${USERNAME}:x:${CURRENT_UID}:${CURRENT_GID}:/${USERNAME}:x:${USER_UID}:${USER_GID}:/" /etc/passwd
    sed -i "s/^${USERNAME}:x:${CURRENT_GID}:/${USERNAME}:x:${USER_GID}:/" /etc/group
fi

normalize_venv_perms_once() {
    local venv_path="${VENV_PATH:-/opt/venv}"
    local marker_dir="/var/lib/devcontainer"
    local marker_path="${marker_dir}/venv-perms-normalized"

    [ -d "$venv_path" ] || return 0
    [ ! -e "$marker_path" ] || return 0

    mkdir -p "$marker_dir"
    find "$venv_path" -type d ! -perm -0020 -exec chmod g+rwx,g+s {} +
    find "$venv_path" -type f ! -perm -0020 -exec chmod g+rwX {} +
    touch "$marker_path"
}

if [ "$NEEDS_ID_REMAP" = "1" ]; then
    normalize_venv_perms_once
fi

# chown only the dirs the dev user needs to write to. Avoid recursing into
# the workspace mount (NAS-backed, slow) or /opt/venv (normalized once above).
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

umask "${DEVCONTAINER_RUNTIME_UMASK:-0002}" 2>/dev/null || true

exec gosu ${USERNAME} "$@"
