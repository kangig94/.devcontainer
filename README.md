# ML Research & Experiments Dev Container

A development environment for general-purpose ML research and experiments.

**Base Image**: `<your-registry>/uv-torch:py312-2.10.0-cu128`

> **Prerequisites**: `compose/.env` must exist before any `make` command.
> Copy the sample and edit it: `cp compose/.env.sample compose/.env`

## Quick Start

### 1. Configure Environment

```bash
cd .devcontainer
cp compose/.env.sample compose/.env
```

Edit `compose/.env` with your settings:
```bash
DOCKER_REGISTRY=your-dockerhub-username   # Required
NAS_HOME=/path/to/your/nas/home           # Required (or set HOST_* paths directly)
```

See `compose/.env.sample` for all available options.

Notes:
- Container user is always `dev`. UID/GID are reconciled to the host at startup.
- Container home is always `/home/dev`.
- Core startup bootstrap is baked into the image as `devcontainer-entrypoint`;
  this compose file uses `scripts/entrypoint.sh` as a repo-local wrapper
  that chains to the baked entrypoint.
- For one-off privileged commands, use `docker exec -u root <container>` —
  there is no separate "root image".

### 2. Build & Start

```bash
make build   # Build image
make up      # Start container
```

See `make help` for all available commands.

### 3. Connect with VS Code

> **Important**: Container must be running (`make up`) before connecting.

1. Open workspace folder (parent of `.devcontainer`) in VS Code
2. `Ctrl+Shift+P` → "Dev Containers: Attach to Running Container"
3. Select `devcontainer-lab-1`

### 4. Install AI CLIs (optional)

Claude Code / Codex / Gemini are installed on demand, not baked into the image:

```bash
make shell
setup-ai          # idempotent — re-run after make down/up
```

Skips already-installed CLIs; final summary lists what's installed and what failed.

### 5. Jupyter Lab Access

Jupyter Lab runs on `http://localhost:18888` (no token required).

> **Security Warning**: Jupyter binds to `0.0.0.0` by default, allowing external access.
>
> To restrict to localhost only, modify `command` in `docker-compose.yml`:
> ```yaml
> command: [ "zsh", "-lc", "jupyter lab --ip=127.0.0.1 &> /tmp/jupyter.log & exec zsh -l" ]
> ```

## Usage

### Build Image

```bash
cd .devcontainer
make build          # Auto-detects UID/GID from host
```

UID/GID is reconciled at container startup by `entrypoint.sh` (runtime), based on mounted workspace ownership.

### Development with VS Code

1. Build image first: `make build`
2. Open workspace folder in VS Code
3. `Ctrl+Shift+P` → "Dev Containers: Reopen in Container"
4. Container starts with existing image & connects
5. Container keeps running even after VS Code closes

## Key Features

- **Auto UID/GID Matching**: Auto-detects UID/GID from mounted workspace (entrypoint)
- **Fixed Username Policy**: Username is fixed to `dev`, only UID/GID is dynamic
- **Passwordless sudo**: Run sudo without password inside container
- **Multi-GPU Architecture**: Supports RTX 30/40/50, A100, H100, B100
- **GPU Support**: Auto-detects NVIDIA GPUs
- **Multi-Node Training**: DeepSpeed distributed training support (SSH port 2222)
- **Jupyter Lab**: Auto-forwarded from port 18888 → 8888
- **npm Global Without sudo**: `npm -g` installs to `~/.local` by default
- **AI CLIs on demand**: Run `setup-ai` inside the container to install Claude Code / Codex / Gemini (idempotent)

## Port Mapping

| Host | Container | Purpose |
|------|-----------|---------|
| 18888 | 8888 | Jupyter Lab |
| 16006 | 6006 | TensorBoard |
| 17860 | 7860 | Gradio |
| 10022 | 22 | SSH (single-node) |
| 2222 | 22 | SSH (multi-node) |

## Mounted Volumes

- NAS workspace: `${NAS_HOME}/workspace` → `/home/dev/workspace`
- NAS cache: `${NAS_HOME}/.cache` → `/home/dev/.cache`
- NAS datasets: `${NAS_HOME}/datasets` → `/home/dev/datasets`
- Tmux config: `${NAS_HOME}/.tmux.conf` → `/home/dev/.tmux.conf`

## Installed Tools

- Python 3.12 + uv (system CUDA 12.9.1, torch wheel cu128)
- PyTorch 2.10.0, torchvision, torchaudio
- flash-attn-4, deepspeed, accelerate
- diffusers, transformers, peft, datasets
- Jupyter Lab
- Claude Code / Codex / Gemini via `setup-ai` (on-demand)
- Zsh + antidote
- SSH server/client (for multi-node training)

## Makefile Commands

