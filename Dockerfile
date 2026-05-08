# syntax=docker/dockerfile:1.6
#
# Layers ordered by cache stability (top = most stable):
#   L1 (root): sudo + dev user                — never
#   L2 (dev):  apt packages + node            — rare
#   L3 (dev):  zsh dotfiles + uv              — moderate
#   L4 (dev):  torch / deepspeed / flash-attn — frequent
# Image USER is dev from L3 onward. PID 1 still needs root (UID remap /
# ssh-keygen); entrypoint.sh self-elevates via sudo, then drops back via
# `gosu dev` for the CMD. Username is hardcoded as `dev` everywhere — UID/GID
# are the only thing that vary at runtime (entrypoint reconciles to host).

ARG CUDA_BASE=12.9.1-cudnn-devel-ubuntu24.04
FROM nvidia/cuda:${CUDA_BASE} AS base

ARG DEBIAN_FRONTEND=noninteractive

ENV VENV_PATH=/opt/venv

# L1: bare minimum to safely switch USER.
# - Disable Ubuntu base's apt-clean so BuildKit cache mounts in L2 retain .debs.
# - Remove the default `ubuntu` user/group at UID/GID 1000 that ubuntu24.04
#   ships with, otherwise our `groupadd -g 1000 dev` collides.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update && apt-get install -y --no-install-recommends \
        sudo gosu zsh ca-certificates curl \
    && (userdel -r $(getent passwd 1000 | cut -d: -f1) 2>/dev/null || true) \
    && (groupdel $(getent group 1000 | cut -d: -f1) 2>/dev/null || true) \
    && groupadd -g 1000 dev \
    && useradd -m -u 1000 -g 1000 -s /usr/bin/zsh dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && echo 'Defaults env_keep += "http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY"' > /etc/sudoers.d/proxy-env \
    && chmod 0440 /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/proxy-env \
    && install -d -o dev -g dev ${VENV_PATH}

COPY files/jupyter_server_config.py /etc/jupyter/jupyter_server_config.py
COPY files/shell-aliases.sh /etc/profile.d/shell-aliases.sh
RUN echo 'for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done' \
        >> /etc/zsh/zshrc

USER dev
WORKDIR /home/dev

ENV HOME=/home/dev
ENV NPM_CONFIG_PREFIX=$HOME/.local/npm \
    NPM_CONFIG_CACHE=$HOME/.npm
ENV PATH="$HOME/.local/bin:$HOME/.local/npm/bin:${VENV_PATH}/bin:/usr/local/cuda/bin:${PATH}"

# L2: apt packages + node. sshd host keys are generated per-container in entrypoint.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && sudo apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev python3-setuptools \
        nano tree wget git pkg-config tmux unzip net-tools ncurses-term \
        build-essential g++ libstdc++6 libgcc-s1 ninja-build cmake make \
        libjpeg-dev libpng-dev libtiff-dev ffmpeg \
        openssh-server openssh-client pdsh \
    && echo 'Acquire::https::Verify-Peer "false";' | sudo tee /etc/apt/apt.conf.d/99proxy-insecure >/dev/null \
    && (curl -kfsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - || true) \
    && sudo apt-get install -y nodejs \
    && (command -v npm >/dev/null 2>&1 || sudo apt-get install -y npm) \
    && sudo rm -f /etc/apt/apt.conf.d/99proxy-insecure \
    && sudo mkdir -p /var/run/sshd

# L3: user-level installers (zsh dotfiles + uv).
# AI CLIs (claude/codex/gemini) are NOT installed at build time — see
# /usr/local/bin/setup-ai (COPY'd at the end of this file). Rationale: they
# update frequently, ~/.local isn't mounted across `make down/up`, and baking
# them would force an image rebuild on every CLI update.
RUN mkdir -p $HOME/.local/bin $HOME/.local/npm/bin $HOME/.local/npm/lib/node_modules \
    && curl -kfsSL "https://gist.githubusercontent.com/kangig94/b418ec255b0c9ad73b986459796801fd/raw/install_zsh_antidote_docker.sh" | GIT_SSL_NO_VERIFY=true bash \
    && if curl -kLsSf https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; then \
        sh /tmp/uv-install.sh; \
    else \
        python3 -m venv $HOME/.local/uv-bootstrap; \
        $HOME/.local/uv-bootstrap/bin/pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org uv; \
        ln -sf $HOME/.local/uv-bootstrap/bin/uv $HOME/.local/bin/uv; \
        ln -sf $HOME/.local/uv-bootstrap/bin/uvx $HOME/.local/bin/uvx; \
    fi \
    && command -v uv

