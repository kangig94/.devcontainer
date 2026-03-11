#!/bin/bash
set -e

USERNAME="dev"
if [ -z "${CONTAINER_HOME:-}" ]; then
    if [ "${RUN_AS_ROOT:-false}" = "true" ]; then
        CONTAINER_HOME="/root"
    else
        CONTAINER_HOME="/home/dev"
    fi
fi
TARGET_HOME="${CONTAINER_HOME}"

# Fix Claude Code plugin paths to use current HOME
# Claude stores absolute paths like /home/user/.claude/... or /root/.claude/... which break when username changes
fix_claude_plugin_paths() {
    local claude_dir="$1"
    local target_home="$2"
    local installed_plugins="${claude_dir}/plugins/installed_plugins.json"
    local known_marketplaces="${claude_dir}/plugins/known_marketplaces.json"

    # Find stored home path from either file (supports both /home/user and /root patterns)
    local stored_home=""
    for json_file in "$installed_plugins" "$known_marketplaces"; do
        [ -f "$json_file" ] || continue
        # Try /home/username pattern first
        local path=$(grep -oP '"/home/[^/]+' "$json_file" 2>/dev/null | head -1 | tr -d '"')
        if [ -n "$path" ]; then
            stored_home="$path"
            break
        fi
        # Try /root pattern
        if grep -q '"/root/' "$json_file" 2>/dev/null; then
            stored_home="/root"
            break
        fi
    done

    [ -z "$stored_home" ] && return 0

    # Skip if paths already match
    [ "$stored_home" = "$target_home" ] && return 0

    # Replace old home path with new home path in all plugin-related JSON files
    for json_file in "$installed_plugins" "$known_marketplaces"; do
        [ -f "$json_file" ] || continue
        sed -i "s|${stored_home}|${target_home}|g" "$json_file" 2>/dev/null || true
    done
    echo "[entrypoint] Fixed Claude plugin paths: ${stored_home} -> ${target_home}"
}

# Build unbuilt Claude plugins in container environment
build_claude_plugins() {
    local cache_dir="$1/plugins/cache"
    [ -d "$cache_dir" ] || return 0

    find "$cache_dir" -name "package.json" -maxdepth 4 | while read pkg; do
        local plugin_dir=$(dirname "$pkg")
        # Skip if already built (dist/ exists) or no build script
        [ -d "${plugin_dir}/dist" ] && continue
        grep -q '"build"' "$pkg" 2>/dev/null || continue

        echo "[entrypoint] Building plugin: ${plugin_dir}"
        (cd "$plugin_dir" && npm install --ignore-scripts 2>/dev/null && npm run build 2>/dev/null) || \
            echo "[entrypoint] Warning: plugin build failed: ${plugin_dir}"
    done
}

