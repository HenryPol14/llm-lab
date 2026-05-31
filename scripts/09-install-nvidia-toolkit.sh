#!/usr/bin/env bash
# Описание: Устанавливает NVIDIA Container Toolkit внутри гостевой VM.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции
load_config                                           # загружаем конфигурацию проекта

TARGET="${1:-${LLM_IP:-${MONITORING_IP:-}}}"          # IP целевой VM для установки NVIDIA toolkit
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi

mark_step "Installing NVIDIA Container Toolkit on ${TARGET}"

wait_for_ssh "$TARGET" 240

# Очищаем устаревший ключ хоста — VM могла пересоздаваться
ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
mkdir -p "$HOME/.ssh"
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

check_gpu_presence() {
  local gpu_count
  gpu_count="$(guest_ssh "$TARGET" 'lspci | grep -i nvidia | wc -l' 2>/dev/null || echo "0")"  # проверяем наличие NVIDIA GPU внутри гостя
  if [[ "$gpu_count" -eq "0" ]]; then
    info "No NVIDIA GPU detected in guest, skipping NVIDIA toolkit"
    return 1
  fi
  info "Detected $gpu_count NVIDIA GPU(s) in guest"
  return 0
}

install_nvidia_drivers() {
  info "Installing NVIDIA drivers"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
if ! command -v nvidia-smi >/dev/null 2>&1; then
  # ubuntu-drivers-common is already installed in template
  ubuntu-drivers install || true
fi
# nvidia-smi может падать если модуль ядра ещё не загружен — это не ошибка
nvidia-smi || true
EOF

  # Если nvidia-smi не работает — модуль ядра не загружен, нужна перезагрузка
  local smi_ok
  smi_ok="$(guest_ssh "$TARGET" 'nvidia-smi -L 2>/dev/null | wc -l' || echo "0")"
  if [[ "$smi_ok" -eq 0 ]]; then
    info "NVIDIA kernel module not loaded, rebooting VM..."
    guest_ssh "$TARGET" 'sudo reboot' || true
    sleep 15
    wait_for_ssh "$TARGET" 180
    ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
    ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    guest_ssh "$TARGET" 'nvidia-smi' || die "nvidia-smi failed after reboot"
  fi
  info "NVIDIA drivers OK"
}

install_nvidia_toolkit() {
  info "Installing NVIDIA Container Toolkit"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  echo "NVIDIA Container Toolkit already installed"
else
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -y >/dev/null 2>&1
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
fi
EOF
}

configure_nvidia_runtime() {
  info "Configuring NVIDIA runtime for Docker"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
sleep 5
docker run --rm --gpus all nvidia/cuda:11.6.2-base-ubuntu20.04 nvidia-smi || true
EOF
}

verify_installation() {
  info "Verifying NVIDIA Container Toolkit installation"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -EEu
echo "Docker info:"
docker info | grep -i nvidia || true
echo "NVIDIA runtime configured:"
docker info | grep -i runtime || true
echo "GPU test:"
timeout 30 docker run --rm --gpus all nvidia/cuda:11.6.2-base-ubuntu20.04 nvidia-smi || true
EOF
}

if ! check_gpu_presence; then
  audit_log "NVIDIA toolkit skipped on ${TARGET} (no GPU detected)"
  exit 0
fi

install_nvidia_drivers
install_nvidia_toolkit
configure_nvidia_runtime
verify_installation

audit_log "NVIDIA Container Toolkit installed on ${TARGET}"