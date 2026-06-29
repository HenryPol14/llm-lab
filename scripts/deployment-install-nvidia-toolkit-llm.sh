#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Устанавливает NVIDIA драйверы и Container Toolkit в LLM VM.
#
#   Порядок:
#     1. Проверяем наличие GPU через lspci
#     2. Устанавливаем драйвер ubuntu-drivers
#     3. Перезагружаем VM если модуль ещё не загружен
#     4. Устанавливаем nvidia-container-toolkit
#     5. Конфигурируем docker runtime
#     6. Верифицируем — без || true, ошибка = реальный провал
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-}}"
[[ -n "$TARGET" ]] || die "Target IP required. Usage: $0 <IP>"

mark_step "Installing NVIDIA Container Toolkit on ${TARGET}"
wait_for_ssh "$TARGET" 240
ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

# ---------------------------------------------------------------------------
check_gpu_presence() {
  local count
  count="$(guest_ssh "$TARGET" 'lspci | grep -ci nvidia' 2>/dev/null || echo 0)"
  if [[ "$count" -eq 0 ]]; then
    info "No NVIDIA GPU found in guest — skipping toolkit"
    return 1
  fi
  info "Detected ${count} NVIDIA device(s) in guest"
  return 0
}

# ---------------------------------------------------------------------------
install_nvidia_drivers() {
  info "Installing NVIDIA drivers via ubuntu-drivers"

  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
# Устанавливаем ubuntu-drivers-common если нет
if ! command -v ubuntu-drivers >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common
fi

if /usr/bin/nvidia-smi >/dev/null 2>&1; then
  echo "NVIDIA driver already loaded:"
  /usr/bin/nvidia-smi -L
  exit 0
fi

echo "Installing recommended NVIDIA driver..."
ubuntu-drivers install
echo "Driver package installed (kernel module not loaded until reboot)"
EOF

  # Проверяем загружен ли модуль
  local loaded
  loaded="$(guest_ssh "$TARGET" \
    'sudo /usr/bin/nvidia-smi -L 2>/dev/null | wc -l' || echo 0)"

  if [[ "$loaded" -gt 0 ]]; then
    info "NVIDIA kernel module already loaded (${loaded} GPU(s))"
    return 0
  fi

  # Модуль не загружен — нужна перезагрузка
  info "NVIDIA module not loaded yet — rebooting VM to activate driver"
  guest_ssh "$TARGET" 'sudo reboot' || true
  sleep 20   # ждём пока VM уйдёт в reboot прежде чем опрашивать SSH

  info "Waiting for VM to come back..."
  wait_for_ssh "$TARGET" 300
  ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
  ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

  # После reboot модуль обязан загрузиться
  guest_ssh "$TARGET" 'sudo /usr/bin/nvidia-smi -L' \
    || die "nvidia-smi failed after reboot — check driver installation"
  info "NVIDIA driver OK after reboot"
}

# ---------------------------------------------------------------------------
install_nvidia_toolkit() {
  info "Installing nvidia-container-toolkit"

  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail

if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  echo "nvidia-container-toolkit already installed"
  exit 0
fi

# Добавляем репозиторий NVIDIA
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
echo "nvidia-container-toolkit installed"
EOF
}

# ---------------------------------------------------------------------------
configure_docker_runtime() {
  info "Configuring nvidia runtime for Docker"

  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
# Ждём пока docker поднимется
timeout=30
until docker info >/dev/null 2>&1; do
  sleep 2; ((timeout--))
  (( timeout <= 0 )) && { echo "Docker failed to restart"; exit 1; }
done
echo "Docker restarted with nvidia runtime"
EOF
}

# ---------------------------------------------------------------------------
# FIX: убран || true из GPU-теста — если GPU не работает, это реальный провал.
# configure_nvidia_runtime() запускал docker run до того как после reboot
# nvidia-smi успевал заработать; теперь тест вынесен сюда с явным die().
verify_gpu_in_docker() {
  info "Verifying GPU access inside Docker"

  # Проверяем что nvidia runtime зарегистрирован
  local has_runtime
  has_runtime="$(guest_ssh "$TARGET" \
    "docker info --format '{{range .Runtimes}}{{.}}{{end}}' 2>/dev/null | grep -c nvidia" \
    || echo 0)"
  [[ "$has_runtime" -gt 0 ]] || die "nvidia runtime not registered in Docker"

  # Запускаем тест-контейнер
  info "Running GPU container test (nvidia-smi inside Docker)"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
# Используем небольшой образ чтобы не тянуть 4GB cuda образ при каждом запуске
if docker run --rm --gpus all ubuntu:22.04 \
    sh -c 'ls /dev/nvidia* 2>/dev/null && echo "GPU devices visible"'; then
  echo "GPU test PASSED"
else
  echo "GPU device test failed — trying nvidia-smi container"
  # Fallback: полный образ (уже скачан на этапе configure)
  docker run --rm --gpus all nvidia/cuda:11.6.2-base-ubuntu20.04 nvidia-smi
fi
EOF
}

# ---------------------------------------------------------------------------
if ! check_gpu_presence; then
  audit_log "NVIDIA toolkit skipped on ${TARGET} (no GPU)"
  exit 0
fi

install_nvidia_drivers
install_nvidia_toolkit
configure_docker_runtime
verify_gpu_in_docker

info "NVIDIA Container Toolkit ready on ${TARGET}"
audit_log "NVIDIA toolkit installed on ${TARGET}"
