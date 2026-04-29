# syntax=docker/dockerfile:1.6
#
# Layers ordered by cache stability (top = most stable):
#   L1 (root): sudo + dev user                — never
#   L2 (dev):  apt packages + node            — rare
#   L3 (dev):  zsh dotfiles + claude/uv       — moderate
#   L4 (dev):  torch / deepspeed / flash-attn — frequent
# Final USER root is for entrypoint UID/GID remap before `gosu dev`.

ARG CUDA_BASE=12.9.1-cudnn-devel-ubuntu24.04
FROM nvidia/cuda:${CUDA_BASE} AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=dev

# Persist USERNAME as ENV so child images (isaaclab/...) inherit it without
# re-declaring the ARG. Same for VENV_PATH used by LD_LIBRARY_PATH.
ENV USERNAME=${USERNAME} \
    VENV_PATH=/opt/venv

# L1: bare minimum to safely switch USER.
# Disable Ubuntu base's auto-clean so BuildKit apt cache mounts (used in L2)
# can actually retain downloaded .deb files across rebuilds.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update && apt-get install -y --no-install-recommends \
        sudo gosu zsh ca-certificates curl \
    && groupadd -g 1000 ${USERNAME} \
    && useradd -m -u 1000 -g 1000 -s /usr/bin/zsh ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && install -d -o ${USERNAME} -g ${USERNAME} ${VENV_PATH}

COPY files/jupyter_server_config.py /etc/jupyter/jupyter_server_config.py
COPY files/shell-aliases.sh /etc/profile.d/shell-aliases.sh
RUN echo 'for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done' \
        >> /etc/zsh/zshrc

USER ${USERNAME}
WORKDIR /home/${USERNAME}

ENV HOME=/home/${USERNAME}
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
    && curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - \
    && sudo apt-get install -y nodejs \
    && sudo mkdir -p /var/run/sshd

# L3: user-level installers.
RUN mkdir -p $HOME/.local/bin $HOME/.local/npm/bin $HOME/.local/npm/lib/node_modules \
    && curl -fsSL "https://gist.githubusercontent.com/kangig94/b418ec255b0c9ad73b986459796801fd/raw/install_zsh_antidote_docker.sh" | bash \
    && curl -kfsSL https://claude.ai/install.sh | bash \
    && npm install -g @openai/codex @google/gemini-cli \
    && curl -LsSf https://astral.sh/uv/install.sh | sh

# L4: heavy python deps. ARG/ENV declared here so version bumps only invalidate L4.
ARG PYTHON_VERSION="3.12"
ARG TORCH_VERSION="2.10.0"
ARG CUDA_TAG="cu128"
ARG MAX_JOBS=2

ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;10.0;10.3;12.0"
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Prepend torch wheel cuBLAS so it wins over base image's system libcublas
# (12.8 wheel vs 12.9 system, ABI-incompatible in cublasSgemmStridedBatched
# on torch >=2.10). System path preserved for user-built CUDA C++ extensions.
ENV LD_LIBRARY_PATH=${VENV_PATH}/lib/python${PYTHON_VERSION}/site-packages/nvidia/cublas/lib:${LD_LIBRARY_PATH}

RUN --mount=type=cache,target=/home/${USERNAME}/.cache/uv,uid=1000,gid=1000 \
    uv venv ${VENV_PATH} --python ${PYTHON_VERSION} \
    && uv pip install --upgrade pip setuptools wheel \
    && uv pip install --no-build-isolation --index-url https://download.pytorch.org/whl/${CUDA_TAG} \
        torch==${TORCH_VERSION} torchvision torchaudio \
    && uv pip install psutil ninja packaging \
    && MAX_JOBS=${MAX_JOBS} uv pip install --no-build-isolation deepspeed accelerate \
    && MAX_JOBS=${MAX_JOBS} uv pip install --no-build-isolation --prerelease=allow flash-attn-4 \
    && uv pip install diffusers transformers peft datasets sentencepiece einops jupyterlab

USER root
EXPOSE 8888 22 6006
CMD ["zsh", "-l"]
