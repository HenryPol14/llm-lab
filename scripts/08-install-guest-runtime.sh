#!/usr/bin/env bash
# Описание: Устанавливает runtime (Docker/компоненты) внутри гостевой VM.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции
load_config                                           # загружаем конфигурацию проекта

TARGET="${1:-${LLM_IP:-${MONITORING_IP:-}}}"          # целевой IP для установки runtime
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi

mark_step "Installing guest runtime on ${TARGET}"

wait_for_ssh "$TARGET" 240

REMOTE_DOCKER_ROOT="/mnt/ai-data/docker"
REMOTE_OLLAMA_ROOT="/mnt/ai-data/ollama"
REMOTE_MODELS_ROOT="/mnt/ai-data/models"

install_docker_packages() {
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
# Base packages (ca-certificates, curl, gnupg, lsb-release, docker.io, jq, htop) are pre-installed in template.
# Ensure correct docker-compose variant is available.

sudo apt-get update -y >/dev/null 2>&1

if ! docker compose version >/dev/null 2>&1; then
  if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
  fi
fi

echo "Docker compose variant verified"
EOF
}

confirm_docker_data_migration() {
  local current_root
  current_root="$(guest_ssh "$TARGET" 'docker info --format "{{.DockerRootDir}}"' 2>/dev/null || echo "")"
  if [[ "$current_root" == "$REMOTE_DOCKER_ROOT" ]]; then
    info "Docker Root Dir already at $REMOTE_DOCKER_ROOT"
    return 0
  fi

  warn "Current Docker Root Dir: ${current_root:-/var/lib/docker}"
  info "Target Docker Root Dir: $REMOTE_DOCKER_ROOT"

  if [[ "${MIGRATE_DOCKER_DATA:-1}" != "1" ]]; then
    info "Skipping migration. Use MIGRATE_DOCKER_DATA=1 to enable."
    return 1
  fi

  local confirm
  read -p "Confirm migration of Docker data from ${current_root:-/var/lib/docker} to $REMOTE_DOCKER_ROOT? [yes/no]: " confirm
  [[ "$confirm" == "yes" ]] || die "Aborted by user"

  return 0
}

stop_docker_safely() {
  info "Stopping Docker services"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo systemctl stop docker || true
sudo systemctl stop containerd || true
i=0
while sudo systemctl is-active --quiet docker 2>/dev/null; do
  i=$((i+1))
  if (( i > 30 )); then
    echo "Timeout waiting docker to stop"
    exit 1
  fi
  sleep 1
done
echo "Docker stopped"
EOF
}

prepare_docker_dirs() {
  guest_ssh "$TARGET" 'bash -s' <<EOF
set -Eeuo pipefail
sudo mkdir -p "$REMOTE_DOCKER_ROOT"
sudo mkdir -p "$REMOTE_OLLAMA_ROOT"
sudo mkdir -p "$REMOTE_MODELS_ROOT"
echo "Directories prepared"
EOF
}

copy_docker_data() {
  info "Copying Docker data to $REMOTE_DOCKER_ROOT"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
if [ -d /var/lib/docker ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
  echo "Copying data from /var/lib/docker..."
  sudo rsync -aAXxv --progress /var/lib/docker/ /tmp/mnt-ai-data-docker/ >/dev/null 2>&1
  sudo mv /tmp/mnt-ai-data-docker/* /mnt/ai-data/docker/
  echo "Data copied"
else
  echo "No data to copy"
fi
EOF
}

configure_docker_daemon() {
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo mkdir -p /etc/docker
cat <<JSON | sudo tee /etc/docker/daemon.json
{
  "data-root": "/mnt/ai-data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
JSON
echo "Docker daemon config written"
EOF
}

start_docker_safely() {
  info "Starting Docker services"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl enable containerd

sudo systemctl start containerd
sleep 2
sudo systemctl start docker
systemctl status docker --no-pager || true
systemctl status containerd --no-pager || true

timeout=30
until docker info >/dev/null 2>&1; do
  echo "Waiting for docker to be ready..."
  sleep 2
  ((timeout--))
  if ((timeout <= 0)); then
    echo "Docker failed to start"
    exit 1
  fi
done
echo "Docker started successfully"
EOF
}

verify_docker_config() {
  info "Verifying Docker configuration"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
echo "Docker Root Dir:"
docker info --format "{{.DockerRootDir}}"
echo ""
echo "Docker compose version:"
docker compose version
echo ""
echo "Disk usage:"
df -h
EOF
}

grant_docker_access() {
  guest_ssh "$TARGET" "sudo usermod -aG docker $USER || true"
}

install_docker_packages

if confirm_docker_data_migration; then
  stop_docker_safely
  prepare_docker_dirs
  guest_ssh "$TARGET" "sudo rsync -aP /var/lib/docker/ /tmp/mnt-ai-data-docker/ || true"
  guest_ssh "$TARGET" "sudo rm -rf /tmp/mnt-ai-data-docker"
  configure_docker_daemon
  start_docker_safely
  verify_docker_config
  grant_docker_access
fi

audit_log "Guest Docker runtime installed on ${TARGET}"
