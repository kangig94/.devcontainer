#!/bin/bash
# Multi-node SSH setup script
# Run this on EVERY node (SSH keys are generated once since NAS is shared)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_DIR="$SCRIPT_DIR/ssh_keys"

echo "============================================"
echo "Multi-Node SSH Setup"
echo "============================================"
echo ""

# 0. Start container sshd on port 2222 (network_mode: host + container SSH)
# - NCCL: Uses host network (actual node IPs)
# - SSH: Uses container sshd (same environment, same paths, same UID)
SSH_PORT=2222
echo "[0/4] Starting container sshd on port $SSH_PORT..."
if [ "$(id -u)" = "0" ]; then
    # Configure sshd to listen on port 2222 (avoid conflict with host's port 22)
    sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    service ssh restart
    chown $(id -u):$(id -g) "$HOME"
    chmod 755 "$HOME"
else
    sudo sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    sudo grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config || echo "Port $SSH_PORT" | sudo tee -a /etc/ssh/sshd_config
    sudo service ssh restart
    sudo chown $(id -u):$(id -g) "$HOME"
    sudo chmod 755 "$HOME"
fi
echo "Container sshd started on port $SSH_PORT"
echo ""

# 1. Generate SSH keys (if not exists - only generated on first node since NAS is shared)
if [ ! -f "$SSH_DIR/id_rsa" ]; then
    echo "[1/4] Generating SSH keys..."
    mkdir -p "$SSH_DIR"
    ssh-keygen -t rsa -N "" -f "$SSH_DIR/id_rsa"
    echo "SSH keys created"
else
    echo "[1/4] SSH keys already exist (shared via NAS)"
fi

# 2. Install SSH keys to current node
echo ""
echo "[2/4] Installing SSH keys to ~/.ssh..."
mkdir -p ~/.ssh
cp "$SSH_DIR/id_rsa" ~/.ssh/
cp "$SSH_DIR/id_rsa.pub" ~/.ssh/
cat "$SSH_DIR/id_rsa.pub" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_rsa ~/.ssh/authorized_keys
chmod 644 ~/.ssh/id_rsa.pub
sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
echo "SSH keys installed to ~/.ssh"

# 3. Test SSH connection
echo ""
echo "[3/4] Testing SSH connection to localhost on port $SSH_PORT..."
if ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$SSH_PORT" localhost hostname &>/dev/null; then
    echo "SSH test: SUCCESS"
else
    echo "SSH test: FAILED"
    echo "  Check: sudo service ssh status"
    echo "  Check: sudo netstat -tlnp | grep $SSH_PORT"
fi

echo ""
echo "============================================"
echo "Setup complete!"
echo ""
echo "Run this script on all nodes."
echo "Then start training with train_multinode.sh."
echo "============================================"
