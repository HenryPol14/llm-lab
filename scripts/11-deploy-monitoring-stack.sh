#!/usr/bin/env bash
# Описание: Деплой мониторингового стека (Prometheus, Grafana) в VM.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции
load_config                                           # загружаем конфигурацию проекта

TARGET="${1:-${MONITORING_IP:-${LLM_IP:-}}}"       # IP целевой VM для мониторинга
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi

REMOTE_STACK=/opt/monitoring-stack

mark_step "Deploying monitoring stack to ${TARGET}"

wait_for_ssh "$TARGET" 240

render_prometheus_config() {
  local target_dir="$1"
  info "Rendering Prometheus config for LLM target ${LLM_IP:-10.10.10.50} and Monitoring target ${MONITORING_IP:-10.10.10.60}" >&2
  cp -R "${PROJECT_ROOT}/docker/monitoring/." "$target_dir/"
  mkdir -p "$target_dir/prometheus"
  sed \
    -e "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" \
    -e "s/{{MONITORING_IP}}/${MONITORING_IP:-10.10.10.60}/g" \
    "${PROJECT_ROOT}/monitoring/prometheus/prometheus.yml.tpl" > "$target_dir/prometheus/prometheus.yml"
}

setup_remote_directory() {
  guest_ssh "$TARGET" "sudo mkdir -p ${REMOTE_STACK} && sudo chown ${GUEST_USER}:${GUEST_USER} ${REMOTE_STACK}"
}

transfer_stack() {
  info "Transferring docker compose stack"
  local tmp_dir="$1"
  SCP_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  scp ${SCP_OPTS} -r "$tmp_dir/." "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/"
}

check_existing_containers() {
  local existing
  existing="$(guest_ssh "$TARGET" "cd ${REMOTE_STACK} && docker compose ps --quiet")"
  if [[ -n "$existing" ]]; then
    info "Existing containers found, will be updated"
    return 0
  fi
  return 1
}

validate_prometheus_config() {
  info "Validating Prometheus configuration"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/monitoring-stack
if docker compose ps --quiet | grep -q prometheus; then
  echo "Testing Prometheus config..."
  sudo docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml || {
    echo "Prometheus config is invalid"
    exit 1
  }
  echo "Prometheus config is valid"
else
  echo "Prometheus not running yet, skipping validation"
fi
EOF
}

deploy_stack() {
  info "Deploying with Docker Compose"
  guest_ssh "$TARGET" "cd ${REMOTE_STACK} && sudo docker compose up -d --remove-orphans"
}

verify_deployment() {
  info "Verifying monitoring stack deployment"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/monitoring-stack

echo "Container status:"
sudo docker compose ps

echo ""
echo "Checking for running containers..."
RUNNING=$(sudo docker compose ps --services --filter "status=running" | wc -l)
if [[ $RUNNING -eq 0 ]]; then
  echo "No containers are running!"
  exit 1
fi

echo "Verifying Prometheus status..."
timeout 10 curl -f http://localhost:9090/-/healthy || {
  echo "Prometheus is not healthy"
  exit 1
}

echo "Verifying Grafana status..."
timeout 10 curl -f http://localhost:3000/login || {
  echo "Grafana is not responding"
  exit 1
}

echo "Monitoring stack responsive"
EOF
}

print_access_info() {
  info "Monitoring stack deployed:"
  info "  - Prometheus: http://${TARGET}:9090"
  info "  - Grafana: http://${TARGET}:3000"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

render_prometheus_config "$TMP_DIR"
setup_remote_directory
check_existing_containers || info "No existing containers, performing initial deployment"
transfer_stack "$TMP_DIR"
validate_prometheus_config
deploy_stack
verify_deployment
print_access_info

audit_log "Monitoring stack deployed to ${TARGET}"