# Always build unbuilt plugins on startup.
# Run in background so container startup and user switch are not blocked.
maybe_build_claude_plugins() {
    local claude_dir="$1"
    local run_as_user="${2:-}"
    echo "[entrypoint] Building Claude plugins in background"
    if [ -n "${run_as_user}" ] && [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1; then
        (
            export -f build_claude_plugins
            gosu "${run_as_user}" bash -lc "build_claude_plugins '${claude_dir}'" \
                >/tmp/claude-plugin-build.log 2>&1 || true
        ) &
    else
        (build_claude_plugins "$claude_dir" >/tmp/claude-plugin-build.log 2>&1 || true) &
    fi
}

configure_npm_env() {
    local home_dir="$1"
    export NPM_CONFIG_PREFIX="${home_dir}/.local"
    export NPM_CONFIG_CACHE="${home_dir}/.npm"
    export PATH="${home_dir}/.local/bin:${PATH}"
}

# Install CA certs if CERT_DIR is set and contains .crt files
if [ -n "$CERT_DIR" ] && ls "${CERT_DIR}"/*.crt 1>/dev/null 2>&1; then
    if [ "$(id -u)" = "0" ]; then
        cp "${CERT_DIR}"/*.crt /usr/local/share/ca-certificates/
        update-ca-certificates
    else
        sudo cp "${CERT_DIR}"/*.crt /usr/local/share/ca-certificates/
        sudo update-ca-certificates
    fi
fi

# Skip user switching for root target or if user doesn't exist
if [ "${RUN_AS_ROOT}" = "true" ] || ! id "${USERNAME}" &>/dev/null; then
    mkdir -p "${TARGET_HOME}" 2>/dev/null || true
    chmod 755 "${TARGET_HOME}" 2>/dev/null || true
    export HOME="${TARGET_HOME}"
    configure_npm_env "${HOME}"

    mkdir -p "${HOME}/.local/bin" "${HOME}/.local/lib/node_modules" "${HOME}/.local/share/jupyter/runtime" 2>/dev/null || true
    mkdir -p "${HOME}/.npm" 2>/dev/null || true
    mkdir -p "${HOME}/.cache" 2>/dev/null || true
    mkdir -p "${HOME}/.config/vllm" 2>/dev/null || true

    # Find .claude directory - check multiple possible locations
    # Priority: 1) $HOME/.claude (already correct), 2) configured home, 3) /home/${USERNAME}/.claude, 4) /root/.claude
    CLAUDE_DIR=""
    for dir in "${HOME}/.claude" "${TARGET_HOME}/.claude" "/home/${USERNAME}/.claude" "/root/.claude"; do
        if [ -d "$dir" ]; then
            CLAUDE_DIR="$dir"
            break
        fi
    done

    # Create symlink if .claude found but not at $HOME
    if [ -n "$CLAUDE_DIR" ] && [ "$CLAUDE_DIR" != "${HOME}/.claude" ] && [ ! -e "${HOME}/.claude" ]; then
        ln -s "$CLAUDE_DIR" "${HOME}/.claude"
    fi

    # Fix plugin paths and clear cache for container environment
    if [ -d "${HOME}/.claude" ]; then
        fix_claude_plugin_paths "${HOME}/.claude" "${HOME}"
        maybe_build_claude_plugins "${HOME}/.claude"
    fi
    exec "$@"
fi

# Auto-detect UID/GID from WORKSPACE_DIR (skip if root)
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

if [ "$(id -u)" = "0" ]; then
    CURRENT_UID=$(id -u ${USERNAME})
    CURRENT_GID=$(id -g ${USERNAME})

    # Always create required directories for jupyter and vllm
    mkdir -p "${TARGET_HOME}/.local/share/jupyter/runtime" 2>/dev/null || true
    mkdir -p "${TARGET_HOME}/.cache" 2>/dev/null || true
    mkdir -p "${TARGET_HOME}/.config/vllm" 2>/dev/null || true

    if [ "${CURRENT_UID}" != "${USER_UID}" ] || [ "${CURRENT_GID}" != "${USER_GID}" ]; then
        sed -i "s/^${USERNAME}:x:${CURRENT_UID}:${CURRENT_GID}:/${USERNAME}:x:${USER_UID}:${USER_GID}:/" /etc/passwd
        sed -i "s/^${USERNAME}:x:${CURRENT_GID}:/${USERNAME}:x:${USER_GID}:/" /etc/group
    fi

    # Keep startup fast: avoid recursive chown on mounted or large dirs.
    for dir in \
        "${TARGET_HOME}/.ssh" \
        "${TARGET_HOME}/.local" \
        "${TARGET_HOME}/.npm" \
        "${TARGET_HOME}/.cache" \
        "${TARGET_HOME}/.config" \
        "${TARGET_HOME}/.claude"; do
        [ -e "$dir" ] && chown ${USER_UID}:${USER_GID} "$dir" 2>/dev/null || true
    done
    mkdir -p "${TARGET_HOME}/.local/bin" "${TARGET_HOME}/.local/lib/node_modules" 2>/dev/null || true
    mkdir -p "${TARGET_HOME}/.local/share" "${TARGET_HOME}/.local/state" "${TARGET_HOME}/.local/share/jupyter/runtime" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/bin" ] && chown -R ${USER_UID}:${USER_GID} "${TARGET_HOME}/.local/bin" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/lib/node_modules" ] && chown -R ${USER_UID}:${USER_GID} "${TARGET_HOME}/.local/lib/node_modules" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/share" ] && chown -R ${USER_UID}:${USER_GID} "${TARGET_HOME}/.local/share" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/state" ] && chown -R ${USER_UID}:${USER_GID} "${TARGET_HOME}/.local/state" 2>/dev/null || true
    # npm cache can contain stale root-owned files from previous runs.
    [ -d "${TARGET_HOME}/.npm" ] && chown -R ${USER_UID}:${USER_GID} "${TARGET_HOME}/.npm" 2>/dev/null || true
    chown ${USER_UID}:${USER_GID} "${TARGET_HOME}" 2>/dev/null || true
    chmod 755 "${TARGET_HOME}" 2>/dev/null || true

    export HOME="${TARGET_HOME}"
    configure_npm_env "${HOME}"
    fix_claude_plugin_paths "${HOME}/.claude" "${HOME}"
    maybe_build_claude_plugins "${HOME}/.claude" "${USERNAME}"
    exec gosu ${USERNAME} "$@"
else
    # Running as non-root: create and fix directories
    CURRENT_UID=$(id -u)
    CURRENT_GID=$(id -g)
    sudo mkdir -p "${TARGET_HOME}/.local/share/jupyter/runtime" 2>/dev/null || true
    sudo mkdir -p "${TARGET_HOME}/.cache" 2>/dev/null || true
    sudo mkdir -p "${TARGET_HOME}/.config/vllm" 2>/dev/null || true
    sudo chown ${CURRENT_UID}:${CURRENT_GID} "${TARGET_HOME}" 2>/dev/null || true
    sudo chmod 755 "${TARGET_HOME}" 2>/dev/null || true
    for dir in \
        "${TARGET_HOME}/.ssh" \
        "${TARGET_HOME}/.local" \
        "${TARGET_HOME}/.npm" \
        "${TARGET_HOME}/.cache" \
        "${TARGET_HOME}/.config" \
        "${TARGET_HOME}/.claude"; do
        [ -e "$dir" ] && sudo chown ${CURRENT_UID}:${CURRENT_GID} "$dir" 2>/dev/null || true
    done
    sudo mkdir -p "${TARGET_HOME}/.local/bin" "${TARGET_HOME}/.local/lib/node_modules" 2>/dev/null || true
    sudo mkdir -p "${TARGET_HOME}/.local/share" "${TARGET_HOME}/.local/state" "${TARGET_HOME}/.local/share/jupyter/runtime" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/bin" ] && sudo chown -R ${CURRENT_UID}:${CURRENT_GID} "${TARGET_HOME}/.local/bin" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/lib/node_modules" ] && sudo chown -R ${CURRENT_UID}:${CURRENT_GID} "${TARGET_HOME}/.local/lib/node_modules" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/share" ] && sudo chown -R ${CURRENT_UID}:${CURRENT_GID} "${TARGET_HOME}/.local/share" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.local/state" ] && sudo chown -R ${CURRENT_UID}:${CURRENT_GID} "${TARGET_HOME}/.local/state" 2>/dev/null || true
    [ -d "${TARGET_HOME}/.npm" ] && sudo chown -R ${CURRENT_UID}:${CURRENT_GID} "${TARGET_HOME}/.npm" 2>/dev/null || true
    export HOME="${TARGET_HOME}"
    configure_npm_env "${HOME}"
    fix_claude_plugin_paths "${HOME}/.claude" "${HOME}"
    maybe_build_claude_plugins "${HOME}/.claude"
fi
exec "$@"
