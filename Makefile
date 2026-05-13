.PHONY: build up down shell run \
        build-multinode up-multinode down-multinode shell-multinode \
        build-isaaclab up-isaaclab down-isaaclab shell-isaaclab sim \
        build-ppocr up-ppocr down-ppocr shell-ppocr \
        push push-ppocr push-isaaclab ci-env ci-build ci-push ci help

# Auto-detect UID/GID for runtime (exported: compose env references these).
# entrypoint.sh remaps the baked dev user (UID 1000) to match at startup.
export USER_UID := $(shell id -u)
export USER_GID := $(shell id -g)

# ML-specific versions (NOT exported: passed via ML_ENV prefix per target)
py ?= 3.12
torch ?= 2.10.0
cu ?= 128
ubuntu ?= 24.04
cuda_toolkit ?= 12-8
isaacsim ?= 6.0.0
isaaclab ?= v3.0.0-beta

PYTHON_VERSION := $(py)
PY_TAG := py$(subst .,,$(py))
TORCH_VERSION := $(torch)
CUDA_TAG := cu$(cu)
UBUNTU_VERSION := $(ubuntu)
CUDA_TOOLKIT_VERSION := $(cuda_toolkit)
ISAACSIM_VERSION := $(isaacsim)
ISAACLAB_VERSION := $(isaaclab)
ISAACLAB_TAG := $(patsubst v%,%,$(ISAACLAB_VERSION))

# flash-attn / deepspeed source builds use ~4-8GB RAM per job.
# nproc/2 (the old default) on a 32-core box demanded ~128GB and froze
# both ing and h9 to a hard reboot. Hold at 2 unless explicitly raised.
MAX_JOBS ?= 2

ML_ENV := PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=$(CUDA_TAG) UBUNTU_VERSION=$(UBUNTU_VERSION) CUDA_TOOLKIT_VERSION=$(CUDA_TOOLKIT_VERSION) MAX_JOBS=$(MAX_JOBS)
ISAACLAB_ENV := $(ML_ENV) ISAACSIM_VERSION=$(ISAACSIM_VERSION) ISAACLAB_VERSION=$(ISAACLAB_VERSION) ISAACLAB_TAG=$(ISAACLAB_TAG)

# Paddle's latest supported CUDA is 12.6 — override the image tag so the
# Paddle wheel index follows cu126. The base toolkit stays on the torch stack
# by default because torch owns its CUDA runtime through nvidia-* wheels.
PADDLE_ENV := PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=cu126 UBUNTU_VERSION=$(UBUNTU_VERSION) CUDA_TOOLKIT_VERSION=$(CUDA_TOOLKIT_VERSION) MAX_JOBS=$(MAX_JOBS)

COMPOSE_FLAGS := --env-file compose/.env
BUILD_FLAGS := $(if $(verbose),--progress=plain,)
target ?= base
push ?= true

.DEFAULT_GOAL := help

help:
	@echo "ML Research Dev Container - Makefile Commands"
	@echo ""
	@echo "Version settings (override on command line):"
	@echo "  py=3.12 (default)      -> image tag prefix py312-..."
	@echo "  torch=2.10.0 (default) -> image tag ...-2.10.0-..."
	@echo "  cu=128 (default)       -> image tag ...-cu128-..."
	@echo "  ubuntu=24.04 (default) -> FROM ubuntu:..."
	@echo "  cuda_toolkit=12-8 (default) -> minimal nvcc/cudart-dev apt packages"
	@echo "  isaacsim=6.0.0 (default) -> Isaac Sim PyPI package version"
	@echo "  isaaclab=v3.0.0-beta (default) -> IsaacLab git tag; image tag drops leading v"
	@echo "  MAX_JOBS=2 (default)   -> parallel jobs for source builds"
	@echo ""
	@echo "Example:"
	@echo "  make build py=3.10 torch=2.5.1 cu=124 cuda_toolkit=12-4"
	@echo ""
	@echo "Base image:"
	@echo "  make build         - Build base image"
	@echo "  make push          - Push base image"
	@echo "  make up            - Start container"
	@echo "  make down          - Stop container"
	@echo "  make shell         - Access shell"
	@echo "  make run           - build + up + shell"
	@echo ""
	@echo "PaddleOCR (auto-builds a cu126 base then layers ppocr):"
	@echo "  make build-ppocr   - Build cu126 base + PaddleOCR overlay"
	@echo "  make push-ppocr    - Push cu126 base + PaddleOCR overlay"
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
	@echo "  make push-isaaclab   - Push base + Isaac Lab overlay"
	@echo "  make up-isaaclab     - Start container"
	@echo "  make sim             - Launch Isaac Sim GUI (requires display)"
	@echo "  make down-isaaclab   - Stop container"
	@echo "  make shell-isaaclab  - Access container shell"
	@echo ""
	@echo "CI:"
	@echo "  make ci target=base|ppocr|isaaclab push=true"
	@echo ""
	@echo "AI CLI install (run inside container after first up):"
	@echo "  setup-ai           - Install Claude / Codex / Gemini (idempotent)"
	@echo ""
	@echo "Root access (one-off, no separate image needed):"
	@echo "  docker exec -u root <container> <cmd>"

