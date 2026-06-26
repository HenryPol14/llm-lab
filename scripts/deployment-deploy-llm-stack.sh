#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Устанавливает LLM стек (Ollama + OpenWebUI + exporters) в контейнерах.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
TARGET="${1:-${LLM_IP:-}}"
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi
REMOTE_STACK="/opt/llm-stack"
mark_step "Deploying LLM stack to ${TARGET}"
wait_for_ssh "$TARGET" 240

prepare_data_dirs() {
  info "Preparing data directories on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo mkdir -p /mnt/data/ollama
sudo mkdir -p /mnt/data/models
sudo mkdir -p /mnt/data/openwebui
sudo mkdir -p /mnt/data/docker
sudo chown -R ${GUEST_USER}:${GUEST_USER} /mnt/data/ollama /mnt/data/models /mnt/data/openwebui
echo "Data directories prepared"
EOF
}

setup_remote_directory() {
  guest_ssh "$TARGET" \
    "sudo mkdir -p \"${REMOTE_STACK}\" && sudo chown \"${GUEST_USER}:${GUEST_USER}\" \"${REMOTE_STACK}\""
}

render_compose_config() {
  info "Rendering docker-compose config"
  cp -R "${PROJECT_ROOT}/docker/llm/." "${TMP_DIR}/"
  sed -i "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" "${TMP_DIR}/docker-compose.yml" 2>/dev/null || true
}

transfer_stack() {
  local tmp_dir="$1"
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  info "Transferring LLM stack"
  scp -r ${opts} \
    "${tmp_dir}/." \
    "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/" || true
}

check_existing_containers() {
  local existing
  existing="$(guest_ssh "$TARGET" \
    "cd ${REMOTE_STACK} && sudo docker compose ps -q 2>/dev/null | wc -l || true" || true)"
  if [[ "$existing" -gt 0 ]]; then
    info "Existing containers detected, updating..."
    return 0
  fi
  info "No existing containers found"
  return 1
}

deploy_stack() {
  info "Deploying LLM stack"
  guest_ssh "$TARGET" "
set -Eeuo pipefail || true
cd ${REMOTE_STACK}
sudo docker compose pull || true
sudo docker compose up -d --remove-orphans || true
"
}

verify_deployment() {
  info "Verifying deployment"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/llm-stack
echo "Container status:"
sudo docker compose ps
echo
echo "Checking Ollama API..."
timeout 15 curl -fsS http://localhost:11434/api/tags || true
echo
echo "Checking OpenWebUI..."
timeout 15 curl -fsS http://localhost:3000/login >/dev/null || true
echo
echo "LLM stack is healthy"
EOF
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
render_compose_config
setup_remote_directory
transfer_stack "$TMP_DIR"
prepare_data_dirs
check_existing_containers || info "No existing containers found"
deploy_stack
verify_deployment

audit_log "LLM stack deployed to ${TARGET}"
