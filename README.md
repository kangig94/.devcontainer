# ML Research & Experiments Dev Container

A development environment for general-purpose ML research and experiments.

**Base Image**: `<your-registry>/uv-torch:py312-2.9.1-cu128`

## Quick Start

### 1. Configure Environment

```bash
cd .devcontainer
cp .env.sample .env
```

Edit `.env` with your settings:
```bash
DOCKER_REGISTRY=your-dockerhub-username   # Required
NAS_HOME=/path/to/your/nas/home           # Required (or set HOST_* paths directly)
```

See `.env.sample` for all available options.

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
3. Select `devcontainer-ml-workspace-1`

### 4. Jupyter Lab Access

Jupyter Lab runs on `http://localhost:18888` (no token required).

> **Security Warning**: Jupyter binds to `0.0.0.0` by default, allowing external access.
>
> To restrict to localhost only, modify `command` in `docker-compose.yml`:
> ```yaml
> command: [ "zsh", "-lc", "jupyter lab --ip=127.0.0.1 &> /tmp/jupyter.log & exec zsh -l" ]
> ```

## Environment Types

Since NAS workspace is used, local and server environments share the same files:

- **Local Environment**: Development on personal PC with VS Code Dev Containers. Mounts local-only settings like Git credentials, OpenCode auth, etc.
- **Server Environment**: Running on GPU server with docker-compose. Uses only NAS mounts.

### Commands by Environment

- **Local**: `make build`, `make up`, `make shell`
- **Server**: `make build-server`, `make up-server`, `make shell-server`

## Usage

### Build Image

```bash
cd .devcontainer
make build          # Local (auto-detect UID/GID)
make build-server   # Server
```

Makefile automatically detects current user's UID/GID for building.

### Development with VS Code (Local)

1. Build image first: `make build`
2. Open workspace folder in VS Code
3. `Ctrl+Shift+P` → "Dev Containers: Reopen in Container"
4. Container starts with existing image & connects
5. Container keeps running even after VS Code closes

### Server Environment (Training)

```bash
cd /path/to/your/workspace/.devcontainer

# Build image (first time only)
make build-server

# Start container
make up-server

# Access shell
make shell-server

# Run training
python train.py ...
```

## Key Features

- **Auto UID/GID Matching**: Auto-detects UID/GID from mounted workspace (entrypoint)
- **Passwordless sudo**: Run sudo without password inside container
- **Multi-GPU Architecture**: Supports RTX 30/40/50, A100, H100, B100
- **GPU Support**: Auto-detects NVIDIA GPUs
- **Multi-Node Training**: DeepSpeed distributed training support (SSH port 2222)
- **Jupyter Lab**: Auto-forwarded from port 18888 → 8888

## Port Mapping

| Host | Container | Purpose |
|------|-----------|---------|
| 18888 | 8888 | Jupyter Lab |
| 16006 | 6006 | TensorBoard |
| 17860 | 7860 | Gradio |
| 10022 | 22 | SSH (single-node) |
| 2222 | 22 | SSH (multi-node) |

## Mounted Volumes

### Base (All Environments)
- NAS workspace: `${NAS_HOME}/workspace` → `/home/dev/workspace`
- NAS cache: `${NAS_HOME}/.cache` → `/home/dev/.cache`
- NAS datasets: `${NAS_HOME}/datasets` → `/home/dev/datasets`

### Local Only (docker-compose.local.yml)
- Git settings: `~/.gitconfig`, `~/.git-credentials`
- OpenCode: `~/.config/opencode`, `~/.local/share/opencode`
- Claude session: `~/.claude`

## Installed Tools

- Python 3.12 + uv
- PyTorch (CUDA 12.8)
- flash-attn, deepspeed, accelerate
- diffusers, transformers, peft
- Jupyter Lab
- OpenCode + oh-my-opencode
- Zsh + antidote
- SSH server/client (for multi-node training)

## Makefile Commands

```bash
make              # Show help

# Local development (includes Git credentials, OpenCode, etc.)
make build        # Build (auto-detect UID/GID)
make up           # Start container
make down         # Stop container
make shell        # Access shell
make run          # build + up + shell

# Server training (base NAS mounts only)
make build-server
make up-server
make down-server
make shell-server

# Root environment (for testing)
make build-root   # Build with root target
make up-root      # Start root container
make down-root    # Stop root container
make shell-root   # Access root container shell

# Multi-Node Training (DeepSpeed distributed)
make up-multinode    # Start multinode container
make down-multinode  # Stop multinode container
make shell-multinode # Access multinode container shell
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

- `docker-compose.multinode.yml`: docker-compose for multi-node (port 2222:22, NCCL ports)
- `setup_multinode.sh`: SSH key generation and installation script

### Execution Steps

```bash
# 0. Master node: Build and push image
cd .devcontainer
make build
docker push <your-registry>/uv-torch:py312-2.9.1-cu128-dev

# 1. All nodes: Edit docker-compose.multinode.yml (volume paths)
volumes:
  - /your/nas/path:/home/dev/workspace

# 2. Worker nodes: Pull image
docker pull <your-registry>/uv-torch:py312-2.9.1-cu128-dev

# 3. All nodes: Start container
cd .devcontainer
make up-multinode

# 4. All nodes: Access container and setup SSH
make shell-multinode
./workspace/.devcontainer/setup_multinode.sh
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

# SSH port (mapped as 2222:22 in docker-compose)
SSH_PORT=2222
```

### Port Configuration

| Port | Purpose |
|------|---------|
| 2222:22 | SSH (DeepSpeed launcher) |
| 29500-29510 | NCCL communication (torch.distributed) |

### Notes

- Run train script on **Master node only**
- DeepSpeed connects via SSH to hostfile IPs to auto-start worker processes
- SSH keys are shared via NAS (`workspace/.devcontainer/ssh_keys/`)
- NCCL_IB_DISABLE=1: Setting for environments without InfiniBand

## Troubleshooting

### Rebuild Container

```bash
make down
make build
make up
```

### Permission denied Error

UID/GID mismatch issue. Rebuild the image:
```bash
make build   # Rebuild with current user UID/GID
```

### docker-compose.local.yml Not Found Error

If local-only file doesn't exist, use server commands:
```bash
make up-server
make shell-server
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
