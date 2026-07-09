# syntax=docker/dockerfile:1.6
#
# Lightweight Isaac Lab base.
# Keep only the shared runtime contract needed by isaaclab/Dockerfile:
#   - dev user with passwordless sudo
#   - uv-managed /opt/venv with Python + torch/torchvision/torchaudio
#   - Isaac Sim runtime system libraries
#   - baked entrypoint for UID/GID remapping
#
# Intentionally excluded: zsh, node/npm, jupyterlab, SSH server, tmux, AI CLIs,
# deepspeed, flash-attn, diffusers, transformers, datasets, and generic
# research tooling from the main uv-torch base image.

ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG DEBIAN_FRONTEND=noninteractive
ARG PYTHON_VERSION="3.12"
ARG TORCH_VERSION="2.10.0"
ARG CUDA_TAG="cu128"
ARG MAX_JOBS=2

ENV VENV_PATH=/opt/venv \
    VIRTUAL_ENV=/opt/venv \
    CUDA_HOME=/usr/local/cuda \
    CUDA_PATH=/usr/local/cuda \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics \
    HOME=/home/dev

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update && apt-get install -y --no-install-recommends \
        sudo gosu ca-certificates curl \
        git cmake build-essential \
        libstdc++6 libgcc-s1 libgomp1 \
        libxt6 libxrandr2 libxext6 libxi6 libxxf86vm1 \
        libxinerama1 libxcursor1 libxss1 libxtst6 libxkbfile1 \
        libfontconfig1 \
        libgl1 libglu1-mesa libegl1 libgles2 \
        libvulkan1 mesa-vulkan-drivers \
    && (userdel -r $(getent passwd 1000 | cut -d: -f1) 2>/dev/null || true) \
    && (groupdel $(getent group 1000 | cut -d: -f1) 2>/dev/null || true) \
    && groupadd -g 1000 dev \
    && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && echo 'Defaults env_keep += "http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY"' > /etc/sudoers.d/proxy-env \
    && chmod 0440 /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/proxy-env \
    && install -d -m 2775 -o dev -g dev ${VENV_PATH} \
    && mkdir -p ${CUDA_HOME}/include ${CUDA_HOME}/lib64 \
    && rm -f /etc/apt/apt.conf.d/keep-cache

USER dev
WORKDIR /home/dev

ENV PATH="$HOME/.local/bin:${VENV_PATH}/bin:${CUDA_HOME}/bin:${PATH}" \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=0 \
    UV_SYSTEM_CERTS=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;10.0;10.3;12.0"

RUN mkdir -p $HOME/.local/bin \
    && curl -kLsSf https://astral.sh/uv/install.sh -o /tmp/uv-install.sh \
    && sh /tmp/uv-install.sh \
    && rm -f /tmp/uv-install.sh \
    && command -v uv

ENV NVIDIA_PYTHON_SITE=${VENV_PATH}/lib/python${PYTHON_VERSION}/site-packages/nvidia
ENV NVIDIA_INCLUDE_PATHS=${NVIDIA_PYTHON_SITE}/cuda_runtime/include:${NVIDIA_PYTHON_SITE}/cudnn/include:${NVIDIA_PYTHON_SITE}/cublas/include:${NVIDIA_PYTHON_SITE}/cusparse/include:${NVIDIA_PYTHON_SITE}/cusparselt/include:${NVIDIA_PYTHON_SITE}/cusolver/include:${NVIDIA_PYTHON_SITE}/cufft/include:${NVIDIA_PYTHON_SITE}/curand/include:${NVIDIA_PYTHON_SITE}/nccl/include:${NVIDIA_PYTHON_SITE}/nvshmem/include:${NVIDIA_PYTHON_SITE}/cuda_nvrtc/include:${NVIDIA_PYTHON_SITE}/cuda_cupti/include:${NVIDIA_PYTHON_SITE}/nvtx/include:${NVIDIA_PYTHON_SITE}/cufile/include
ENV NVIDIA_LIBRARY_PATHS=${NVIDIA_PYTHON_SITE}/cudnn/lib:${NVIDIA_PYTHON_SITE}/nvshmem/lib:${NVIDIA_PYTHON_SITE}/nccl/lib:${NVIDIA_PYTHON_SITE}/cusparselt/lib:${NVIDIA_PYTHON_SITE}/cublas/lib:${NVIDIA_PYTHON_SITE}/cuda_cupti/lib:${NVIDIA_PYTHON_SITE}/cuda_nvrtc/lib:${NVIDIA_PYTHON_SITE}/cuda_runtime/lib:${NVIDIA_PYTHON_SITE}/cufft/lib:${NVIDIA_PYTHON_SITE}/curand/lib:${NVIDIA_PYTHON_SITE}/cusolver/lib:${NVIDIA_PYTHON_SITE}/cusparse/lib:${NVIDIA_PYTHON_SITE}/nvtx/lib:${NVIDIA_PYTHON_SITE}/cufile/lib
ENV CPATH=${CUDA_HOME}/include:${NVIDIA_INCLUDE_PATHS}:${CPATH}
ENV LIBRARY_PATH=${CUDA_HOME}/lib64:${NVIDIA_LIBRARY_PATHS}:${LIBRARY_PATH}
ENV LD_LIBRARY_PATH=${NVIDIA_LIBRARY_PATHS}:${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}

