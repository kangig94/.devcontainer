# syntax=docker/dockerfile:1.6
#
# Isaac Lab variant — built on top of the base uv-torch image.
#
# Replaces the legacy NGC nvcr.io/nvidia/isaac-sim:6.0.0-dev2 base. That
# removed the recursive chmod /isaac-sim layer (~10 min build), the
# 17-line PYTHONPATH/LD_LIBRARY_PATH ENV block, the LD_PRELOAD line, and
# the websockets-version manual upgrade hack — every one of those existed
# only because the NGC tarball wasn't a venv-managed package.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# USERNAME inherited as ENV from base image.
ARG ISAACSIM_VERSION="6.0.0"
ARG ISAACLAB_VERSION="v3.0.0-beta"
ENV ISAACLAB_PATH=/opt/isaaclab \
    ACCEPT_EULA=Y \
    PRIVACY_CONSENT=Y

USER ${USERNAME}

# X11/OpenGL/Vulkan libs the slim cuda base lacks. Without these:
#   libXt.so.6 / libGLU.so.1: cannot open shared object file
#   Vulkan ERROR_INCOMPATIBLE_DRIVER
#   PhysXFoundation: Unable to create GPU Foundation
#   -> torch.bmm raises CUBLAS_STATUS_INVALID_VALUE at first reset.
# (cmake/build-essential already in base L2.)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && sudo apt-get install -y --no-install-recommends \
        libxt6 libxrandr2 libxext6 libxi6 libxxf86vm1 \
        libxinerama1 libxcursor1 libxss1 libxtst6 libxkbfile1 \
        libfontconfig1 libgomp1 \
        libgl1 libglu1-mesa libegl1 libgles2 \
        libvulkan1 mesa-vulkan-drivers \
    && sudo install -d -o ${USERNAME} -g ${USERNAME} ${ISAACLAB_PATH}

# isaacsim from NVIDIA PyPI mirror + IsaacLab git editable install.
#   --no-build-isolation: avoid uv fetching setuptools/wheel through the
#                         nvidia mirror (times out / lacks them)
# `echo "Yes" | python -c "import isaacsim"` accepts the Omniverse EULA at
# build time. ACCEPT_EULA env alone isn't enough — kit kernel reads the
# answer from stdin on first import; once accepted it persists in
# ~/.nvidia-omniverse/. Must run as ${USERNAME} so the file lands in the
# user home that the runtime (`gosu dev`) actually uses.
RUN --mount=type=cache,target=/home/${USERNAME}/.cache/uv,uid=1000,gid=1000 \
    uv pip install \
        --extra-index-url https://pypi.nvidia.com \
        --index-strategy unsafe-best-match \
        --no-build-isolation \
        --prerelease=allow \
        "isaacsim[all,extscache]==${ISAACSIM_VERSION}" \
 && echo "Yes" | python -c "import isaacsim" 2>&1 | tail -3 \
 && git clone --depth 1 --branch ${ISAACLAB_VERSION} \
        https://github.com/isaac-sim/IsaacLab.git ${ISAACLAB_PATH} \
 && cd ${ISAACLAB_PATH} && ./isaaclab.sh --install \
 && uv pip install rerun-sdk

USER root

# Ports: SSH / Jupyter / Viser / Tensorboard / Rerun /WebRTC signal / WebRTC stream
EXPOSE 22 8888 8080 6006 9876 49100 47998
