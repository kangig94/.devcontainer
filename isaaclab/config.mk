# Isaac Lab release matrix.
#
# A release selects two independent things:
#   1. a reusable Python / Torch / Isaac Sim dependency profile;
#   2. small image-policy overrides that are passed as late Docker build args.
#
# Keep policy here instead of in profiles/: profile files are copied before the
# expensive Isaac Sim layer, while this file is never copied into the image.

isaaclab ?= v3.0.0-beta2.patch1
ISAACLAB_VERSION := $(isaaclab)
ISAACLAB_VERSION_LIST := v2.3.0 v2.3.1 v2.3.2 v3.0.0-beta2.patch1 v3.0.0-EA

ISAACLAB_PROFILE_v2.3.0 := isaacsim-5.1-py311-cu128
ISAACLAB_PROFILE_v2.3.1 := isaacsim-5.1-py311-cu128
ISAACLAB_PROFILE_v2.3.2 := isaacsim-5.1-py311-cu128
ISAACLAB_PROFILE_v3.0.0-beta2.patch1 := isaacsim-6.0-py312-cu128
ISAACLAB_PROFILE_v3.0.0-EA := isaacsim-6.1-py312-cu130

ISAACLAB_PROFILE := $(ISAACLAB_PROFILE_$(ISAACLAB_VERSION))
ISAACLAB_PROFILE_FILE := isaaclab/profiles/$(ISAACLAB_PROFILE).env

ifneq ($(wildcard $(ISAACLAB_PROFILE_FILE)),)
include $(ISAACLAB_PROFILE_FILE)
else ifneq ($(filter build-isaaclab-base build-isaaclab push-isaaclab up-isaaclab down-isaaclab shell-isaaclab sim,$(MAKECMDGOALS)),)
$(error Unsupported Isaac Lab release $(ISAACLAB_VERSION). Add its mapping to isaaclab/config.mk)
endif

# v2.3.1 and v2.3.2 call this exact registry extension API from UrdfConverter.
ifneq ($(filter v2.3.1 v2.3.2,$(ISAACLAB_VERSION)),)
HEADLESS_ASSET_EXTENSIONS ?= true
URDF_IMPORTER_VERSION ?= 2.4.31
endif

HEADLESS_ASSET_EXTENSIONS ?= false
URDF_IMPORTER_VERSION ?=
ISAACLAB_23_VERSIONS ?= v2.3.0 v2.3.1 v2.3.2
