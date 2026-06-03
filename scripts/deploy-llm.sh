#!/usr/bin/env bash
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
  info "Preparing remote directory"

  guest_ssh "$TARGET" "
    sudo mkdir -p ${REMOTE_STACK}
    sudo mkdir -p /mnt/data/ollama
    sudo mkdir -p /mnt/data/openwebui
    sudo chown -R ${GUEST_USER}:${GUEST_USER} ${REMOTE_STACK}
  "
}

transfer_stack() {
  info "Transferring Docker Compose stack"

  local SCP_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"

  scp ${SCP_OPTS} \
    -r "${PROJECT_ROOT}/docker/llm/." \
    "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/"
}

check_existing_containers() {
  local existing

  existing="$(
    guest_ssh "$TARGET" \
      "cd ${REMOTE_STACK} 2>/dev/null && sudo docker compose ps -q" \
      2>/dev/null || true
  )"

  if [[ -n "$existing" ]]; then
    info "Existing containers found, deployment will update them"
    return 0
  fi

  return 1
}

deploy_stack() {
  info "Deploying Docker Compose stack"

  guest_ssh "$TARGET" "
    cd ${REMOTE_STACK}
    sudo docker compose up -d --remove-orphans
  "
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

  if [[ "${SKIP_MODEL_PULL:-0}" == "1" ]]; then
    info "Skipping model pull (SKIP_MODEL_PULL=1)"
    return 0
  fi

  local models=(
    "qwen2.5:7b"
    "llama3.1:8b"
    "mistral:7b"
  )

  for model in "${models[@]}"; do

    if guest_ssh "$TARGET" \
      "sudo docker exec ollama ollama list | grep -q '^${model}[[:space:]]'"; then

      info "Model already installed: ${model}"
      continue
    fi

    info "Pulling model: ${model}"

    guest_ssh "$TARGET" \
      "sudo docker exec ollama ollama pull ${model}" \
      || warn "Failed to pull model ${model}"
  done

  info "Installed models:"

  guest_ssh "$TARGET" \
    "sudo docker exec ollama ollama list" \
    || true
}

verify_gpu() {
  info "Verifying GPU access"

  guest_ssh "$TARGET" \
    "nvidia-smi >/dev/null" \
    || die "GPU verification failed"
}

verify_deployment() {

  info "Verifying LLM stack deployment"

  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail

cd /opt/llm-stack

echo "=== Container status ==="
sudo docker compose ps

echo
echo "=== Running containers ==="

RUNNING=$(
  sudo docker compose ps \
    --services \
    --filter status=running \
    | wc -l
)

if [[ "$RUNNING" -eq 0 ]]; then
  echo "No containers are running"
  exit 1
fi

echo
echo "=== Ollama API ==="

timeout 10 curl -sf http://localhost:11434/api/tags >/dev/null

echo "OK"

echo
echo "=== Installed models ==="

MODELS=$(
  sudo docker exec ollama ollama list \
    | tail -n +2 \
    | wc -l
)

if [[ "$MODELS" -eq 0 ]]; then
  echo "No models installed"
  exit 1
fi

echo "Models installed: ${MODELS}"

echo
echo "=== OpenWebUI ==="

timeout 20 curl -sf http://localhost:3000/ >/dev/null

echo "OK"

echo
echo "=== GPU ==="

nvidia-smi >/dev/null

echo "OK"

echo
echo "LLM stack verification successful"
EOF
}

print_access_info() {

  info "LLM stack deployed successfully"
  info "OpenWebUI : http://${TARGET}:3000"
  info "Ollama API : http://${TARGET}:11434"

  info "Installed models:"

  guest_ssh "$TARGET" \
    "sudo docker exec ollama ollama list" \
    || true
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