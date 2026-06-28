#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
TARGET="${1:-${MONITORING_IP:-${LLM_IP:-}}}"
if [[ -z "$TARGET" ]]; then
  die "Target IP required"
fi
REMOTE_STACK="/opt/monitoring-stack"
mark_step "Deploying monitoring stack to ${TARGET}"
wait_for_ssh "$TARGET" 240

prepare_data_dirs() {
  info "Preparing data directories on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
sudo mkdir -p /mnt/data/prometheus
sudo mkdir -p /mnt/data/grafana
sudo mkdir -p /mnt/data/alertmanager
# Prometheus и alertmanager работают от nobody (65534)
sudo chown -R 65534:65534 /mnt/data/prometheus
sudo chown -R 65534:65534 /mnt/data/alertmanager
# Grafana работает от uid 472
sudo chown -R 472:472 /mnt/data/grafana
echo "Data directories prepared"
EOF
}

render_prometheus_config() {
  local target_dir="$1"
  info "Rendering Prometheus configuration"
  cp -R "${PROJECT_ROOT}/docker/monitoring/." "$target_dir/"
  mkdir -p "$target_dir/prometheus"
  sed \
    -e "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" \
    -e "s/{{MONITORING_IP}}/${MONITORING_IP:-10.10.10.60}/g" \
    "${PROJECT_ROOT}/monitoring/prometheus/prometheus.yml.tpl" \
    > "${target_dir}/prometheus/prometheus.yml"
}

validate_prometheus_files() {
  local tmp_dir="$1"
  local config_file="${tmp_dir}/prometheus/prometheus.yml"
  info "Validating generated Prometheus configuration"
  [[ -f "$config_file" ]] || die "Prometheus config not found: $config_file"
  grep -q "${LLM_IP}" "$config_file" || die "LLM IP was not rendered into Prometheus config"
  grep -q "${MONITORING_IP}" "$config_file" || die "Monitoring IP was not rendered into Prometheus config"
  info "Prometheus configuration validated"
}

setup_remote_directory() {
  guest_ssh "$TARGET" \
    "sudo mkdir -p \"${REMOTE_STACK}\" && sudo chown \"${GUEST_USER}:${GUEST_USER}\" \"${REMOTE_STACK}\""
}

install_docker_compose() {
  info "Checking Docker Compose on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
if docker compose version >/dev/null 2>&1; then
  echo "Docker Compose already installed:"
  docker compose version
  exit 0
fi

echo "Installing Docker Compose v2"
sudo apt-get update -qq
sudo apt-get install -y docker-compose-v2
docker compose version
EOF
}

reboot_if_required() {
  info "Checking if reboot is required"
  local needs_reboot
  needs_reboot="$(guest_ssh "$TARGET" 'bash -s' <<'EOF'
if [[ -f /var/run/reboot-required ]]; then
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
  echo REBOOT_REQUIRED
fi
EOF
)"

  if grep -q "REBOOT_REQUIRED" <<<"$needs_reboot"; then
    info "Reboot required"
    guest_ssh "$TARGET" "sudo reboot" || true
    sleep 15
    wait_for_ssh "$TARGET" 180
    info "VM is back online"
  else
    info "No reboot required"
  fi
}

grant_docker_access() {
  guest_ssh "$TARGET" \
    "sudo usermod -aG docker \"${GUEST_USER}\""
}

transfer_stack() {
  local tmp_dir="$1"
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  info "Transferring monitoring stack"
  scp -r ${opts} \
    "${tmp_dir}/." \
    "${GUEST_USER}@${TARGET}:${REMOTE_STACK}/" || true
}

check_existing_containers() {
  local existing
  existing="$(guest_ssh "$TARGET" \
    "cd ${REMOTE_STACK} && sudo docker compose ps 2>/dev/null || true" || true)"
  if grep -Eq 'Up|running' <<<"$existing" || true; then
    info "Existing containers detected"
    return 0 || true
  fi
  return 1 || true
}

deploy_stack() {
  info "Deploying monitoring stack"
  guest_ssh "$TARGET" "
set -Eeuo pipefail || true
cd ${REMOTE_STACK}
if sudo docker compose ps -q 2>/dev/null | grep -q .; then
  info 'Monitoring stack already running. Skipping deployment.'
  exit 0 || true
fi
sudo docker compose pull || true
sudo docker compose up -d || true
"
}

validate_running_prometheus() {
  info "Validating Prometheus runtime configuration"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/monitoring-stack
  if sudo docker compose ps | grep -q prometheus || true; then
  sudo docker compose exec -T prometheus \
    promtool check config /etc/prometheus/prometheus.yml
fi
EOF
}

verify_deployment() {
  info "Verifying deployment"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/monitoring-stack
echo "Container status:"
sudo docker compose ps
RUNNING="$(sudo docker compose ps | grep -Ec 'Up|running' || true)"
if [[ "$RUNNING" -eq 0 ]]; then
  echo "No running containers found"
  exit 1
fi

echo
echo "Checking Prometheus"
timeout 15 curl -fsS http://localhost:9090/-/healthy
echo
echo "Checking Grafana"
timeout 15 curl -fsS http://localhost:3000/login >/dev/null
echo
echo "Monitoring stack is healthy"
EOF
}

print_access_info() {
  info "Monitoring stack deployed successfully"
  info "Prometheus: http://${TARGET}:9090"
  info "Grafana: http://${TARGET}:3000"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
render_prometheus_config "$TMP_DIR"
validate_prometheus_files "$TMP_DIR"
setup_remote_directory
install_docker_compose
reboot_if_required
grant_docker_access
check_existing_containers || info "No existing containers found"
transfer_stack "$TMP_DIR"
prepare_data_dirs 
deploy_stack
validate_running_prometheus
verify_deployment
print_access_info
audit_log "Monitoring stack deployed to ${TARGET}"