```bash
make              # Show help

# Base image
make build        # Build (auto-detect UID/GID)
make up           # Start container
make down         # Stop container
make shell        # Access shell
make run          # build + up + shell

# Inside the container — install AI CLIs on demand (idempotent)
setup-ai

# One-off root command (no separate image required)
docker exec -u root <container> <cmd>

# Multi-Node Training (DeepSpeed distributed)
make build-multinode # Build multinode overlay (depends on base)
make up-multinode    # Start multinode container
make down-multinode  # Stop multinode container
make shell-multinode # Access multinode container shell

# PaddleOCR (auto-builds cu126 base + paddle overlay)
make build-ppocr     # Build cu126 base + ppocr overlay
make up-ppocr / down-ppocr / shell-ppocr
```

## Multi-Node Training (DeepSpeed)

How to run distributed training across multiple GPU servers.

### Architecture

```
Master Node                      Worker Nodes
    │                                │
    ├── deepspeed launcher ──SSH──▶ Auto-start processes
    │                                │
    └── Training ◀──NCCL comm──────▶ Training
```

- **Master**: Runs train script, DeepSpeed manages worker processes via SSH
- **Worker**: Master connects via SSH to auto-start processes (no manual execution)

### Prerequisites

1. All nodes must mount the same NAS
2. All nodes use the same Docker image
3. SSH communication between nodes (port 2222)

### Configuration Files

- `docker-compose.multinode.yml`: docker-compose for multi-node (host network, SSH 2222, NCCL ports)
- `scripts/setup_multinode.sh`: SSH key generation and installation script

### Execution Steps

```bash
# 0. Master node: Build and push image
cd .devcontainer
make build
docker push <your-registry>/uv-torch:py312-2.10.0-cu128

# 1. All nodes: Edit docker-compose.multinode.yml (volume paths)
volumes:
  - /your/nas/path:/home/dev/workspace

# 2. Worker nodes: Pull image
docker pull <your-registry>/uv-torch:py312-2.10.0-cu128

# 3. All nodes: Start container
cd .devcontainer
make up-multinode

# 4. All nodes: Access container and setup SSH
make shell-multinode
./workspace/.devcontainer/scripts/setup_multinode.sh
# SSH keys are generated only on first node since NAS is shared

# 5. Master node only: Run training
cd workspace/diffusion-pipe  # or your training code path
./train_online_multinode.sh ./output
```

### train_online_multinode.sh Configuration

```bash
# Node IP addresses (modify for your environment)
NODES=(
    "<master-ip>"   # Master
    "<worker-1-ip>" # Worker 1
    "<worker-2-ip>" # Worker 2
    "<worker-3-ip>" # Worker 3
)

# GPUs per node
GPUS_PER_NODE=8

# SSH port (container sshd listens on host-network port 2222)
SSH_PORT=2222
```

### Port Configuration

| Port | Purpose |
|------|---------|
| 2222 | SSH (DeepSpeed launcher) |
| 29500-29510 | NCCL communication (torch.distributed) |

### Notes

- Run train script on **Master node only**
- DeepSpeed connects via SSH to hostfile IPs to auto-start worker processes
- SSH keys are shared via NAS (`workspace/.devcontainer/ssh_keys/`)
- NCCL_IB_DISABLE=1: Setting for environments without InfiniBand

## Isaac Lab (Isaac Sim + Newton)

Robotics simulation environment layered on top of the normal `uv-torch` ML base
by default. Add `isolate=true` to use the dedicated lightweight `isaaclab-base`
instead. Isaac Sim is installed from the NVIDIA PyPI mirror as a regular venv
package (no NGC `nvcr.io/nvidia/isaac-sim` base), and Isaac Lab is
editable-installed from a pinned git tag. Dependency pins live in
`isaaclab/versions/<tag>.env`, so `isaaclab=<tag>` selects the matching Python,
PyTorch, CUDA wheel tag, Ubuntu, and Isaac Sim versions for the selected base
and overlay.

**Default layers**: `uv-torch` ML base -> Isaac Sim system libraries ->
`isaacsim[all,extscache]` (PyPI) -> Isaac Lab git tag (editable)

**Isolated layers**: Ubuntu + dev/sudo + uv + git/curl +
cmake/build-essential + torch runtime + Isaac Sim system libraries ->
`isaacsim[all,extscache]` (PyPI) -> Isaac Lab git tag (editable)

The isolated IsaacLab base intentionally excludes zsh, Node/npm, JupyterLab,
SSH server, tmux, and the generic ML stack (`deepspeed`, `flash-attn`,
`diffusers`, `datasets`). IsaacLab itself may install domain dependencies such
as `transformers`.

**Known manifests**:

| Isaac Lab | Python | Torch | CUDA wheel | Isaac Sim |
|-----------|--------|-------|------------|-----------|
| `v2.3.0` | 3.11 | 2.7.0 | cu128 | 5.1.0 |
| `v2.3.1` | 3.11 | 2.7.0 | cu128 | 5.1.0 |
| `v2.3.2` | 3.11 | 2.7.0 | cu128 | 5.1.0 |
| `v3.0.0-beta2.patch1` | 3.12 | 2.10.0 | cu128 | 6.0.1 |

