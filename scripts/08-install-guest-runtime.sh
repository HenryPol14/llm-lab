#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-10.10.10.50}}"

info "Installing guest runtime on ${TARGET}"
wait_for_ssh "$TARGET" 240
guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release docker.io jq htop

if ! docker compose version >/dev/null 2>&1; then
  if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
  fi
fi

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true
docker compose version
EOF
