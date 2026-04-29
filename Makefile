.PHONY: build up down shell up-local down-local shell-local \
        up-server down-server shell-server \
        build-multinode up-multinode down-multinode shell-multinode \
        build-isaaclab up-isaaclab down-isaaclab shell-isaaclab sim \
        build-ppocr up-ppocr down-ppocr shell-ppocr help run

# Auto-detect UID/GID for runtime (exported: compose env references these).
# entrypoint.sh remaps the baked dev user (UID 1000) to match at startup.
export USER_UID := $(shell id -u)
export USER_GID := $(shell id -g)

# ML-specific versions (NOT exported: passed via ML_ENV prefix per target)
py ?= 3.12
torch ?= 2.10.0
cu ?= 128
cuda_base ?= 12.9.1-cudnn-devel-ubuntu24.04

PYTHON_VERSION := $(py)
PY_TAG := py$(subst .,,$(py))
TORCH_VERSION := $(torch)
CUDA_TAG := cu$(cu)
CUDA_BASE := $(cuda_base)

# flash-attn / deepspeed source builds use ~4-8GB RAM per job.
# nproc/2 (the old default) on a 32-core box demanded ~128GB and froze
# both ing and h9 to a hard reboot. Hold at 2 unless explicitly raised.
MAX_JOBS ?= 2

ML_ENV := PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=$(CUDA_TAG) CUDA_BASE=$(CUDA_BASE) MAX_JOBS=$(MAX_JOBS)

# Paddle's latest supported CUDA is 12.6 — override CUDA_TAG so the base
# torch wheel is cu126. CUDA_BASE (system libs) stays at the default 12.9.x;
# paddle wheels bundle their own CUDA libs so newer system libs are fine.
PADDLE_ENV := PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=cu126 CUDA_BASE=$(CUDA_BASE) MAX_JOBS=$(MAX_JOBS)

COMPOSE_FLAGS := --env-file compose/.env
BUILD_FLAGS := $(if $(verbose),--progress=plain,)

.DEFAULT_GOAL := help

help:
	@echo "ML Research Dev Container - Makefile Commands"
	@echo ""
	@echo "Version settings (override on command line):"
	@echo "  py=3.12 (default)      -> image tag prefix py312-..."
	@echo "  torch=2.10.0 (default) -> image tag ...-2.10.0-..."
	@echo "  cu=128 (default)       -> image tag ...-cu128-..."
	@echo "  cuda_base=12.9.1-cudnn-devel-ubuntu24.04 (default) -> FROM nvidia/cuda:..."
	@echo "  MAX_JOBS=2 (default)   -> parallel jobs for source builds"
	@echo ""
	@echo "Example:"
	@echo "  make build py=3.10 torch=2.5.1 cu=124 cuda_base=12.4.1-cudnn-devel-ubuntu22.04"
	@echo ""
	@echo "Base image:"
	@echo "  make build         - Build base image"
	@echo "  make up            - Start container (alias for up-local)"
	@echo "  make down          - Stop container"
	@echo "  make shell         - Access shell"
	@echo "  make run           - build + up + shell"
	@echo ""
	@echo "Variants by environment (up/down/shell only):"
	@echo "  make up-local      - With local-only mounts (Git creds, etc.)"
	@echo "  make up-server     - NAS mounts only, no local settings"
	@echo ""
	@echo "PaddleOCR (auto-builds a cu126 base then layers ppocr):"
	@echo "  make build-ppocr   - Build cu126 base + PaddleOCR overlay"
	@echo "  make up-ppocr      - Start PaddleOCR container"
	@echo "  make down-ppocr    - Stop PaddleOCR container"
	@echo "  make shell-ppocr   - Access PaddleOCR shell"
	@echo ""
	@echo "Multi-Node Training (DeepSpeed distributed):"
	@echo "  make build-multinode - Build multinode overlay (depends on base)"
	@echo "  make up-multinode    - Start multinode container"
	@echo "  make down-multinode  - Stop multinode container"
	@echo "  make shell-multinode - Access multinode container shell"
	@echo ""
	@echo "Isaac Lab (Isaac Sim + IsaacLab):"
	@echo "  make build-isaaclab  - Build Isaac Lab overlay (depends on base)"
	@echo "  make up-isaaclab     - Start container"
	@echo "  make sim             - Launch Isaac Sim GUI (requires display)"
	@echo "  make down-isaaclab   - Stop container"
	@echo "  make shell-isaaclab  - Access container shell (dev user)"
	@echo ""
	@echo "Root access (one-off, no separate image needed):"
	@echo "  docker exec -u root <container> <cmd>"

# ============================================
# Base image build (single command for all envs)
# ============================================

build:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

# Default `up`/`down`/`shell` use the local overlay (Git creds etc.).
up: up-local
down: down-local
shell: shell-local

# Build and run in one command
run: build up shell

# ============================================
# Up/down/shell variants
# ============================================

up-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml up -d

down-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml down

shell-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml exec -u dev lab zsh

up-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml up -d

down-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml down

shell-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml exec -u dev lab zsh

# ============================================
# PaddleOCR overlay (cu126 base + paddle on top)
# ============================================

build-ppocr:
	# 1. Build a cu126-flavored base (paddle's latest supported CUDA).
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)
	# 2. Layer the ppocr overlay on top.
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml build $(BUILD_FLAGS)

up-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml up -d

down-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml down

shell-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml exec -u dev lab zsh

# ============================================
# Multi-node training overlay (DeepSpeed)
# ============================================

build-multinode: build
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml build $(BUILD_FLAGS)

up-multinode:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml up -d

down-multinode:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml down

shell-multinode:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml exec -u dev lab zsh

# ============================================
# Isaac Lab overlay (isaacsim + IsaacLab editable install)
# ============================================

build-isaaclab: build
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml build $(BUILD_FLAGS)

sim:
	xhost +local: > /dev/null 2>&1
	docker exec -u dev isaaclab-lab-1 /opt/isaaclab/isaaclab.sh -s

up-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml up -d

down-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml down

shell-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml exec -u dev lab zsh
