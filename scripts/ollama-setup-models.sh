#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Настраивает диспетчеризацию моделей в Ollama для CPU/GPU распределения.
#   Маленькие модели (<7B) запускаются на GPU, большие — на CPU при нехватке VRAM.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-}}"
[[ -n "$TARGET" ]] || die "Target IP required. Usage: $0 <IP>"

mark_step "Configuring Ollama model dispatch on ${TARGET}"

wait_for_ssh "$TARGET" 240
ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

# ---------------------------------------------------------------------------
configure_model_dispatch() {
  info "Configuring model dispatch (GPU for 7B models, CPU fallback)"
  
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail

cd /opt/llm-stack

# Проверить наличие GPU
if /usr/bin/nvidia-smi -L >/dev/null 2>&1; then
  echo "GPU detected:"
  /usr/bin/nvidia-smi -L
  
  # Установить переменные окружения для GPU использования
  # OLLAMA_GPU_OVERLAP: коэффициент параллелизма GPU (0.7 = 70% VRAM)
  export OLLAMA_GPU_OVERLAP=0.7
  export OLLAMA_MAX_MEMORY="6G"  # Оставить 2GB для системы
  
  echo "GPU environment variables set:"
  echo "  OLLAMA_GPU_OVERLAP=0.7"
  echo "  OLLAMA_MAX_MEMORY=6G"
  
  # Модель mistral:7b — использует GPU автоматически (7B fits in 8GB VRAM)
  echo "Model mistral:7b will use GPU automatically"
else
  echo "No GPU detected - all models will use CPU"
  
  # Для CPU: использовать больше потоков
  export OLLAMA_NUM_THREADS=4
  echo "CPU environment variables set:"
  echo "  OLLAMA_NUM_THREADS=4"
fi

# Показать текущие модели
echo ""
echo "Installed models:"
docker compose exec -T ollama /bin/ollama list

echo ""
echo "Model dispatch configuration complete."
echo "Models are dispatched automatically based on size and VRAM availability."
echo "For GPU models: use 'OLLAMA_GPU_OVERLAP=0.7' for 70% VRAM usage."
echo "For CPU models: use 'OLLAMA_NUM_THREADS=4' for 4 CPU cores."
EOF
}

# ---------------------------------------------------------------------------
configure_model_dispatch
info "Ollama model dispatch configured on ${TARGET}"
