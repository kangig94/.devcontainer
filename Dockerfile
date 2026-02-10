# syntax=docker/dockerfile:1.6
FROM nvidia/cuda:12.9.1-cudnn-devel-ubuntu24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Layer 1: Base system + SSH setup
# ------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-dev python3-setuptools \
    nano tree ca-certificates curl wget git pkg-config tmux unzip net-tools \
    build-essential g++ libstdc++6 libgcc-s1 ninja-build cmake make \
    libjpeg-dev libpng-dev libtiff-dev ffmpeg \
    openssh-server openssh-client pdsh \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && ssh-keygen -A \
    && echo "PermitRootLogin yes" >> /etc/ssh/sshd_config \
    && echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config \
    && echo "PasswordAuthentication no" >> /etc/ssh/sshd_config \
    && echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config \
    && echo "UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config

# ------------------------------------------------------------
# Layer 2: zsh + antidote
# ------------------------------------------------------------
RUN curl -fsSL \
    "https://gist.githubusercontent.com/kangig94/b418ec255b0c9ad73b986459796801fd/raw/install_zsh_antidote_docker.sh" \
    | bash

# ------------------------------------------------------------
# Layer 3: Node.js + Claude Code + Codex + Gemini
# ------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && curl -kfsSL https://claude.ai/install.sh | bash \
    && CLAUDE_VER=$(ls /root/.local/share/claude/versions/) \
    && mkdir -p /opt/claude \
    && mv /root/.local/share/claude/versions/${CLAUDE_VER} /opt/claude/ \
    && chmod -R 755 /opt/claude \
    && rm -rf /root/.local/share/claude /root/.local/bin/claude /root/.local/bin/env /root/.local/bin/env.fish \
    && ln -s /opt/claude/${CLAUDE_VER} /usr/local/bin/claude \
    && sed -i 's/^\. "\$HOME\/\.local\/bin\/env"$/[ -f "\$HOME\/.local\/bin\/env" ] \&\& . "\$HOME\/.local\/bin\/env"/' /root/.bashrc /root/.profile 2>/dev/null || true \
    && npm install -g @openai/codex \
    && npm install -g @google/gemini-cli \
    && mv /root/.npm /opt/.npm \
    && chmod -R 777 /opt/.npm

ENV PATH="/root/.local/bin:${PATH}"
ENV NPM_CONFIG_CACHE=/opt/.npm

# ------------------------------------------------------------
# Layer 4: uv + Python venv + Shell aliases
# ------------------------------------------------------------
ARG PYTHON_VERSION="3.12"
ENV VENV_PATH=/opt/venv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv venv ${VENV_PATH} --python ${PYTHON_VERSION} \
    && echo 'for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done' >> /etc/zsh/zshrc \
    && cat > /etc/profile.d/shell-aliases.sh <<'ALIASES'
# uv wrapper: `uv a` or `uv activate` to source .venv/bin/activate
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
# Claude Code worktree launcher
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
ALIASES

ENV PATH="${VENV_PATH}/bin:${PATH}"
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /root

# ------------------------------------------------------------
# Layer 5: Python deps + Jupyter config
# ------------------------------------------------------------
# Multi-GPU architecture support: A100(8.0), RTX30(8.6), RTX40(8.9), H100(9.0), B100(10.0), RTX50(12.0)
ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;10.0;10.3;12.0"

ARG TORCH_VERSION="2.9.1"
ARG CUDA_TAG="cu128"
ARG MAX_JOBS=4

RUN uv pip install --upgrade pip setuptools wheel \
    && uv pip install --no-build-isolation --index-url https://download.pytorch.org/whl/${CUDA_TAG} torch==${TORCH_VERSION} torchvision \
    && uv pip install psutil ninja packaging \
    && MAX_JOBS=${MAX_JOBS} uv pip install --no-build-isolation deepspeed accelerate flash-attn \
    && uv pip install diffusers transformers peft datasets sentencepiece einops \
    && uv pip install jupyterlab \
    && rm -rf /root/.cache/uv /root/.cache/pip \
    && mkdir -p /etc/jupyter && cat > /etc/jupyter/jupyter_server_config.py <<'EOF'
import os
c = get_config()
c.ServerApp.ip = "0.0.0.0"
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_remote_access = True
c.ServerApp.token = ""
c.ServerApp.password = ""
c.ServerApp.disable_check_xsrf = True
c.ServerApp.root_dir = os.environ.get("HOME", "/root")
c.ServerApp.allow_root = os.getuid() == 0
EOF

EXPOSE 8888 22

# ============================================================
# Target: root (run as root user)
# ============================================================
FROM base AS root

ENV HOME=/root
ENV PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.opencode/bin:${VENV_PATH}/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SHELL ["/usr/bin/zsh", "-lc"]
CMD ["zsh", "-l"]

# ============================================================
# Target: user (run as non-root user) - DEFAULT
# ============================================================
FROM base AS user

ARG USER_UID=1000
ARG USER_GID=1000
ARG USERNAME=dev

RUN apt-get update && apt-get install -y --no-install-recommends sudo gosu \
    && rm -rf /var/lib/apt/lists/* \
    && (userdel -r $(getent passwd ${USER_UID} | cut -d: -f1) 2>/dev/null || true) \
    && (groupdel $(getent group ${USER_GID} | cut -d: -f1) 2>/dev/null || true) \
    && groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -m -u ${USER_UID} -g ${USER_GID} -s /usr/bin/zsh ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && find /root -maxdepth 1 -name '.*' ! -name '.' ! -name '..' -exec mv {} /home/${USERNAME}/ \; \
    && mkdir -p /home/${USERNAME}/.ssh /home/${USERNAME}/.cache \
    && chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.ssh /home/${USERNAME}/.zshrc /home/${USERNAME}/.zsh* /home/${USERNAME}/.antidote* 2>/dev/null || true \
    && chmod 700 /home/${USERNAME}/.ssh \
    && chmod 777 /home/${USERNAME}/.cache \
    && chmod -R 777 /opt/venv \
    && sed -i 's/compinit/compinit -u/' /home/${USERNAME}/.zshrc 2>/dev/null || true

WORKDIR /home/${USERNAME}

ENV HOME=/home/${USERNAME}
ENV PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.opencode/bin:${VENV_PATH}/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CMD ["zsh", "-l"]
