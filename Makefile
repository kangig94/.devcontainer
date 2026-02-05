.PHONY: build up down shell build-local up-local down-local shell-local build-server up-server down-server shell-server build-root up-root down-root shell-root build-multinode up-multinode down-multinode shell-multinode build-multinode-root up-multinode-root down-multinode-root shell-multinode-root help

# Auto-detect UID/GID for runtime (chmod 777 allows any UID to write to home)
export USER_UID := $(shell id -u)
export USER_GID := $(shell id -g)
export USERNAME := dev
export BUILD_TARGET := user
export IMAGE_SUFFIX := -$(USERNAME)

# Python version: use `py=3.10` to set (default: 3.12)
py ?= 3.12
export PYTHON_VERSION := $(py)
# Convert to tag format: 3.12 → py312, 3.10 → py310
export PY_TAG := py$(subst .,,$(py))

# Torch version: use `torch=2.9.1` to set (default: 2.9.1)
torch ?= 2.9.1
export TORCH_VERSION := $(torch)

# CUDA version for torch wheel: use `cu=126` to set (default: 128)
cu ?= 128
export CUDA_TAG := cu$(cu)

# Max parallel jobs for flash-attn build (50% of CPU cores)
export MAX_JOBS := $(shell echo $$(( $(shell nproc) / 2 )))

# Project name is now defined in compose/docker-compose.yml (name: devcontainer)
# No need for -p flag - compose file takes precedence
# Use `make build verbose=1` for detailed build logs
COMPOSE_FLAGS := --env-file .env
BUILD_FLAGS := $(if $(verbose),--progress=plain,)

# Default target: show help
.DEFAULT_GOAL := help

help:
	@echo "ML Research Dev Container - Makefile Commands"
	@echo ""
	@echo "Version settings:"
	@echo "  py=3.12 (default)     -> image: py312-..."
	@echo "  torch=2.9.1 (default) -> image: ...-2.9.1-..."
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
# ============================================
# Local development commands (with local mounts)
# ============================================

build-local:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-local:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml up -d

down-local:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml down

shell-local:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.local.yml exec -u dev ml-workspace zsh

# Alias for local (default)
build: build-local
up: up-local
down: down-local
shell: shell-local

# ============================================
# Server commands (base config only)
# ============================================

build-server:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-server:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml up -d

down-server:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml down

shell-server:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml exec -u dev ml-workspace zsh

# Build and run with current user in one command
run: build up shell

# ============================================
# Root commands (for multi-node training)
# ============================================

build-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root RUN_AS_ROOT=true docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml up -d

down-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml down

shell-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml exec ml-workspace zsh

# ============================================
# Multi-node training commands
# ============================================

build-multinode:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-multinode:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.multinode.yml up -d

down-multinode:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.multinode.yml down

shell-multinode:
	docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.multinode.yml exec -u $(USERNAME) ml-training zsh

# Multi-node as root (for SSH-based DeepSpeed launcher)
build-multinode-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

up-multinode-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root RUN_AS_ROOT=true docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.multinode.yml up -d

down-multinode-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.multinode.yml down

shell-multinode-root:
	BUILD_TARGET=root IMAGE_SUFFIX=-root docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.multinode.yml exec ml-training zsh
