# syntax=docker/dockerfile:1.6
#
# PaddleOCR overlay on top of a cu126-torch base. Paddle's latest supported
# CUDA is 12.6, so the base must be built with CUDA_TAG=cu126. CUDA_BASE
# (system libs) can stay at the default 12.9.x — paddle wheels bundle their
# own CUDA libs, so newer system libs are harmless.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER ${USERNAME}

# OpenCV/Paddle runtime libs not in base.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && sudo apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0

# PaddlePaddle wheel mirror is per-CUDA; keep it overridable for future cu127+.
ARG PADDLE_CUDA_TAG="cu126"
RUN --mount=type=cache,target=/home/${USERNAME}/.cache/uv,uid=1000,gid=1000 \
    uv pip install paddlepaddle-gpu \
        --index-url https://www.paddlepaddle.org.cn/packages/stable/${PADDLE_CUDA_TAG}/ \
 && uv pip install paddleocr \
 && uv pip install shapely scikit-image pyclipper lmdb rapidfuzz \
        opencv-contrib-python cython albumentations

USER root
EXPOSE 22 8888 6006
