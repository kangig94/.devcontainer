.PHONY: build up down shell run \
        build-multinode up-multinode down-multinode shell-multinode \
        build-isaaclab-base build-isaaclab build-isaaclab-23x up-isaaclab down-isaaclab shell-isaaclab sim \
        build-ppocr up-ppocr down-ppocr shell-ppocr \
        push push-ppocr push-isaaclab ci-env ci-build ci-push ci help

# Auto-detect UID/GID for runtime (exported: compose env references these).
# entrypoint.sh remaps the baked dev user (UID 1000) to match at startup.
export USER_UID := $(shell id -u)
export USER_GID := $(shell id -g)

# Isaac Lab dependency manifests live in isaaclab/versions/<tag>.env.
# Set only isaaclab=<tag>; the manifest supplies the matching Python/Torch/CUDA
# base image inputs and Isaac Sim version. Lowercase CLI overrides still win.
isaaclab ?= v3.0.0-beta2.patch1
ISAACLAB_VERSION := $(isaaclab)
ISAACLAB_DEP_FILE := isaaclab/versions/$(ISAACLAB_VERSION).env
ISAACLAB_VERSION_LIST := $(patsubst isaaclab/versions/%.env,%,$(wildcard isaaclab/versions/*.env))
ifneq ($(wildcard $(ISAACLAB_DEP_FILE)),)
include $(ISAACLAB_DEP_FILE)
else ifneq ($(filter build-isaaclab-base build-isaaclab push-isaaclab up-isaaclab down-isaaclab shell-isaaclab sim,$(MAKECMDGOALS)),)
$(error No Isaac Lab dependency manifest for $(ISAACLAB_VERSION). Add $(ISAACLAB_DEP_FILE))
endif

# Lowercase command-line overrides for compatibility with existing usage.
ifneq ($(origin py),undefined)
PYTHON_VERSION := $(py)
endif
ifneq ($(origin torch),undefined)
TORCH_VERSION := $(torch)
endif
ifneq ($(origin cu),undefined)
CUDA_TAG := cu$(cu)
endif
ifneq ($(origin ubuntu),undefined)
UBUNTU_VERSION := $(ubuntu)
endif
ifneq ($(origin cuda_toolkit),undefined)
CUDA_TOOLKIT_VERSION := $(cuda_toolkit)
endif
ifneq ($(origin isaacsim),undefined)
ISAACSIM_VERSION := $(isaacsim)
endif

# ML-specific defaults (NOT exported: passed via ML_ENV prefix per target).
IMAGE_NAME ?= uv-torch
PYTHON_VERSION ?= 3.12
TORCH_VERSION ?= 2.10.0
CUDA_TAG ?= cu128
UBUNTU_VERSION ?= 24.04
CUDA_TOOLKIT_VERSION ?= 12-8
ISAACSIM_VERSION ?= 6.0.0

PY_TAG := py$(subst .,,$(PYTHON_VERSION))
ISAACLAB_TAG := $(patsubst v%,%,$(ISAACLAB_VERSION))

# flash-attn / deepspeed source builds use ~4-8GB RAM per job.
# nproc/2 (the old default) on a 32-core box demanded ~128GB and froze
# both ing and h9 to a hard reboot. Hold at 2 unless explicitly raised.
MAX_JOBS ?= 2

ML_ENV := IMAGE_NAME=$(IMAGE_NAME) PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=$(CUDA_TAG) UBUNTU_VERSION=$(UBUNTU_VERSION) CUDA_TOOLKIT_VERSION=$(CUDA_TOOLKIT_VERSION) MAX_JOBS=$(MAX_JOBS)
isolate ?= false
ISAACLAB_ISOLATE := $(filter true yes 1 on,$(isolate))
ISAACLAB_ISOLATED_BASE_IMAGE_NAME ?= isaaclab-base
ifeq ($(origin ISAACLAB_BASE_IMAGE_NAME),undefined)
ISAACLAB_BASE_IMAGE_NAME := $(if $(ISAACLAB_ISOLATE),$(ISAACLAB_ISOLATED_BASE_IMAGE_NAME),$(IMAGE_NAME))
else
ISAACLAB_ISOLATED_BASE_IMAGE_NAME ?= $(ISAACLAB_BASE_IMAGE_NAME)
endif
ISAACLAB_BASE_ENV := $(ML_ENV) IMAGE_NAME=$(ISAACLAB_ISOLATED_BASE_IMAGE_NAME) DOCKERFILE_PATH=isaaclab/base/Dockerfile
ISAACLAB_BASE_TARGET := $(if $(ISAACLAB_ISOLATE),build-isaaclab-base,build)
ISAACLAB_PUSH_BASE_ENV := $(if $(ISAACLAB_ISOLATE),$(ISAACLAB_BASE_ENV),$(ML_ENV))
ISAACLAB_ENV := $(ML_ENV) ISAACLAB_BASE_IMAGE_NAME=$(ISAACLAB_BASE_IMAGE_NAME) ISAACLAB_VERSION=$(ISAACLAB_VERSION) ISAACLAB_TAG=$(ISAACLAB_TAG)
ISAACLAB_23_VERSIONS ?= v2.3.0 v2.3.1 v2.3.2
offline_assets ?= false
ISAACLAB_OFFLINE_ASSETS := $(if $(filter true yes 1 on,$(offline_assets)),true,false)
ISAACLAB_ENV += ISAACLAB_OFFLINE_ASSETS=$(ISAACLAB_OFFLINE_ASSETS) ISAAC_ASSET_ROOT=$(ISAAC_ASSET_ROOT)

# Paddle's latest supported CUDA is 12.6 — override the image tag so the
# Paddle wheel index follows cu126. The base toolkit stays on the torch stack
# by default because torch owns its CUDA runtime through nvidia-* wheels.
PADDLE_ENV := PYTHON_VERSION=$(PYTHON_VERSION) PY_TAG=$(PY_TAG) TORCH_VERSION=$(TORCH_VERSION) CUDA_TAG=cu126 UBUNTU_VERSION=$(UBUNTU_VERSION) CUDA_TOOLKIT_VERSION=$(CUDA_TOOLKIT_VERSION) MAX_JOBS=$(MAX_JOBS)

COMPOSE_FLAGS := --env-file compose/.env
BUILD_FLAGS := $(if $(verbose),--progress=plain,)
target ?= base
push ?= true
CI_DOCKER_REGISTRY := $(if $(DOCKER_REGISTRY),$(DOCKER_REGISTRY),$(if $(filter true,$(push)),,local))

.DEFAULT_GOAL := help

help:
	@echo "ML Research Dev Container - Makefile Commands"
	@echo ""
	@echo "Version settings (override on command line):"
	@echo "  isaaclab=$(ISAACLAB_VERSION) -> loads isaaclab/versions/<tag>.env"
	@echo "  available Isaac Lab manifests: $(ISAACLAB_VERSION_LIST)"
	@echo "  py=$(PYTHON_VERSION), torch=$(TORCH_VERSION), cu=$(patsubst cu%,%,$(CUDA_TAG)) are resolved from the manifest"
	@echo "  py= / torch= / cu= / cuda_toolkit= still override manually"
	@echo "  ubuntu=$(UBUNTU_VERSION) -> FROM ubuntu:..."
	@echo "  isaacsim=$(ISAACSIM_VERSION) -> resolved from the Isaac Lab manifest"
	@echo "  MAX_JOBS=2 (default)   -> parallel jobs for source builds"
	@echo "  isolate=true           -> build Isaac Lab from isaaclab-base instead of uv-torch"
	@echo "  offline_assets=true    -> patch Isaac Lab Kit files to use the version manifest's local asset root"
	@echo ""
	@echo "Example:"
	@echo "  make build-isaaclab isaaclab=v2.3.2"
	@echo "  make build-isaaclab isaaclab=v2.3.2 offline_assets=true"
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
	@echo "  make build-isaaclab-base - Build isolated lightweight Isaac Lab base"
	@echo "  make build-isaaclab  - Build uv-torch base + Isaac Lab overlay"
	@echo "  make build-isaaclab isolate=true - Build isolated base + Isaac Lab overlay"
	@echo "  make build-isaaclab-23x - Build IsaacLab v2.3.0/v2.3.1/v2.3.2"
	@echo "  make push-isaaclab   - Push selected base + Isaac Lab overlay"
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

build-isaaclab-base:
	$(ISAACLAB_BASE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.build.yml build $(BUILD_FLAGS)

build-isaaclab: $(ISAACLAB_BASE_TARGET)
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml build $(BUILD_FLAGS)

build-isaaclab-23x:
	@set -e; \
	for version in $(ISAACLAB_23_VERSIONS); do \
		echo "Building Isaac Lab $$version from isaaclab/versions/$$version.env"; \
		$(MAKE) build-isaaclab isaaclab=$$version; \
	done

push-isaaclab:
	$(ISAACLAB_PUSH_BASE_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml config --images | xargs -r -n 1 docker push
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml config --images | xargs -r -n 1 docker push

sim:
	xhost +local: > /dev/null 2>&1
	docker exec isaaclab-lab-1 /opt/isaaclab/isaaclab.sh -s

up-isaaclab:
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml up -d

down-isaaclab:
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml down

shell-isaaclab:
	$(ISAACLAB_ENV) docker compose $(COMPOSE_FLAGS) -f compose/docker-compose.yml -f compose/docker-compose.isaaclab.yml exec lab bash

# ============================================
# CI entrypoint (GitHub Actions calls this)
# ============================================

ci-env:
	@if [ "$(GITHUB_ACTIONS)" = "true" ] || [ ! -f compose/.env ]; then \
		test -n "$(CI_DOCKER_REGISTRY)" || { echo "DOCKER_REGISTRY is required when push=true"; exit 1; }; \
		mkdir -p compose; \
		{ \
			echo "DOCKER_REGISTRY=$(CI_DOCKER_REGISTRY)"; \
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
