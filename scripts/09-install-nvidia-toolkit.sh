#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-${MONITORING_IP:-}}}"
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi

mark_step "Installing NVIDIA Container Toolkit on ${TARGET}"

wait_for_ssh "$TARGET" 240

check_gpu_presence() {
  local gpu_count
  gpu_count="$(guest_ssh "$TARGET" 'lspci | grep -i nvidia | wc -l' 2>/dev/null || echo "0")"
  if [[ "$gpu_count" -eq "0" ]]; then
    info "No NVIDIA GPU detected in guest, skipping NVIDIA toolkit"
    return 1
  fi
  info "Detected $gpu_count NVIDIA GPU(s) in guest"
  return 0
}

install_nvidia_drivers() {
  info "Installing NVIDIA drivers"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
if ! command -v nvidia-smi >/dev/null 2>&1; then
  # ubuntu-drivers-common is already installed in template
  sudo ubuntu-drivers install || true
  sleep 5
  nvidia-smi || true
else
  echo "NVIDIA drivers already installed"
  nvidia-smi
fi
EOF
}

install_nvidia_toolkit() {
  info "Installing NVIDIA Container Toolkit"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
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
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
sleep 5
docker run --rm --gpus all nvidia/cuda:11.6.2-base-ubuntu20.04 nvidia-smi || true
EOF
}

verify_installation() {
  info "Verifying NVIDIA Container Toolkit installation"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
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