**Image tags**: `uv-torch:py312-2.10.0-cu128` and
`isaaclab:py312-3.0.0-beta2.patch1` by default. `isaaclab=v2.3.2` builds
`uv-torch:py311-2.7.0-cu128` and `isaaclab:py311-2.3.2`. With `isolate=true`,
the base tag becomes `isaaclab-base:<py>-<torch>-<cuda>`.

### Quick Start

```bash
cd .devcontainer

# `make build-isaaclab` chains: uv-torch -> isaaclab overlay.
# IsaacLab is already installed inside the image; no in-container install needed.
make build-isaaclab
make up-isaaclab
```

To build a specific Isaac Lab version:

```bash
make build-isaaclab isaaclab=v2.3.2
make build-isaaclab-23x     # v2.3.0, v2.3.1, v2.3.2

# Use the lightweight IsaacLab-only base instead of uv-torch.
make build-isaaclab isaaclab=v2.3.2 isolate=true

# Patch the image to use the version manifest's local Isaac Sim asset root.
# This is off by default.
make build-isaaclab isaaclab=v2.3.2 offline_assets=true
```

When `offline_assets=true`, the build rewrites `default`, `cloud`, and `nvidia`
asset roots in every `apps/isaaclab.python*.kit` file. The local container path
is versioned in `isaaclab/versions/<tag>.env` (`5.1` for Isaac Lab 2.3.x and
`6.0` for Isaac Lab 3.0.0-beta2.patch1). Mount the matching host asset tree at
runtime, for example:

```yaml
volumes:
  - /data/isaacsim_assets:/data/isaacsim_assets:ro
```

### Launch Isaac Sim GUI (local, requires display)

```bash
make sim
```

### Commands

```bash
make build-isaaclab-base     # Build lightweight IsaacLab base image
make build-isaaclab          # Build uv-torch base + final IsaacLab image
make build-isaaclab isolate=true  # Build isolated base + final IsaacLab image
make up-isaaclab             # Start container
make down-isaaclab           # Stop container
make shell-isaaclab          # Access shell
make sim                     # Launch Isaac Sim GUI (requires display)
```

### Training

```bash
# Headless training (default). Add --viz viser for the web visualizer.
./isaaclab.sh -p scripts/reinforcement_learning/skrl/train.py \
  --task Isaac-Cartpole-Direct-v0

# WebRTC streaming (separate viewer container required)
./isaaclab.sh -p scripts/reinforcement_learning/skrl/train.py \
  --task Isaac-Cartpole-Direct-v0 \
  --livestream 1 \
  --experience /opt/isaaclab/apps/isaaclab.python.streaming.kit
```

### Ports (network_mode: host)

| Port | Purpose |
|------|---------|
| 8080 | Viser (Newton visualizer) |
| 9876 | Rerun |
| 49100 | WebRTC signal (if livestream) |
| 47998 | WebRTC stream (if livestream) |

### Architecture

```
Local Workstation                 GPU Cluster (headless)
├── make up-isaaclab              ├── make up-isaaclab
├── make sim (GUI)                ├── Viser for monitoring
├── Env design, debugging         ├── Training at scale
└── Same Docker image             └── Same Docker image
```

## PaddleOCR

PaddleOCR overlay on top of a cu126-flavored base. Paddle's latest supported
CUDA is 12.6, so this variant builds a separate base image with `CUDA_TAG=cu126`
(Paddle wheels bundle their own CUDA libs; the base toolkit stays aligned with
the torch stack by default).

**Layers**: `ubuntu:24.04` + minimal CUDA SDK → uv-torch base → paddlepaddle-gpu + paddleocr

### Quick Start

```bash
cd .devcontainer

# Builds cu126 base + ppocr overlay in one command.
make build-ppocr
make up-ppocr
make shell-ppocr
```

### Notes

- The cu126 base image is tagged `<registry>/uv-torch:py312-2.10.0-cu126` and coexists with the default cu128 base.
- ppocr image is tagged `<registry>/ppocr:py312-cu126`.

## Troubleshooting

### Rebuild Container

```bash
make down
make build
make up
```

### Permission denied Error

UID/GID or home ownership mismatch issue. Restart container to re-run entrypoint ownership sync:
```bash
make down
make up
```

### zoxide: unable to create data directory

If `~/.local/share` was previously created with a different owner, restart container so entrypoint can fix ownership:
```bash
make down
make up
```

### Multi-Node SSH Connection Failed

1. **Check SSH service**: Run `sudo service ssh status` on all nodes
2. **Check SSH keys**: `ls ~/.ssh/` (verify id_rsa, authorized_keys exist)
3. **Manual SSH test**: `ssh -p 2222 <worker_ip>` (verify passwordless)
4. **Check port**: `netstat -tlnp | grep 22` (verify sshd is listening)

### NCCL Communication Error

```bash
# Check environment variables
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=eth0  # Check network interface: ip addr
export NCCL_IB_DISABLE=1        # Required if no InfiniBand
export NCCL_P2P_DISABLE=1       # Add if P2P issues
```
