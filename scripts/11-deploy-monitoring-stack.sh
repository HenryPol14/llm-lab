#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${MONITORING_IP:-${LLM_IP:-}}}"
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

install_docker_compose() {
  info "Checking Docker Compose on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail

if docker compose version >/dev/null 2>&1; then
  echo "Docker Compose already installed: $(docker compose version)"
  exit 0
fi

echo "Installing Docker Compose v2..."
sudo apt-get update -qq
sudo apt-get install -y docker-compose-v2
echo "Docker Compose installed: $(docker compose version)"
EOF
}

reboot_if_required() {
  info "Checking if reboot is required on ${TARGET}"
  local needs_reboot
  needs_reboot="$(guest_ssh "$TARGET" 'bash -s' <<'EOF'
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
  echo "REBOOT_REQUIRED"
fi
EOF
)"
  if echo "$needs_reboot" | grep -q "REBOOT_REQUIRED"; then
    info "Reboot required, rebooting ${TARGET}..."
    guest_ssh "$TARGET" "sudo reboot" || true
    sleep 15
    wait_for_ssh "$TARGET" 120
    info "VM ${TARGET} is back online"
  else
    info "No reboot required"
  fi
}

transfer_stack() {
  info "Transferring docker compose stack"
  local tmp_dir="$1"
  SCP_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  scp ${SCP_OPTS}%$3 oiump_dir/." "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/"
}

check_existing_containers() {
  local existing
  existing="$(guest_ssh "$TARGET" "cd ${REMOTE_STACK} && docker compose ps 2>/dev/null")"
  if echo "$existing" | grep -q "Up\|running"; then
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
if docker compose ps 2>/dev/null | grep -q prometheus; then
  echo "Testing Prometheus config..."
  docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml || {
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
  guest_ssh "$TARGET" "cd ${REMOTE_STACK} && docker compose up -d --remove-orphans"
}

verify_deployment() {
  info "Verifying monitoring stack deployment"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/monitoring-stack

echo "Container status:"
docker compose ps

echo ""
echo "Checking for running containers..."
RUNNING=$(docker compose ps 2>/dev/null | grep -c " running\|Up " || true)
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

grant_docker_access() {
  guest_ssh "$TARGET" "sudo usermod -aG docker ${GUEST_USER}"
}


TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

render_prometheus_config "$TMP_DIR"
setup_remote_directory
install_docker_compose
reboot_if_required
check_existing_containers || info "No existing containers, performing initial deployment"
transfer_stack "$TMP_DIR"
validate_prometheus_config
deploy_stack
verify_deployment
print_access_info
grant_docker_access
audit_log "Monitoring stack deployed to ${TARGET}"