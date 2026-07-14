# syntax=docker/dockerfile:1.6
#
# Isaac Lab variant — built on top of either the generic uv-torch image or the
# lightweight isaaclab-base image (`make build-isaaclab isolate=true`).
#
# Replaces the legacy NGC nvcr.io/nvidia/isaac-sim:6.0.0-dev2 base. That
# removed the recursive chmod /isaac-sim layer (~10 min build), the
# 17-line PYTHONPATH/LD_LIBRARY_PATH ENV block, the LD_PRELOAD line, and
# the websockets-version manual upgrade hack — every one of those existed
# only because the NGC tarball wasn't a venv-managed package.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# USER=dev inherited from the base image. Privileged steps use sudo
# (NOPASSWD baked into isaaclab/base/Dockerfile).
ARG ISAACLAB_VERSION="v3.0.0-beta2.patch1"
ARG OFFLINE_ASSETS="false"
ARG ISAAC_ASSET_ROOT=""
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:${PATH} \
    ISAACLAB_PATH=/opt/isaaclab \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics \
    ACCEPT_EULA=Y \
    PRIVACY_CONSENT=Y \
    TERM=xterm-256color
COPY isaaclab/versions /tmp/isaaclab-versions

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update \
 && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libstdc++6 libgcc-s1 libgomp1 \
        libxt6 libxrandr2 libxext6 libxi6 libxxf86vm1 \
        libxinerama1 libxcursor1 libxss1 libxtst6 libxkbfile1 \
        libfontconfig1 \
        libgl1 libglu1-mesa libegl1 libgles2 \
        libvulkan1 mesa-vulkan-drivers \
 && sudo install -d -m 2775 -o dev -g dev ${ISAACLAB_PATH}

# isaacsim from NVIDIA PyPI mirror + IsaacLab git editable install.
#   --no-build-isolation: avoid uv fetching setuptools/wheel through the
#                         nvidia mirror (times out / lacks them)
# `echo "Yes" | python -c "import isaacsim"` accepts the Omniverse EULA at
# build time. ACCEPT_EULA env alone isn't enough — kit kernel reads the
# answer from stdin on first import; once accepted it persists in
# ~/.nvidia-omniverse/. Must run as dev so the file lands in the user home
# that the runtime (`gosu dev`) actually uses.
RUN --mount=type=cache,target=/home/dev/.cache/uv,uid=1000,gid=1000 \
    umask 0002 \
 && . "/tmp/isaaclab-versions/${ISAACLAB_VERSION}.env" \
 && { \
        echo "torch==${TORCH_VERSION}"; \
        [ -z "${NUMPY_VERSION:-}" ] || echo "numpy==${NUMPY_VERSION}"; \
        [ -z "${PSUTIL_VERSION:-}" ] || echo "psutil==${PSUTIL_VERSION}"; \
        [ -z "${IPYTHON_VERSION:-}" ] || echo "ipython==${IPYTHON_VERSION}"; \
        [ -z "${TYPING_EXTENSIONS_VERSION:-}" ] || echo "typing_extensions==${TYPING_EXTENSIONS_VERSION}"; \
        [ -z "${SKRL_MIN_VERSION:-}${SKRL_MAX_VERSION:-}" ] || \
            echo "skrl>=${SKRL_MIN_VERSION:?},<${SKRL_MAX_VERSION:?}"; \
    } > /tmp/isaaclab-constraints.txt \
 && printf '%s\n' 'setuptools==70.3.0' > /tmp/isaaclab-build-constraints.txt \
 && uv pip install \
        --extra-index-url https://pypi.nvidia.com \
        --index-strategy unsafe-best-match \
        --no-build-isolation \
        --prerelease=allow \
        "isaacsim[all,extscache]==${ISAACSIM_VERSION}" \
 && echo "Yes" | python -c "import isaacsim" 2>&1 | tail -3 \
 && GIT_SSL_NO_VERIFY=true git clone --depth 1 --branch ${ISAACLAB_VERSION} \
        https://github.com/isaac-sim/IsaacLab.git ${ISAACLAB_PATH} \
 && if [ "${OFFLINE_ASSETS}" = "true" ]; then \
        test -n "${ISAAC_ASSET_ROOT}"; \
        set -- ${ISAACLAB_PATH}/apps/isaaclab.python*.kit; \
        test -e "$1"; \
        sed -i -E \
          "s#^(persistent\\.isaac\\.asset_root\\.(default|cloud|nvidia))[[:space:]]*=.*#\\1 = \"${ISAAC_ASSET_ROOT}\"#" \
          "$@"; \
        grep -H 'persistent.isaac.asset_root' "$@"; \
    fi \
 && uv pip install "setuptools==70.3.0" \
 && python -c "import pkg_resources" \
 && uv pip install --no-build-isolation "flatdict==4.0.1" \
 && if [ -n "${IPYTHON_VERSION:-}" ]; then uv pip install "ipython==${IPYTHON_VERSION}"; fi \
 && cd ${ISAACLAB_PATH} \
 && GIT_SSL_NO_VERIFY=true \
    UV_CONSTRAINT=/tmp/isaaclab-constraints.txt \
    UV_BUILD_CONSTRAINT=/tmp/isaaclab-build-constraints.txt \
    UV_TORCH_BACKEND=${CUDA_TAG} \
    UV_EXTRA_INDEX_URL=https://pypi.nvidia.com \
    UV_INDEX_STRATEGY=unsafe-best-match \
    PIP_CONSTRAINT=/tmp/isaaclab-constraints.txt \
    PIP_BUILD_CONSTRAINT=/tmp/isaaclab-build-constraints.txt \
    PIP_EXTRA_INDEX_URL=https://pypi.nvidia.com \
    ./isaaclab.sh --install \
 && uv pip install --constraint /tmp/isaaclab-constraints.txt rerun-sdk \
 && if [ -n "${NCCL_VERSION:-}" ]; then \
        uv pip install --no-deps --reinstall "nvidia-nccl-cu12==${NCCL_VERSION}"; \
        python -c "import importlib.metadata as m; assert m.version('nvidia-nccl-cu12') == '${NCCL_VERSION}'"; \
    fi \
 && find ${VENV_PATH:-/opt/venv} -type d \( ! -perm -0020 -o ! -perm -2000 \) -exec chmod g+rwx,g+s {} + \
 && find ${VENV_PATH:-/opt/venv} -type f ! -perm -0020 -exec chmod g+rwX {} +

# Ports: Viser / Tensorboard / Rerun / WebRTC signal / WebRTC stream
EXPOSE 8080 6006 9876 49100 47998
