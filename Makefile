.PHONY: build up down shell build-local up-local down-local shell-local build-server up-server down-server shell-server build-root up-root down-root shell-root build-multinode up-multinode down-multinode shell-multinode build-multinode-root up-multinode-root down-multinode-root shell-multinode-root build-isaaclab up-isaaclab down-isaaclab shell-isaaclab sim up-isaaclab-multinode down-isaaclab-multinode shell-isaaclab-multinode build-ppocr up-ppocr down-ppocr shell-ppocr help

# Auto-detect UID/GID for runtime (exported: compose files reference these)
export USER_UID := $(shell id -u)
export USER_GID := $(shell id -g)
export USERNAME := dev
export BUILD_TARGET := user
export IMAGE_SUFFIX := -$(USERNAME)

# ML-specific versions (NOT exported: only used in ML targets via ML_ENV prefix)
py ?= 3.12
torch ?= 2.10.0
cu ?= 128

PYTHON_VERSION := $(py)
PY_TAG := py$(subst .,,$(py))
TORCH_VERSION := $(torch)
CUDA_TAG := cu$(cu)
# flash-attn / deepspeed source builds use ~4-8GB RAM per job.
# nproc/2 (was the default) on a 32-core box demanded ~128GB and froze
# both ing and h9 to a hard reboot. Hold at 2 unless explicitly raised.
MAX_JOBS ?= 2

# Prefix for ML targets to pass version vars to compose
ML_ENV := PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=$(CUDA_TAG) MAX_JOBS=$(MAX_JOBS)


# Project name is now defined in compose/docker-compose.yml (name: devcontainer)
# No need for -p flag - compose file takes precedence
# Use `make build verbose=1` for detailed build logs
COMPOSE_FLAGS := --env-file compose/.env
BUILD_FLAGS := $(if $(verbose),--progress=plain,)

# Default target: show help
.DEFAULT_GOAL := help

help:
	@echo "ML Research Dev Container - Makefile Commands"
	@echo ""
	@echo "Version settings:"
	@echo "  py=3.12 (default)     -> image: py312-..."
	@echo "  torch=2.10.0 (default) -> image: ...-2.10.0-..."
	@echo "  cu=128 (default)      -> image: ...-cu128-..."
	@echo ""
	@echo "Example:"
	@echo "  make build py=3.10 torch=2.5.1 cu=124"
	@echo ""
	@echo "Local development (mounts Git credentials, OpenCode auth, etc.):"
	@echo "  make build-local   - Build container (with local-only mounts)"
	@echo "  make up-local      - Start container"
	@echo "  make down-local    - Stop container"
	@echo "  make shell-local   - Access container shell"
	@echo ""
	@echo "Server environment (NAS mounts only, no local settings):"
	@echo "  make build-server  - Build container (base config only)"
	@echo "  make up-server     - Start container"
	@echo "  make down-server   - Stop container"
	@echo "  make shell-server  - Access container shell"
	@echo ""
	@echo "Alias (default: local):"
	@echo "  make build         - = make build-local"
	@echo "  make up            - = make up-local"
	@echo "  make down          - = make down-local"
	@echo "  make shell         - = make shell-local"
	@echo ""
	@echo "Root environment (for testing):"
	@echo "  make build-root    - Build with root target"
	@echo "  make up-root       - Start root container"
	@echo "  make down-root     - Stop root container"
	@echo "  make shell-root    - Access root container shell"
	@echo ""
	@echo "PaddleOCR (cu126):"
	@echo "  make build-ppocr   - Build PaddleOCR image"
	@echo "  make up-ppocr      - Start PaddleOCR container"
	@echo "  make down-ppocr    - Stop PaddleOCR container"
	@echo "  make shell-ppocr   - Access PaddleOCR shell"
	@echo ""
	@echo "Multi-Node Training (DeepSpeed distributed):"
	@echo "  make build-multinode - Build multinode container"
	@echo "  make up-multinode    - Start multinode container"
	@echo "  make down-multinode  - Stop multinode container"
	@echo "  make shell-multinode - Access multinode container shell"
	@echo ""
	@echo "Multi-Node as Root (SSH-based launcher):"
	@echo "  make build-multinode-root - Build root multinode"
	@echo "  make up-multinode-root    - Start root multinode"
	@echo "  make down-multinode-root  - Stop root multinode"
	@echo "  make shell-multinode-root - Access root multinode shell"
	@echo ""
	@echo "Isaac Lab (Isaac Sim + Newton):"
	@echo "  make build-isaaclab          - Build Isaac Lab image (on Isaac Sim)"
	@echo "  make up-isaaclab             - Start container"
	@echo "  make sim                     - Launch Isaac Sim GUI (requires display)"
	@echo "  make down-isaaclab           - Stop container"
	@echo "  make shell-isaaclab          - Access container shell"
	@echo ""
# ============================================
# Local development commands (with local mounts)
# ============================================

build-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml up -d

down-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml down

shell-local:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml exec -u dev lab zsh

# Alias for local (default)
build: build-local
up: up-local
down: down-local
shell: shell-local

# ============================================
# Server commands (base config only)
# ============================================

build-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml up -d

down-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml down

shell-server:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml exec -u dev lab zsh

# Build and run with current user in one command
run: build up shell

# ============================================
# Root commands (for multi-node training)
# ============================================

build-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root RUN_AS_ROOT=true CONTAINER_HOME=/root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml up -d

down-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml down

shell-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml exec lab zsh

# ============================================
# PaddleOCR commands
# ============================================

build-ppocr: build-local
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml build $(BUILD_FLAGS)

up-ppocr:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml up -d

down-ppocr:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml down

shell-ppocr:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.ppocr.yml exec -u dev lab zsh

# ============================================
# Multi-node training commands
# ============================================

build-multinode: build-local
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-multinode:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml up -d

down-multinode:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml down

shell-multinode:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml exec -u $(USERNAME) lab zsh

# Multi-node as root (for SSH-based DeepSpeed launcher)
build-multinode-root: build-root
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-multinode-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root RUN_AS_ROOT=true CONTAINER_HOME=/root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml up -d

down-multinode-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml down

shell-multinode-root:
	$(ML_ENV) BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.multinode.yml exec lab zsh

# ============================================
# Isaac Lab (Isaac Sim + Newton)
# ============================================

build-isaaclab: build-local
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml build $(BUILD_FLAGS)

sim:
	xhost +local: > /dev/null 2>&1
	docker exec -u dev isaaclab-lab-1 /isaac-sim/isaac-sim.sh

up-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml up -d

down-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml down

shell-isaaclab:
	$(ML_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml exec -u dev lab zsh

# Isaac Lab multi-node (same stack, NCCL env already in overlay)
up-isaaclab-multinode: up-isaaclab
down-isaaclab-multinode: down-isaaclab
shell-isaaclab-multinode: shell-isaaclab
