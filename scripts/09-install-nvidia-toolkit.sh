#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-10.10.10.50}}"

info "Installing NVIDIA Container Toolkit on ${TARGET}"
wait_for_ssh "$TARGET" 240
guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
if ! lspci | grep -qi nvidia; then
  echo "No NVIDIA device visible in guest; skipping NVIDIA toolkit."
  exit 0
fi

sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates ubuntu-drivers-common
if ! command -v nvidia-smi >/dev/null 2>&1; then
  sudo ubuntu-drivers install || true
fi

if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
fi

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
nvidia-smi || true
EOF
