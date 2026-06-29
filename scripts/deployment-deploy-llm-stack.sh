#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Разворачивает LLM стек (Ollama + OpenWebUI + node-exporter + dcgm-exporter).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-}}"
[[ -n "$TARGET" ]] || die "Target IP required. Usage: $0 <IP>"

REMOTE_STACK="/opt/llm-stack"

mark_step "Deploying LLM stack to ${TARGET}"
wait_for_ssh "$TARGET" 240

# ---------------------------------------------------------------------------
prepare_data_dirs() {
  info "Preparing data directories on ${TARGET}"

  # FIX: GUEST_USER передаём как позиционный аргумент — в remote bash
  # переменные local-окружения недоступны при heredoc с 'EOF' (single quotes).
  guest_ssh "$TARGET" bash -s -- "${GUEST_USER:-ubuntu}" <<'EOF'
set -Eeuo pipefail
GUSER="$1"
sudo mkdir -p /mnt/data/ollama /mnt/data/models /mnt/data/openwebui /mnt/data/docker
sudo chown -R "${GUSER}:${GUSER}" \
  /mnt/data/ollama /mnt/data/models /mnt/data/openwebui
echo "Data directories prepared"
EOF
}

# ---------------------------------------------------------------------------
setup_remote_directory() {
  # FIX: GUEST_USER передаём аргументом
  guest_ssh "$TARGET" bash -s -- "$REMOTE_STACK" "${GUEST_USER:-ubuntu}" <<'EOF'
set -Eeuo pipefail
sudo mkdir -p "$1"
sudo chown "$2:$2" "$1"
EOF
}

# ---------------------------------------------------------------------------
render_compose_config() {
  info "Rendering docker-compose config"
  cp -R "${PROJECT_ROOT}/docker/llm/." "${TMP_DIR}/"
  sed -i "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" \
    "${TMP_DIR}/docker-compose.yml" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
transfer_stack() {
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  info "Transferring LLM stack to ${TARGET}:${REMOTE_STACK}"
  # shellcheck disable=SC2086
  scp -r $opts "${TMP_DIR}/." "${GUEST_USER:-ubuntu}@${TARGET}:${REMOTE_STACK}/" \
    || die "scp failed"
}

# ---------------------------------------------------------------------------
deploy_stack() {
  info "Deploying LLM stack (idempotent)"

  # FIX: идемпотентная проверка на локальной стороне — не exit внутри heredoc
  local running
  running="$(guest_ssh "$TARGET" \
    "cd ${REMOTE_STACK} && sudo docker compose ps -q 2>/dev/null | wc -l" || echo 0)"

  if [[ "$running" -gt 0 ]]; then
    info "LLM stack already running (${running} containers) — pulling updates"
    guest_ssh "$TARGET" \
      "cd ${REMOTE_STACK} && sudo docker compose pull --quiet || true"
    guest_ssh "$TARGET" \
      "cd ${REMOTE_STACK} && sudo docker compose up -d --remove-orphans"
  else
    info "Starting LLM stack for the first time"
    guest_ssh "$TARGET" \
      "cd ${REMOTE_STACK} && sudo docker compose pull --quiet || true"
    guest_ssh "$TARGET" \
      "cd ${REMOTE_STACK} && sudo docker compose up -d"
  fi
}

# ---------------------------------------------------------------------------
verify_deployment() {
  info "Verifying LLM stack on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/llm-stack
echo "=== Container status ==="
sudo docker compose ps

RUNNING="$(sudo docker compose ps -q | wc -l)"
[[ "$RUNNING" -gt 0 ]] || { echo "ERROR: no running containers"; exit 1; }

echo "=== Health checks ==="
timeout 30 curl -fsS http://localhost:11434/api/tags \
  && echo "Ollama API OK" || echo "WARN: Ollama not ready yet (may still be loading)"

# Installation logic for optimal model selection based on system resources
# 8GB GPU + 32GB RAM → prefer GPU-capable 7B models
# If no GPU → use CPU-optimized 3B models

# ---------------------------------------------------------------------------
install_models_if_needed() {
  info "Checking GPU availability and installing optimal models"

  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail

# Check GPU availability via nvidia-smi
if /usr/bin/nvidia-smi -L >/dev/null 2>&1; then
  echo "GPU detected - installing mistral:7b (GPU-optimized 7B model)"
  
  # Pull GPU-optimized model (7B fits in 8GB VRAM with ~1GB headroom)
  if ! /usr/bin/ollama list 2>/dev/null | tail -n +2 | grep -q "mistral:7b"; then
    /usr/bin/ollama pull mistral:7b
    echo "Model mistral:7b installed"
  else
    echo "Model mistral:7b already present"
  fi
  
  # Optional: pull llama3.2:3b as backup for CPU fallback
  echo "Installing llama3.2:3b as CPU fallback model..."
  if ! /usr/bin/ollama list 2>/dev/null | tail -n +2 | grep -q "llama3.2:3b"; then
    /usr/bin/ollama pull llama3.2:3b
    echo "Model llama3.2:3b installed"
  else
    echo "Model llama3.2:3b already present"
  fi
else
  echo "No GPU detected - installing llama3.2:3b (CPU-optimized)"
  
  if ! /usr/bin/ollama list 2>/dev/null | tail -n +2 | grep -q "llama3.2:3b"; then
    /usr/bin/ollama pull llama3.2:3b
    echo "Model llama3.2:3b installed"
  else
    echo "Model llama3.2:3b already present"
  fi
fi

echo "Available models:"
/usr/bin/ollama list
EOF
}

# ---------------------------------------------------------------------------
verify_deployment() {
  info "Verifying LLM stack on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/llm-stack
echo "=== Container status ==="
sudo docker compose ps

RUNNING="$(sudo docker compose ps -q | wc -l)"
[[ "$RUNNING" -gt 0 ]] || { echo "ERROR: no running containers"; exit 1; }

echo "=== Health checks ==="
timeout 30 curl -fsS http://localhost:11434/api/tags \
  && echo "Ollama API OK" || echo "WARN: Ollama not ready yet (may still be loading)"

timeout 15 curl -fsS http://localhost:3000/login >/dev/null \
  && echo "Open WebUI OK" || echo "WARN: WebUI not ready yet"
EOF

  # Install models after Ollama is healthy
  install_models_if_needed
}

# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

render_compose_config
setup_remote_directory
transfer_stack
prepare_data_dirs
deploy_stack
install_models_if_needed
verify_deployment

info "LLM stack deployed:"
info "  Ollama API:  http://${TARGET}:11434"
info "  Open WebUI:  http://${TARGET}:3000"
audit_log "LLM stack deployed to ${TARGET}"
