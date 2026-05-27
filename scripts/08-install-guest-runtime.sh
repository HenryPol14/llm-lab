#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-10.10.10.50}}"

info "Installing guest runtime on ${TARGET}"
wait_for_ssh "$TARGET" 240
guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release docker.io docker-compose-plugin jq htop
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true
EOF
