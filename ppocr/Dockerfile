# syntax=docker/dockerfile:1.6
#
# PaddleOCR overlay on top of a cu126-torch base. Paddle's latest supported
# CUDA is 12.6, so the overlay image is tagged with CUDA_TAG=cu126 and uses
# the matching Paddle wheel index. The base CUDA toolkit stays aligned with
# the torch stack by default because torch owns its runtime CUDA libraries.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# USER=dev inherited from base. Privileged steps use sudo (NOPASSWD).

# OpenCV/Paddle runtime libs not in base.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    sudo apt-get update && sudo apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0

# PaddlePaddle wheel mirror is per-CUDA; keep it overridable for future cu127+.
ARG PADDLE_CUDA_TAG="cu126"
RUN --mount=type=cache,target=/home/dev/.cache/uv,uid=1000,gid=1000 \
    umask 0002 \
 && uv pip install paddlepaddle-gpu \
        --index-url https://www.paddlepaddle.org.cn/packages/stable/${PADDLE_CUDA_TAG}/ \
 && uv pip install paddleocr \
 && uv pip install shapely scikit-image pyclipper lmdb rapidfuzz \
        opencv-contrib-python cython albumentations \
 && find ${VENV_PATH:-/opt/venv} -type d \( ! -perm -0020 -o ! -perm -2000 \) -exec chmod g+rwx,g+s {} + \
 && find ${VENV_PATH:-/opt/venv} -type f ! -perm -0020 -exec chmod g+rwX {} +

EXPOSE 22 8888 6006