# L4: heavy python deps. ARG/ENV declared here so version bumps only invalidate L4.
ARG PYTHON_VERSION="3.12"
ARG TORCH_VERSION="2.10.0"
ARG CUDA_TAG="cu128"
ARG MAX_JOBS=2

ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;10.0;10.3;12.0"
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=0 \
    UV_SYSTEM_CERTS=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Prepend torch wheel cuBLAS so it wins over base image's system libcublas
# (12.8 wheel vs 12.9 system, ABI-incompatible in cublasSgemmStridedBatched
# on torch >=2.10). System path preserved for user-built CUDA C++ extensions.
ENV LD_LIBRARY_PATH=${VENV_PATH}/lib/python${PYTHON_VERSION}/site-packages/nvidia/cublas/lib:${LD_LIBRARY_PATH}

RUN --mount=type=cache,target=/home/dev/.cache/uv,uid=1000,gid=1000 \
    UV_INSECURE_FLAGS="--allow-insecure-host download.pytorch.org --allow-insecure-host download-r2.pytorch.org --allow-insecure-host pypi.org --allow-insecure-host files.pythonhosted.org" \
    && uv venv ${VENV_PATH} --python ${PYTHON_VERSION} \
    && uv pip install ${UV_INSECURE_FLAGS} --upgrade pip setuptools wheel \
    && uv pip install ${UV_INSECURE_FLAGS} --no-build-isolation \
        torch==${TORCH_VERSION} torchvision torchaudio \
    && uv pip install ${UV_INSECURE_FLAGS} psutil ninja packaging \
    && MAX_JOBS=${MAX_JOBS} uv pip install ${UV_INSECURE_FLAGS} --no-build-isolation deepspeed accelerate \
    && MAX_JOBS=${MAX_JOBS} uv pip install ${UV_INSECURE_FLAGS} --no-build-isolation --prerelease=allow flash-attn-4 \
    && uv pip install ${UV_INSECURE_FLAGS} diffusers transformers peft datasets sentencepiece einops jupyterlab

# Image USER stays `dev` from L3 onward so `docker exec` (VS Code Attach,
# manual exec, etc.) defaults to dev. PID 1 still needs root for UID remap /
# ssh-keygen / ca-certs; entrypoint.sh re-execs itself via `sudo -E` to
# elevate, then drops back to dev with `gosu dev` for the CMD.
#
# This sudoers drop-in is needed for that self-elevate to behave like the
# original dev shell:
#   - `!secure_path`: sudo's secure_path otherwise overrides PATH (even with
#     -E), stripping /opt/venv/bin → the elevated entrypoint can't see
#     jupyter/python; the CMD that runs after `gosu dev` inherits the bad
#     PATH and fails with "command not found: jupyter".
#   - env_keep: preserve compose-injected vars + PATH/LD_LIBRARY_PATH across
#     Ubuntu's default `Defaults env_reset`. LD_LIBRARY_PATH carries the
#     torch wheel cuBLAS prepend (see ENV LD_LIBRARY_PATH below).
#
# Written via `sudo tee` (dev has NOPASSWD from L1) so this RUN can stay as
# the L3-inherited dev user — no `USER root` toggle needed.
RUN printf '%s\n' \
        'Defaults !secure_path' \
        'Defaults env_keep += "PATH LD_LIBRARY_PATH USER_UID USER_GID WORKSPACE_DIR CERT_DIR"' \
        | sudo tee /etc/sudoers.d/entrypoint-env > /dev/null \
    && sudo chmod 0440 /etc/sudoers.d/entrypoint-env \
    && sudo visudo -c -f /etc/sudoers.d/entrypoint-env

# AI CLI on-demand installer — run `setup-ai` from inside the container after
# `make up`. Idempotent; safe to re-run after `make down/up` recreations.
COPY --chmod=0755 scripts/install_ai_cli.sh /usr/local/bin/setup-ai

EXPOSE 8888 22 6006
CMD ["zsh", "-l"]
