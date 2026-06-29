#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Устанавливает Docker runtime внутри гостевой VM.
#   Заменяет два идентичных файла:
#     deployment-install-guest-runtime-llm.sh
#     deployment-install-guest-runtime-monitoring.sh
#
# Использование:
#   deployment-install-guest-runtime.sh <IP>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:?Target IP required. Usage: $0 <IP>}"

mark_step "Installing Docker runtime on ${TARGET}"

wait_for_ssh "$TARGET" 240
ssh-keygen -R "$TARGET" >/dev/null 2>&1 || true
ssh-keyscan -H "$TARGET" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

REMOTE_DOCKER_ROOT="/mnt/data/docker"
REMOTE_MODELS_ROOT="/mnt/data/models"
REMOTE_OLLAMA_ROOT="/mnt/data/ollama"

# ---------------------------------------------------------------------------
verify_data_mount() {
  info "Checking /mnt/data mount on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
mountpoint -q /mnt/data || { echo "WARN: /mnt/data is not a mountpoint"; exit 0; }
echo "OK: /mnt/data is mounted"
EOF
}

# ---------------------------------------------------------------------------
install_docker_packages() {
  info "Installing Docker Compose on ${TARGET}"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
apt-get update -qq

if docker compose version >/dev/null 2>&1; then
  echo "Docker Compose already installed: $(docker compose version)"
  exit 0
fi

for pkg in docker-compose-v2 docker-compose-plugin docker-compose; do
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
    break
  fi
done

docker compose version
EOF
}

# ---------------------------------------------------------------------------
configure_docker_daemon() {
  info "Configuring Docker daemon (data-root=${REMOTE_DOCKER_ROOT})"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
# идемпотентно: пишем только если data-root отличается или файла нет
WANTED="/mnt/data/docker"
CURRENT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '')"
if [[ "$CURRENT" == "$WANTED" ]]; then
  echo "Docker Root Dir already at $WANTED"
  exit 0
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "data-root": "/mnt/data/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" },
  "storage-driver": "overlay2"
}
JSON
echo "daemon.json written"
EOF
}

# ---------------------------------------------------------------------------
migrate_docker_data() {
  # Нужна миграция только если есть старые данные не в целевом каталоге
  local current_root
  current_root="$(guest_ssh "$TARGET" \
    "docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo ''" || echo "")"

  if [[ "$current_root" == "$REMOTE_DOCKER_ROOT" ]]; then
    info "Docker Root Dir already at $REMOTE_DOCKER_ROOT, skipping migration"
    return 0
  fi

  local has_data
  has_data="$(guest_ssh "$TARGET" \
    'sudo find /var/lib/docker -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | wc -l' \
    || echo 0)"

  if [[ "$has_data" == "0" ]]; then
    info "No existing Docker data to migrate"
    return 0
  fi

  # Non-interactive: требуем явного флага
  if [[ "${CONFIRM_DOCKER_MIGRATION:-no}" != "yes" ]]; then
    if [[ ! -t 0 ]]; then
      warn "Skipping Docker data migration (set CONFIRM_DOCKER_MIGRATION=yes to enable)"
      return 0
    fi
    local ans
    read -r -p "Migrate Docker data to $REMOTE_DOCKER_ROOT? [yes/no]: " ans || true
    [[ "$ans" == "yes" ]] || { warn "Migration skipped by user"; return 0; }
  fi

  info "Stopping Docker before data migration"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
systemctl stop docker || true
systemctl stop containerd || true
i=0
while systemctl is-active --quiet docker 2>/dev/null; do
  sleep 1; ((i++)); (( i > 30 )) && { echo "Timeout stopping Docker"; exit 1; }
done
EOF

  info "Copying /var/lib/docker → $REMOTE_DOCKER_ROOT"
  guest_ssh "$TARGET" bash -s -- "$REMOTE_DOCKER_ROOT" <<'EOF'
set -Eeuo pipefail
REMOTE_DOCKER_ROOT="$1"
sudo mkdir -p "$REMOTE_DOCKER_ROOT"
sudo rsync -aAX --delete /var/lib/docker/ "$REMOTE_DOCKER_ROOT"/
echo "Migration done"
EOF
}

# ---------------------------------------------------------------------------
start_docker() {
  info "Starting Docker on ${TARGET}"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
systemctl daemon-reload
systemctl enable docker containerd
systemctl start containerd
sleep 2
systemctl start docker

timeout=30
until docker info >/dev/null 2>&1; do
  sleep 2; ((timeout--))
  (( timeout <= 0 )) && { echo "Docker failed to start"; exit 1; }
done
echo "Docker started: $(docker info --format '{{.DockerRootDir}}')"
EOF
}

# ---------------------------------------------------------------------------
prepare_data_dirs() {
  info "Creating data directories on ${TARGET}"
  # FIX: переменные передаём как аргументы, не через heredoc-интерполяцию
  guest_ssh "$TARGET" bash -s -- \
    "$REMOTE_DOCKER_ROOT" "$REMOTE_OLLAMA_ROOT" "$REMOTE_MODELS_ROOT" \
    "${GUEST_USER:-ubuntu}" <<'EOF'
set -Eeuo pipefail
DOCKER_ROOT="$1" OLLAMA_ROOT="$2" MODELS_ROOT="$3" GUSER="$4"
sudo mkdir -p "$DOCKER_ROOT" "$OLLAMA_ROOT" "$MODELS_ROOT"
sudo chown -R "${GUSER}:${GUSER}" "$OLLAMA_ROOT" "$MODELS_ROOT"
echo "Directories ready"
EOF
}

# ---------------------------------------------------------------------------
grant_docker_access() {
  # FIX: GUEST_USER передаём явно как аргумент
  guest_ssh "$TARGET" bash -s -- "${GUEST_USER:-ubuntu}" <<'EOF'
set -Eeuo pipefail
sudo usermod -aG docker "$1" && echo "User $1 added to docker group"
EOF
}

# ---------------------------------------------------------------------------
verify_docker() {
  info "Verifying Docker on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
echo "Root:    $(docker info --format '{{.DockerRootDir}}')"
echo "Compose: $(docker compose version)"
echo "Disk:";  df -h /mnt/data
EOF
}

# ---------------------------------------------------------------------------
verify_data_mount
install_docker_packages
prepare_data_dirs
migrate_docker_data
configure_docker_daemon
start_docker
grant_docker_access
verify_docker

audit_log "Docker runtime installed on ${TARGET}"
