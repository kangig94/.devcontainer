#!/bin/bash
#
# Container entrypoint.
#
# The image bakes USER root + dev (UID 1000). At every container start we:
#   1. Detect the host UID/GID (env USER_UID, or stat the workspace mount)
#   2. Remap dev's UID/GID in /etc/passwd if it differs from the bake-time 1000
#   3. chown the few directories the dev user needs to own
#   4. Patch claude-code plugin paths if HOME differs from where they were
#      first installed, then kick off any unbuilt plugin builds
#   5. exec the CMD via `gosu dev` so the container runs as the right user
#
# Root-as-runtime is not a separate image; use `docker exec -u root <ct>`
# for one-off privileged commands.

set -e

# USERNAME inherited from image ENV (baked at build time, default "dev").
USERNAME="${USERNAME:-dev}"
TARGET_HOME="/home/${USERNAME}"

# ---- helpers ---------------------------------------------------------------

# Claude stores absolute paths like /home/<original-user>/.claude/... in its
# plugin metadata. When the container HOME path differs (e.g. UID change
# moved files to /home/dev), rewrite those references in-place.
fix_claude_plugin_paths() {
    local claude_dir="$1"
    local target_home="$2"
    local installed_plugins="${claude_dir}/plugins/installed_plugins.json"
    local known_marketplaces="${claude_dir}/plugins/known_marketplaces.json"

    local stored_home=""
    for json_file in "$installed_plugins" "$known_marketplaces"; do
        [ -f "$json_file" ] || continue
        local path=$(grep -oP '"/home/[^/]+' "$json_file" 2>/dev/null | head -1 | tr -d '"')
        if [ -n "$path" ]; then stored_home="$path"; break; fi
        if grep -q '"/root/' "$json_file" 2>/dev/null; then stored_home="/root"; break; fi
    done

    [ -z "$stored_home" ] && return 0
    [ "$stored_home" = "$target_home" ] && return 0

    for json_file in "$installed_plugins" "$known_marketplaces"; do
        [ -f "$json_file" ] || continue
        sed -i "s|${stored_home}|${target_home}|g" "$json_file" 2>/dev/null || true
    done
    echo "[entrypoint] Fixed Claude plugin paths: ${stored_home} -> ${target_home}"
}

# Build any claude-code plugins that don't have a dist/ yet.
build_claude_plugins() {
    local cache_dir="$1/plugins/cache"
    [ -d "$cache_dir" ] || return 0

    find "$cache_dir" -name "package.json" -maxdepth 4 | while read pkg; do
        local plugin_dir=$(dirname "$pkg")
        [ -d "${plugin_dir}/dist" ] && continue
        grep -q '"build"' "$pkg" 2>/dev/null || continue

        echo "[entrypoint] Building plugin: ${plugin_dir}"
        (cd "$plugin_dir" && npm install --ignore-scripts 2>/dev/null && npm run build 2>/dev/null) || \
            echo "[entrypoint] Warning: plugin build failed: ${plugin_dir}"
    done
}

# Run plugin builds in the background as the dev user — startup must not block.
run_plugin_builds_in_background() {
    local claude_dir="$1"
    echo "[entrypoint] Building Claude plugins in background"
    (
        export -f build_claude_plugins
        gosu "${USERNAME}" bash -lc "build_claude_plugins '${claude_dir}'" \
            >/tmp/claude-plugin-build.log 2>&1 || true
    ) &
}

# ---- main flow (always running as root from the image's USER root) --------

if [ "$(id -u)" != "0" ]; then
    echo "[entrypoint] expected to run as root; got uid $(id -u). exec'ing CMD as-is." >&2
    exec "$@"
fi

# Optional: pick up host CA certs dropped into the workspace .devcontainer dir.
if [ -n "$CERT_DIR" ] && ls "${CERT_DIR}"/*.crt 1>/dev/null 2>&1; then
    cp "${CERT_DIR}"/*.crt /usr/local/share/ca-certificates/
    update-ca-certificates
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
    "${TARGET_HOME}/.config" \
    "${TARGET_HOME}/.claude"; do
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

# claude plugin paths and build
fix_claude_plugin_paths "${TARGET_HOME}/.claude" "${TARGET_HOME}"
[ -d "${TARGET_HOME}/.claude" ] && run_plugin_builds_in_background "${TARGET_HOME}/.claude"

exec gosu ${USERNAME} "$@"
