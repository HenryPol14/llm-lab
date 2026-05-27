#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-10.10.10.50}}"

info "Installing guest runtime on ${TARGET}"

wait_for_ssh "$TARGET" 240

guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail

sudo apt-get update -y

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  docker.io \
  jq \
  htop

if ! docker compose version >/dev/null 2>&1; then
  if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
  fi
fi

sudo systemctl stop docker || true
sudo systemctl stop containerd || true

sudo mkdir -p /mnt/ai-data/docker
sudo mkdir -p /mnt/ai-data/ollama

if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
  sudo rsync -aP /var/lib/docker/ /mnt/ai-data/docker/ || true
fi

sudo mkdir -p /etc/docker

cat <<JSON | sudo tee /etc/docker/daemon.json
{
  "data-root": "/mnt/ai-data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
JSON

sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl enable containerd

sudo systemctl start containerd
sudo systemctl start docker

sudo usermod -aG docker "$USER" || true

docker info | grep "Docker Root Dir"

docker compose version

echo
echo "[INFO] Docker data root:"
docker info | grep "Docker Root Dir"

echo
echo "[INFO] Disk usage:"
df -h
EOF
