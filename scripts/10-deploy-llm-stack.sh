#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Деплой стека LLM (Ollama, OpenWebUI, monitoring exporters)
# в гостевую VM с автоматической загрузкой моделей.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-${MONITORING_IP:-}}}"

if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi

REMOTE_STACK="/opt/llm-stack"

mark_step "Deploying LLM stack to ${TARGET}"

wait_for_ssh "$TARGET" 240

# VM могла быть пересоздана
ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
mkdir -p "$HOME/.ssh"
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

setup_remote_directory() {
  # Создаем директорию для LLM стека на удаленной машине
  guest_ssh "$TARGET" "sudo mkdir -p \"${REMOTE_STACK}\" && sudo chown \"${GUEST_USER}:${GUEST_USER}\" \"${REMOTE_STACK}\""
}

transfer_stack() {
  info "Transferring docker compose stack"
  # Опции SCP для копирования файлов
  SCP_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  # Копируем docker compose файлы на удаленную машину
  # shellcheck disable=SC2086
  scp ${SCP_OPTS} -r "${PROJECT_ROOT}/docker/llm/." "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/"
}

check_existing_containers() {
  local existing
  # Проверяем есть ли уже запущенные контейнеры
  existing="$(guest_ssh "$TARGET" "cd \"${REMOTE_STACK}\" && docker compose ps -q")"
  if [[ -n "$existing" ]]; then
    info "Existing containers found, will be updated"
    return 0
  fi
  return 1
}

deploy_stack() {
  info "Deploying with Docker Compose"
  # Запускаем контейнеры через docker compose
  guest_ssh "$TARGET" "cd \"${REMOTE_STACK}\" && sudo docker compose up -d --remove-orphans"
}

wait_for_ollama() {
  info "Waiting for Ollama API"

  local waited=0

  until guest_ssh "$TARGET" \
    "curl -sf http://localhost:11434/api/tags >/dev/null 2>&1"; do

    sleep 3
    (( waited += 3 ))

    if (( waited >= 180 )); then
      error "Ollama did not become ready"

      guest_ssh "$TARGET" \
        "sudo docker logs --tail 200 ollama" || true

      die "Ollama API not ready after 180 seconds"
    fi
  done

  info "Ollama API is ready"
}

pull_models() {
  # Модели подобраны под GTX 1080 (8GB VRAM) — 4-bit квантизация, до ~5GB
  # Чтобы пропустить загрузку моделей: SKIP_MODEL_PULL=1
  if [[ "${SKIP_MODEL_PULL:-0}" == "1" ]]; then
    info "Skipping model pull (SKIP_MODEL_PULL=1)"
    return 0
  fi

  # Список моделей для загрузки
  local models=(
    "llama3.2:3b"   # 2.0GB — общего назначения, компактная
    "llama3.2:1b"   # 1.3GB — самая быстрая, для лёгких задач
    "mistral:7b"    # 4.4GB — быстрая и качественная
  )

  info "Waiting for Ollama API to be ready..."
  # Ждем пока Ollama API станет доступен (до 60 секунд)
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
    # Загружаем модель через Docker exec (может занять несколько минут)
    guest_ssh "$TARGET" "sudo docker exec ollama ollama pull \"${model}\"" ||       warn "Failed to pull ${model}, skipping"
  done

  # Выводим список установленных моделей
  info "Installed models:"
  guest_ssh "$TARGET" "sudo docker exec ollama ollama list" || true
}

verify_gpu() {
  info "Verifying GPU access"

  guest_ssh "$TARGET" \
    "nvidia-smi >/dev/null" \
    || die "GPU verification failed"
}

verify_deployment() {
  info "Verifying LLM stack deployment"
  # Проверяем статус контейнеров и доступность сервисов
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
  # Выводим ссылки для доступа к сервисам
  info "  - Ollama API: http://${TARGET}:11434"
  info "  - OpenWebUI: http://${TARGET}:3000"
}

setup_remote_directory

check_existing_containers || \
  info "No existing containers found, performing initial deployment"

transfer_stack
deploy_stack
wait_for_ollama
verify_gpu
pull_models
verify_deployment
print_access_info

audit_log "LLM stack deployed to ${TARGET}"