#!/usr/bin/env bash
# Описание: Деплой стека LLM (Ollama, OpenWebUI и т.д.) в гостевой VM.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции
load_config                                           # загружаем конфигурацию проекта

TARGET="${1:-${LLM_IP:-${MONITORING_IP:-}}}"          # IP целевой VM для деплоя LLM стека
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi

REMOTE_STACK=/opt/llm-stack

mark_step "Deploying LLM stack to ${TARGET}"

wait_for_ssh "$TARGET" 240

setup_remote_directory() {
  guest_ssh "$TARGET" "sudo mkdir -p ${REMOTE_STACK} && sudo chown ${GUEST_USER}:${GUEST_USER} ${REMOTE_STACK}"
}

transfer_stack() {
  info "Transferring docker compose stack"
  SCP_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  scp ${SCP_OPTS} -r "${PROJECT_ROOT}/docker/llm/." "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/"  # копируем docker stack на целевую VM
}

check_existing_containers() {
  local existing
  existing="$(guest_ssh "$TARGET" "cd ${REMOTE_STACK} && docker compose ps -q")"
  if [[ -n "$existing" ]]; then
    info "Existing containers found, will be updated"
    return 0
  fi
  return 1
}

deploy_stack() {
  info "Deploying with Docker Compose"
  guest_ssh "$TARGET" "cd ${REMOTE_STACK} && sudo docker compose up -d --remove-orphans"
}

verify_deployment() {
  info "Verifying LLM stack deployment"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/llm-stack

echo "Container status:"
sudo docker compose ps

echo ""
echo "Checking for running containers..."
RUNNING=$(sudo docker compose ps --services --filter "status=running" | wc -l)
if [[ $RUNNING -eq 0 ]]; then
  echo "No containers are running!"
  exit 1
fi

echo "Verifying Ollama API status..."
timeout 10 curl -f http://localhost:11434/api/tags || {
  echo "Ollama API not responding"
  exit 1
}

echo "Verifying OpenWebUI status..."
timeout 10 curl -f http://localhost:3000/ || {
  echo "OpenWebUI not responding"
  exit 1
}

echo "LLM stack responsive"
EOF
}

print_access_info() {
  info "LLM stack deployed:"
  info "  - Ollama API: http://${TARGET}:11434"
  info "  - OpenWebUI: http://${TARGET}:3000"
}

setup_remote_directory
check_existing_containers || info "No existing containers, performing initial deployment"
transfer_stack
deploy_stack
verify_deployment
print_access_info

audit_log "LLM stack deployed to ${TARGET}"