# ============================================
# Base image build (single command for all envs)
# ============================================

build:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

push:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml config --images | xargs -r -n 1 docker push

up:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml up -d

down:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml down

shell:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml exec lab zsh

# Build and run in one command
run: build up shell

# ============================================
# PaddleOCR overlay (cu126 base + paddle on top)
# ============================================

build-ppocr:
	# 1. Build a cu126-flavored base (paddle's latest supported CUDA).
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)
	# 2. Layer the ppocr overlay on top.
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml build $(BUILD_FLAGS)

push-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml config --images | xargs -r -n 1 docker push
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml config --images | xargs -r -n 1 docker push

up-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml up -d

down-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml down

shell-ppocr:
	$(PADDLE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml exec lab zsh

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
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml exec lab zsh

# ============================================
# Isaac Lab overlay (isaacsim + IsaacLab editable install)
# ============================================

build-isaaclab: build
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml build $(BUILD_FLAGS)

push-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml config --images | xargs -r -n 1 docker push
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml config --images | xargs -r -n 1 docker push

sim:
	xhost +local: > /dev/null 2>&1
	docker exec isaaclab-lab-1 /opt/isaaclab/isaaclab.sh -s

up-isaaclab:
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml up -d

down-isaaclab:
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml down

shell-isaaclab:
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml exec lab zsh

# ============================================
# CI entrypoint (GitHub Actions calls this)
# ============================================

ci-env:
	@if [ "$(GITHUB_ACTIONS)" = "true" ] || [ ! -f compose/.env ]; then \
		test -n "$(DOCKER_REGISTRY)" || { echo "DOCKER_REGISTRY is required"; exit 1; }; \
		mkdir -p compose; \
		{ \
			echo "DOCKER_REGISTRY=$(DOCKER_REGISTRY)"; \
			echo "NAS_HOME=/tmp"; \
			echo "HOST_WORKSPACE_DIR=/tmp"; \
			echo "HOST_CACHE_DIR=/tmp"; \
			echo "HOST_DATASETS_DIR=/tmp"; \
		} > compose/.env; \
	fi

ci-build: ci-env
	@case "$(target)" in \
		base) $(MAKE) build verbose=1 ;; \
		ppocr) $(MAKE) build-ppocr verbose=1 ;; \
		isaaclab) $(MAKE) build-isaaclab verbose=1 ;; \
		*) echo "Unsupported target: $(target)" >&2; exit 1 ;; \
	esac

ci-push:
	@case "$(target)" in \
		base) $(MAKE) push ;; \
		ppocr) $(MAKE) push-ppocr ;; \
		isaaclab) $(MAKE) push-isaaclab ;; \
		*) echo "Unsupported target: $(target)" >&2; exit 1 ;; \
	esac

ci: ci-build
	@if [ "$(push)" = "true" ]; then \
		$(MAKE) ci-push; \
	else \
		echo "Skipping docker push because push=$(push)"; \
	fi
