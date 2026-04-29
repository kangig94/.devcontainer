# Sourced by every login shell via /etc/zsh/zshrc.

# `uv a` / `uv activate` — source .venv/bin/activate from the cwd.
uv() {
    if [ "$1" = "a" ] || [ "$1" = "activate" ]; then
        if [ -f ".venv/bin/activate" ]; then
            source .venv/bin/activate
        else
            echo "No .venv/bin/activate in $(pwd)"
            return 1
        fi
    else
        command uv "$@"
    fi
}

# `clx [branch]` — create a new git worktree branch and launch claude in plan mode.
clx() {
    local branch_name
    if [ -z "$1" ]; then
        branch_name="worktree-$(date +%Y%m%d-%H%M%S)"
    else
        branch_name="$1"
    fi
    git worktree add "../$branch_name" -b "$branch_name" && \
    cd "../$branch_name" || return 1
    claude --model opusplan --permission-mode plan
}

# `clb` — claude with all approval prompts bypassed (use carefully).
alias clb='claude --dangerously-skip-permissions'
