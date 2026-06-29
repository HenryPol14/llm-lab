#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Разворачивает monitoring стек (Prometheus + Grafana + Alertmanager + node-exporter + blackbox)
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${MONITORING_IP:-}}"
[[ -n "$TARGET" ]] || die "Target IP required. Usage: $0 <IP>"

REMOTE_STACK="/opt/monitoring-stack"

mark_step "Deploying monitoring stack to ${TARGET}"
wait_for_ssh "$TARGET" 240

# ---------------------------------------------------------------------------
render_prometheus_config() {
  local tmp="$1"
  info "Rendering Prometheus config"
  cp -R "${PROJECT_ROOT}/docker/monitoring/." "$tmp/"
  mkdir -p "$tmp/prometheus"
  sed \
    -e "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" \
    -e "s/{{MONITORING_IP}}/${MONITORING_IP:-10.10.10.60}/g" \
    "${PROJECT_ROOT}/monitoring/prometheus/prometheus.yml.tpl" \
    > "${tmp}/prometheus/prometheus.yml"

  grep -q "${LLM_IP}" "${tmp}/prometheus/prometheus.yml" \
    || die "LLM_IP not rendered into prometheus.yml"
  info "prometheus.yml validated"
}

# ---------------------------------------------------------------------------
setup_remote_directory() {
  guest_ssh "$TARGET" bash -s -- "$REMOTE_STACK" "${GUEST_USER:-ubuntu}" <<'EOF'
set -Eeuo pipefail
sudo mkdir -p "$1"
sudo chown "$2:$2" "$1"
EOF
}

# ---------------------------------------------------------------------------
transfer_stack() {
  local tmp="$1"
  info "Transferring monitoring stack to ${TARGET}:${REMOTE_STACK}"
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  # shellcheck disable=SC2086
  scp -r $opts "${tmp}/." "${GUEST_USER:-ubuntu}@${TARGET}:${REMOTE_STACK}/" \
    || die "scp failed"
}

# ---------------------------------------------------------------------------
prepare_data_dirs() {
  info "Preparing data directories on ${TARGET}"
  guest_ssh "$TARGET" 'sudo bash -s' <<'EOF'
set -Eeuo pipefail
mkdir -p /mnt/data/prometheus /mnt/data/grafana /mnt/data/alertmanager
chown -R 65534:65534 /mnt/data/prometheus /mnt/data/alertmanager  # nobody
chown -R 472:472     /mnt/data/grafana                            # grafana uid
echo "Data directories ready"
EOF
}

# ---------------------------------------------------------------------------
deploy_stack() {
  info "Deploying monitoring stack (idempotent)"

  # FIX: идемпотентная проверка вынесена в shell-переменную ПЕРЕД heredoc,
  # а не как 'exit 0' внутри remote bash (что завершало только remote bash,
  # но не останавливало скрипт-обёртку)
  local running
  running="$(guest_ssh "$TARGET" \
    "cd ${REMOTE_STACK} && sudo docker compose ps -q 2>/dev/null | wc -l" || echo 0)"

  if [[ "$running" -gt 0 ]]; then
    info "Monitoring stack already running (${running} containers) — pulling updates"
    guest_ssh "$TARGET" "cd ${REMOTE_STACK} && sudo docker compose pull --quiet || true"
    guest_ssh "$TARGET" "cd ${REMOTE_STACK} && sudo docker compose up -d --remove-orphans"
  else
    info "Starting monitoring stack for the first time"
    guest_ssh "$TARGET" "cd ${REMOTE_STACK} && sudo docker compose pull --quiet || true"
    guest_ssh "$TARGET" "cd ${REMOTE_STACK} && sudo docker compose up -d"
  fi
}

# ---------------------------------------------------------------------------
verify_deployment() {
  info "Verifying monitoring stack on ${TARGET}"
  guest_ssh "$TARGET" 'bash -s' <<'EOF'
set -Eeuo pipefail
cd /opt/monitoring-stack
echo "=== Container status ==="
sudo docker compose ps

RUNNING="$(sudo docker compose ps -q | wc -l)"
[[ "$RUNNING" -gt 0 ]] || { echo "ERROR: no running containers"; exit 1; }

echo "=== Health checks ==="

# Prometheus (быстро готов)
timeout 20 curl -fsS http://localhost:9090/-/healthy && echo "Prometheus OK" || echo "Prometheus: FAILED"

# Alertmanager (быстро готов)
timeout 20 curl -fsS http://localhost:9093/-/healthy && echo "Alertmanager OK" || echo "Alertmanager: FAILED"

# Grafana (может занять ~30 секунд на старт)
echo "Waiting for Grafana to be ready..."
timeout 60 bash -c 'until curl -fsS http://localhost:3000/api/health >/dev/null 2>&1; do sleep 2; done'
echo "Grafana OK"
EOF
}

# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

render_prometheus_config "$TMP_DIR"
setup_remote_directory
transfer_stack "$TMP_DIR"
prepare_data_dirs
deploy_stack
verify_deployment

info "Monitoring stack deployed:"
info "  Prometheus:   http://${TARGET}:9090"
info "  Grafana:      http://${TARGET}:3000"
info "  Alertmanager: http://${TARGET}:9093"
audit_log "Monitoring stack deployed to ${TARGET}"
