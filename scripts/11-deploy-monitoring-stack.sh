#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${MONITORING_IP:-10.10.10.60}}"
REMOTE_STACK=/opt/monitoring-stack

info "Rendering Prometheus config for LLM target ${LLM_IP:-10.10.10.50}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp -R "${PROJECT_ROOT}/docker/monitoring/." "$TMP_DIR/"
mkdir -p "$TMP_DIR/prometheus"
sed \
  -e "s/{{LLM_IP}}/${LLM_IP:-10.10.10.50}/g" \
  -e "s/{{MONITORING_IP}}/${MONITORING_IP:-10.10.10.60}/g" \
  "${PROJECT_ROOT}/monitoring/prometheus/prometheus.yml.tpl" > "$TMP_DIR/prometheus/prometheus.yml"

info "Deploying monitoring stack to ${TARGET}"
wait_for_ssh "$TARGET" 240
guest_ssh "$TARGET" "sudo mkdir -p ${REMOTE_STACK} && sudo chown ${GUEST_USER:-ubuntu}:${GUEST_USER:-ubuntu} ${REMOTE_STACK}"
scp ${SSH_OPTS:-} -r "$TMP_DIR/." "${GUEST_USER:-ubuntu}@${TARGET}:${REMOTE_STACK}/"
guest_ssh "$TARGET" "sudo mkdir -p /mnt/monitoring-data/prometheus /mnt/monitoring-data/grafana && cd ${REMOTE_STACK} && sudo docker compose up -d"
info "Monitoring stack deployed at http://${TARGET}:3000 and http://${TARGET}:9090"
