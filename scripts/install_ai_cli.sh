#!/usr/bin/env bash
# Install Claude Code / Codex / Gemini CLIs into ~/.local.
# Idempotent — skips CLIs already on PATH. Re-run after `make down/up` (since
# ~/.local isn't mounted) or to upgrade via the installers' own update paths.
# SSL-tolerant flags (-k, NODE_TLS_REJECT_UNAUTHORIZED=0) for sites behind
# corporate TLS-intercept proxies; harmless on open networks.

# pipefail so `curl ... | bash` fails when curl fails (default pipeline status
# is the last command's; without pipefail a curl error gets masked by bash).
set -e
set -o pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "[setup-ai] Run as the dev user, not root — these install into \$HOME/.local." >&2
    exit 1
fi

failed=()

install_claude() {
    if command -v claude >/dev/null 2>&1; then
        echo "[setup-ai] claude already installed: $(command -v claude)"
        return 0
    fi
    echo "[setup-ai] Installing Claude Code..."
    curl -kfsSL https://claude.ai/install.sh | bash
}

install_npm_cli() {
    local pkg="$1" bin="$2"
    if command -v "$bin" >/dev/null 2>&1; then
        echo "[setup-ai] $bin already installed: $(command -v "$bin")"
        return 0
    fi
    echo "[setup-ai] Installing $pkg..."
    NODE_TLS_REJECT_UNAUTHORIZED=0 npm_config_strict_ssl=false \
        npm install -g "$pkg"
}

# Best-effort: try all three; one failure doesn't block the others.
install_claude                            || failed+=(claude)
install_npm_cli @openai/codex codex       || failed+=(codex)
install_npm_cli @google/gemini-cli gemini || failed+=(gemini)

echo ""
echo "[setup-ai] Summary:"
for c in claude codex gemini; do
    if command -v "$c" >/dev/null 2>&1; then
        printf "  %-7s %s\n" "$c" "$("$c" --version 2>/dev/null | head -1 || echo '(version unknown)')"
    else
        printf "  %-7s %s\n" "$c" "(NOT INSTALLED)"
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo ""
    echo "[setup-ai] Failed: ${failed[*]}" >&2
    exit 1
fi
