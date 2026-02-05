#!/bin/bash
set -e

USERNAME="${USERNAME:-dev}"

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
    # Find .claude directory - check multiple possible locations
    # Priority: 1) $HOME/.claude (already correct), 2) /home/${USERNAME}/.claude, 3) /root/.claude
    CLAUDE_DIR=""
    for dir in "${HOME}/.claude" "/home/${USERNAME}/.claude" "/root/.claude"; do
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
        build_claude_plugins "${HOME}/.claude"
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
    mkdir -p /home/${USERNAME}/.local/share/jupyter/runtime 2>/dev/null || true
    mkdir -p /home/${USERNAME}/.cache 2>/dev/null || true
    mkdir -p /home/${USERNAME}/.config/vllm 2>/dev/null || true

    if [ "${CURRENT_UID}" != "${USER_UID}" ] || [ "${CURRENT_GID}" != "${USER_GID}" ]; then
        sed -i "s/^${USERNAME}:x:${CURRENT_UID}:${CURRENT_GID}:/${USERNAME}:x:${USER_UID}:${USER_GID}:/" /etc/passwd
        sed -i "s/^${USERNAME}:x:${CURRENT_GID}:/${USERNAME}:x:${USER_GID}:/" /etc/group
    fi

    # Always fix ownership
    # NOTE: .cache is chmod 777 in Dockerfile, so only chown the directory itself.
    # NEVER use -R on .cache - it contains thousands of uv/pip cache files and takes forever.
    chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.ssh 2>/dev/null || true
    chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.local 2>/dev/null || true
    chown ${USER_UID}:${USER_GID} /home/${USERNAME}/.cache 2>/dev/null || true
    chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.config 2>/dev/null || true
    chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.claude 2>/dev/null || true
    chown ${USER_UID}:${USER_GID} /home/${USERNAME}
    chmod 755 /home/${USERNAME}

    export HOME=/home/${USERNAME}
    fix_claude_plugin_paths "${HOME}/.claude" "${HOME}"
    build_claude_plugins "${HOME}/.claude"
    exec gosu ${USERNAME} "$@"
else
    # Running as non-root: create and fix directories
    sudo mkdir -p /home/${USERNAME}/.local/share/jupyter/runtime 2>/dev/null || true
    sudo mkdir -p /home/${USERNAME}/.cache 2>/dev/null || true
    sudo mkdir -p /home/${USERNAME}/.config/vllm 2>/dev/null || true
    sudo chown $(id -u):$(id -g) /home/${USERNAME} 2>/dev/null || true
    sudo chmod 755 /home/${USERNAME} 2>/dev/null || true
    sudo chown -R $(id -u):$(id -g) /home/${USERNAME}/.ssh 2>/dev/null || true
    sudo chown -R $(id -u):$(id -g) /home/${USERNAME}/.local 2>/dev/null || true
    # NEVER use -R on .cache - thousands of files, takes forever
    sudo chown $(id -u):$(id -g) /home/${USERNAME}/.cache 2>/dev/null || true
    sudo chown -R $(id -u):$(id -g) /home/${USERNAME}/.config 2>/dev/null || true
    sudo chown -R $(id -u):$(id -g) /home/${USERNAME}/.claude 2>/dev/null || true
    fix_claude_plugin_paths "${HOME}/.claude" "${HOME}"
    build_claude_plugins "${HOME}/.claude"
fi
exec "$@"