RUN --mount=type=cache,target=/home/dev/.cache/uv,uid=1000,gid=1000 \
    UV_INSECURE_FLAGS="--allow-insecure-host download.pytorch.org --allow-insecure-host download-r2.pytorch.org --allow-insecure-host pypi.org --allow-insecure-host files.pythonhosted.org" \
    && umask 0002 \
    && UV_TORCH_BACKEND=${CUDA_TAG} uv venv ${VENV_PATH} --python ${PYTHON_VERSION} \
    && UV_TORCH_BACKEND=${CUDA_TAG} uv pip install ${UV_INSECURE_FLAGS} --upgrade pip setuptools wheel \
    && UV_TORCH_BACKEND=${CUDA_TAG} uv pip install ${UV_INSECURE_FLAGS} --no-build-isolation \
        torch==${TORCH_VERSION} torchvision torchaudio==${TORCH_VERSION} \
    && for include_dir in ${NVIDIA_PYTHON_SITE}/*/include; do \
        [ -d "$include_dir" ] || continue; \
        find "$include_dir" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.cuh' \) -print | while IFS= read -r header; do \
            rel="${header#$include_dir/}"; \
            dest="${CUDA_HOME}/include/$rel"; \
            [ -e "$dest" ] || { sudo mkdir -p "$(dirname "$dest")" && sudo ln -s "$header" "$dest"; }; \
        done; \
    done \
    && for lib_dir in ${NVIDIA_PYTHON_SITE}/*/lib; do \
        [ -d "$lib_dir" ] || continue; \
        find "$lib_dir" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) -print | while IFS= read -r lib; do \
            base="$(basename "$lib")"; \
            dest="${CUDA_HOME}/lib64/$base"; \
            [ -e "$dest" ] || sudo ln -s "$lib" "$dest"; \
            case "$base" in \
                *.so.*) unversioned="${base%%.so.*}.so"; [ -e "${CUDA_HOME}/lib64/$unversioned" ] || sudo ln -s "$base" "${CUDA_HOME}/lib64/$unversioned" ;; \
            esac; \
        done; \
    done \
    && find ${VENV_PATH} -type d \( -name tests -o -name test -o -name __pycache__ \) -prune -exec rm -rf {} + \
    && find ${VENV_PATH} -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete \
    && find ${VENV_PATH} -type d \( ! -perm -0020 -o ! -perm -2000 \) -exec chmod g+rwx,g+s {} + \
    && find ${VENV_PATH} -type f ! -perm -0020 -exec chmod g+rwX {} +

RUN printf '%s\n' \
        'Defaults !secure_path' \
        'Defaults env_keep += "PATH LD_LIBRARY_PATH CPATH LIBRARY_PATH CUDA_HOME CUDA_PATH USER_UID USER_GID WORKSPACE_DIR CERT_DIR"' \
        | sudo tee /etc/sudoers.d/entrypoint-env > /dev/null \
    && sudo chmod 0440 /etc/sudoers.d/entrypoint-env \
    && sudo visudo -c -f /etc/sudoers.d/entrypoint-env

COPY --chmod=0755 scripts/baked_entrypoint.sh /usr/local/bin/devcontainer-entrypoint

ENTRYPOINT ["/usr/local/bin/devcontainer-entrypoint"]
CMD ["bash", "-l"]
