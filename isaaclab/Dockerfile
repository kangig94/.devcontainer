# syntax=docker/dockerfile:1.6
#
# Isaac Lab variant — built on top of the base uv-torch image.
#
# Base provides: ubuntu24.04 + CUDA 12.9.1 + uv + torch 2.10.0 +
# zsh/claude/codex/gemini + system tooling + /opt/venv (chmod 777).
# This layer adds isaacsim (NVIDIA PyPI) and IsaacLab (git source).
#
# Replaces the legacy NGC nvcr.io/nvidia/isaac-sim:6.0.0-dev2 base.
# Removes the recursive chmod /isaac-sim layer (~10 min build), the
# 17-line PYTHONPATH/LD_LIBRARY_PATH ENV block, the LD_PRELOAD line,
# and the websockets-version manual upgrade hack — every one of those
# lived only because the NGC tarball wasn't a venv-managed package.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root

# IsaacLab's ./isaaclab.sh --install shells out to `apt-get install
# cmake build-essential` if cmake is absent. Bake them so the install
# never tries `sudo apt` (which fails under any sandbox with
# no_new_privileges, e.g. uv build hooks or Claude bash sandbox).
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake build-essential \
    && rm -rf /var/lib/apt/lists/*

ARG ISAACLAB_VERSION="v3.0.0-beta"
ENV ISAACLAB_PATH=/opt/isaaclab \
    ACCEPT_EULA=Y \
    PRIVACY_CONSENT=Y

# isaacsim 6.0.0 from NVIDIA PyPI mirror into the inherited /opt/venv.
# Flags explained:
#   --extra-index-url       NVIDIA mirror hosts the isaacsim-* wheels
#   --index-strategy        let uv mix nvidia mirror with default PyPI
#   --no-build-isolation    avoid uv re-fetching setuptools/wheel through
#                           the nvidia mirror (which times out / lacks them)
#   --prerelease=allow      tinyobjloader 2.0.0rc13 is a pre-release
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install \
        --extra-index-url https://pypi.nvidia.com \
        --index-strategy unsafe-best-match \
        --no-build-isolation \
        --prerelease=allow \
        "isaacsim[all,extscache]==6.0.0"

# First `import isaacsim` normally prompts on stdin for the Omniverse
# EULA. ACCEPT_EULA env var alone is not enough — the kit kernel reads
# the answer from stdin. Feed "Yes" once at build time so the accepted
# state is persisted in the image, and runtime imports skip the prompt.
RUN echo "Yes" | python -c "import isaacsim" 2>&1 | tail -3

# Isaac Lab: PyPI publishes only stable 2.3.x; v3.0.0-beta is git-only.
# Clone source at the desired tag and editable-install all submodules.
# `./isaaclab.sh --install` auto-detects the venv-installed isaacsim via
# extract_isaacsim_path -> import isaacsim -> os.environ['ISAAC_PATH'],
# then "Repointed N prebundled package(s)" rewires Isaac Sim's
# hash-suffixed extscache paths to live inside /opt/venv/site-packages.
RUN --mount=type=cache,target=/root/.cache/uv \
    git clone --depth 1 --branch ${ISAACLAB_VERSION} \
        https://github.com/isaac-sim/IsaacLab.git ${ISAACLAB_PATH} \
    && cd ${ISAACLAB_PATH} && ./isaaclab.sh --install

# Ports: SSH / Jupyter / Viser / Rerun / WebRTC signal / WebRTC stream
EXPOSE 8888 22 8012 9876 49100 47998
