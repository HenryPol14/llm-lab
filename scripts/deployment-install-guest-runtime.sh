#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Устанавливает Docker runtime внутри гостевой VM (LLM или Monitoring).
# Заменяет два идентичных скрипта: deployment-install-guest-runtime-llm.sh
# и deployment-install-guest-runtime-monitoring.sh
#
# Использование:
#   deployment-install-guest-runtime.sh <IP>
#   deployment-install-guest-runtime.sh 10.10.10.50   # LLM VM
#   deployment-install-guest-runtime.sh 10.10.10.60   # Monitoring VM
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  die "Target IP required. Usage: $0 <IP>"
fi

mark_step "Installing guest Docker runtime on ${TARGET}"

wait_for_ssh "$TARGET" 240

ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
mkdir -p "$HOME/.ssh"
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

REMOTE_DOCKER_ROOT="/mnt/data/docker"
REMOTE_OLLAMA_ROOT="/mnt/data/ollama"
REMOTE_MODELS_ROOT="/mnt/data/models"

verify_data_mount() {
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail || true
mountpoint -q /mnt/data || true
test -d /mnt/data/docker || true
EOF
}

install_docker_packages() {
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
sudo apt-get update -qq

if ! docker compose version >/dev/null 2>&1; then
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
  fi
fi

echo "Docker Compose verified: $(docker compose version)"
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

  local has_existing_data
  has_existing_data="$(guest_ssh "$TARGET" \
    'test -d /var/lib/docker && test -n "$(sudo find /var/lib/docker -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" && echo yes || echo no' \
    || echo no)"
  if [[ "$has_existing_data" != "yes" ]]; then
    info "No existing Docker data to migrate"
    return 0
  fi

  if [[ "${MIGRATE_DOCKER_DATA:-1}" != "1" ]]; then
    info "Skipping migration. Use MIGRATE_DOCKER_DATA=1 to enable."
    return 1
  fi

  if [[ "${CONFIRM_DOCKER_MIGRATION:-no}" != "yes" ]]; then
    if [[ ! -t 0 ]]; then
      die "Non-interactive: Docker data migration requires CONFIRM_DOCKER_MIGRATION=yes"
    fi
    local confirm
    read -r -p "Confirm Docker data migration to $REMOTE_DOCKER_ROOT? [yes/no]: " confirm || true
    [[ "$confirm" == "yes" ]] || die "Aborted by user"
  fi

  return 0
}

stop_docker_safely() {
  info "Stopping Docker services"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
sudo systemctl stop docker || true
sudo systemctl stop containerd || true
i=0
while sudo systemctl is-active --quiet docker 2>/dev/null; do
  i=$((i+1))
  (( i > 30 )) && { echo "Timeout waiting docker to stop"; exit 1; }
  sleep 1
done
echo "Docker stopped"
EOF
}

prepare_docker_dirs() {
  # FIX: REMOTE_* переменные передаём явно, чтобы они были доступны в remote bash
  guest_ssh "$TARGET" bash -s -- "$REMOTE_DOCKER_ROOT" "$REMOTE_OLLAMA_ROOT" "$REMOTE_MODELS_ROOT" <<'EOF'
set -Eeuo pipefail
REMOTE_DOCKER_ROOT="$1"
REMOTE_OLLAMA_ROOT="$2"
REMOTE_MODELS_ROOT="$3"
sudo mkdir -p "$REMOTE_DOCKER_ROOT" "$REMOTE_OLLAMA_ROOT" "$REMOTE_MODELS_ROOT"
echo "Directories prepared"
EOF
}

copy_docker_data() {
  info "Copying Docker data to $REMOTE_DOCKER_ROOT"
  guest_ssh "$TARGET" bash -s -- "$REMOTE_DOCKER_ROOT" <<'EOF'
set -Eeuo pipefail
REMOTE_DOCKER_ROOT="$1"
if [[ -d /var/lib/docker ]] && [[ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]]; then
  echo "Copying data from /var/lib/docker..."
  sudo rsync -aAX --delete /var/lib/docker/ "$REMOTE_DOCKER_ROOT"/
  echo "Data copied"
else
  echo "No data to copy"
fi
EOF
}

configure_docker_daemon() {
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
sudo mkdir -p /etc/docker
cat <<JSON | sudo tee /etc/docker/daemon.json
{
  "data-root": "/mnt/data/docker",
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
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
sudo systemctl daemon-reload
sudo systemctl enable docker containerd
sudo systemctl start containerd
sleep 2
sudo systemctl start docker
systemctl status docker --no-pager || true

timeout=30
until sudo docker info >/dev/null 2>&1; do
  echo "Waiting for docker to be ready..."
  sleep 2
  ((timeout--))
  (( timeout <= 0 )) && { echo "Docker failed to start"; exit 1; }
done
echo "Docker started successfully"
EOF
}

verify_docker_config() {
  info "Verifying Docker configuration"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
echo "Docker Root Dir: $(docker info --format '{{.DockerRootDir}}')"
echo "Docker Compose: $(docker compose version)"
echo "Disk usage:"; df -h
EOF
}

grant_docker_access() {
  # FIX: GUEST_USER передаём явно как аргумент
  guest_ssh "$TARGET" bash -s -- "${GUEST_USER:-ubuntu}" <<'EOF'
set -Eeuo pipefail
sudo usermod -aG docker "$1"
echo "User $1 added to docker group"
EOF
}

verify_data_mount
install_docker_packages

if confirm_docker_data_migration; then
  stop_docker_safely
  prepare_docker_dirs
  copy_docker_data
  configure_docker_daemon
  start_docker_safely
  verify_docker_config
  grant_docker_access
fi

audit_log "Guest Docker runtime installed on ${TARGET}"
