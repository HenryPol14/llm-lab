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

# Очищаем устаревший ключ хоста — VM могла пересоздаваться
ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
mkdir -p "$HOME/.ssh"
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

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

pull_models() {
  # Модели подобраны под GTX 1080 (8GB VRAM) — 4-bit квантизация, до ~5GB
  # Чтобы пропустить загрузку моделей: SKIP_MODEL_PULL=1
  if [[ "${SKIP_MODEL_PULL:-0}" == "1" ]]; then
    info "Skipping model pull (SKIP_MODEL_PULL=1)"
    return 0
  fi

  local models=(
    "qwen2.5:7b"    # 4.4GB — хорошо работает на русском
    "llama3.1:8b"   # 4.7GB — общего назначения
    "mistral:7b"    # 4.1GB — быстрая и качественная
  )

  info "Waiting for Ollama API to be ready..."
  local waited=0
  until guest_ssh "$TARGET" "curl -sf http://localhost:11434/api/tags >/dev/null 2>&1"; do
    sleep 3
    (( waited += 3 ))
    if (( waited >= 60 )); then
      die "Ollama API not ready after 60s"
    fi
  done

  for model in "${models[@]}"; do
    info "Pulling model: ${model}"
    # ollama pull может занять несколько минут — запускаем через sudo docker exec
    guest_ssh "$TARGET" "sudo docker exec ollama ollama pull ${model}" ||       warn "Failed to pull ${model}, skipping"
  done

  info "Installed models:"
  guest_ssh "$TARGET" "sudo docker exec ollama ollama list" || true
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
pull_models
print_access_info

audit_log "LLM stack deployed to ${TARGET}"