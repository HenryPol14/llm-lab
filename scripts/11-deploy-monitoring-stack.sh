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

render_prometheus_config() {
  local target_dir="$1"

  info "Rendering Prometheus config for LLM target ${LLM_IP:-10.10.10.50} and Monitoring target ${MONITORING_IP:-10.10.10.60}"

  cp -R "${PROJECT_ROOT}/docker/monitoring/." "$target_dir/"

  mkdir -p "$target_dir/prometheus"

  sed \
    -e "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" \
    -e "s/{{MONITORING_IP}}/${MONITORING_IP:-10.10.10.60}/g" \
    "${PROJECT_ROOT}/monitoring/prometheus/prometheus.yml.tpl" \
    > "$target_dir/prometheus/prometheus.yml"
}

setup_remote_directory() {
  guest_ssh "$TARGET" \
    "sudo mkdir -p ${REMOTE_STACK} && sudo chown ${GUEST_USER}:${GUEST_USER} ${REMOTE_STACK}"
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

echo "Installing Docker Compose v2..."

sudo apt-get update -qq
sudo apt-get install -y docker-compose-v2

echo "Docker Compose installed:"
docker compose version
EOF
}

reboot_if_required() {
  info "Checking if reboot is required on ${TARGET}"

  local needs_reboot

  needs_reboot="$(
    guest_ssh "$TARGET" 'bash -s' <<'EOF'
if [[ -f /var/run/reboot-required ]]; then
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
  echo REBOOT_REQUIRED
fi
EOF
  )"

  if grep -q "REBOOT_REQUIRED" <<<"$needs_reboot"; then
    info "Reboot required, rebooting ${TARGET}"

    guest_ssh "$TARGET" "sudo reboot" || true

    sleep 15
    wait_for_ssh "$TARGET" 180

    info "VM ${TARGET} is back online"
  else
    info "No reboot required"
  fi
}

transfer_stack() {
  local tmp_dir="$1"

  info "Transferring docker compose stack"

  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"

  scp -r ${opts} \
    "${tmp_dir}/." \
    "${GUEST_USER:-ubuntu}@${TARGET}:${REMOTE_STACK}/"
}

check_existing_containers() {
  local existing

  existing="$(
    guest_ssh "$TARGET" \
      "cd ${REMOTE_STACK} && docker compose ps 2>/dev/null || true"
  )"

  if grep -Eq 'Up|running' <<<"$existing"; then
    info "Existing containers found, will be updated"
    return 0
  fi

  return 1
}

validate_prometheus_files() {
  info "Validating generated Prometheus configuration"

  local config_file="$1/prometheus/prometheus.yml"

  [[ -f "$config_file" ]] || die "Prometheus config not found: $config_file"

  grep -q "${LLM_IP}" "$config_file" \
    || die "LLM IP not rendered into Prometheus config"

  grep -q "${MONITORING_IP}" "$config_file" \
    || die "Monitoring IP not rendered into Prometheus config"

  info "Prometheus configuration looks valid"
}

deploy_stack() {
  info "Deploying monitoring stack"

  guest_ssh "$TARGET" "
    set -Eeuo pipefail
    cd ${REMOTE_STACK}
    docker compose pull || true
    docker compose up -d --remove-orphans
  "
}

validate_running_prometheus() {
  info "Validating Prometheus container"

  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail

cd /opt/monitoring-stack

if docker compose ps | grep -q prometheus; then
  docker compose exec -T prometheus \
    promtool check config /etc/prometheus/prometheus.yml
fi
EOF
}

verify_deployment() {
  info "Verifying monitoring stack deployment"

  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail

cd /opt/monitoring-stack

echo "Container status:"
docker compose ps

RUNNING="$(docker compose ps | grep -Ec 'Up|running' || true)"

if [[ "$RUNNING" -eq 0 ]]; then
  echo "No containers are running"
  exit 1
fi

echo
echo "Checking Prometheus..."

timeout 15 curl -fsS \
  http://localhost:9090/-/healthy

echo
echo "Checking Grafana..."

timeout 15 curl -fsS \
  http://localhost:3000/login >/dev/null

echo
echo "Monitoring stack responsive"
EOF
}

grant_docker_access() {
  guest_ssh "$TARGET" \
    "sudo usermod -aG docker ${GUEST_USER}"
}

print_access_info() {
  info "Monitoring stack deployed successfully"
  info "Prometheus: http://${TARGET}:9090"
  info "Grafana:    http://${TARGET}:3000"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

render_prometheus_config "$TMP_DIR"
validate_prometheus_files "$TMP_DIR"
setup_remote_directory
install_docker_compose
reboot_if_required

check_existing_containers \
  || info "No existing containers, performing initial deployment"

transfer_stack "$TMP_DIR"
deploy_stack
validate_running_prometheus
verify_deployment
grant_docker_access
print_access_info
audit_log "Monitoring stack deployed to ${TARGET}"