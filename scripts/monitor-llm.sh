#!/usr/bin/env bash
# Описание: Скрипт для мониторинга статуса LLM VM и сервисов.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

PROXMOX_MODE=0
if command -v qm >/dev/null 2>&1 && [[ "${EUID:-1}" -eq 0 ]]; then
  PROXMOX_MODE=1
fi

LLM_VMID="${LLM_VMID:-110}"
MONITORING_VMID="${MONITORING_VMID:-120}"
LLM_IP="${LLM_IP:-10.10.10.50}"
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"

check_http() {
  local name="$1"
  local url="$2"
  if curl -fsS --max-time 5 "$url" >/dev/null; then
    info "${name}: OK (${url})"
  else
    warn "${name}: unavailable (${url})"
  fi
}

if ((PROXMOX_MODE)); then
  info "Proxmox VM status"
  qm status "$LLM_VMID" || true
  qm status "$MONITORING_VMID" || true
  qm guest exec "$LLM_VMID" -- bash -lc 'uptime; df -h / /mnt/llm-data 2>/dev/null || true; docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true' || true
  qm guest exec "$MONITORING_VMID" -- bash -lc 'uptime; df -h / /mnt/monitoring-data 2>/dev/null || true; docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true' || true
fi

check_http "Ollama API" "http://${LLM_IP}:11434/api/tags"
check_http "Open WebUI" "http://${LLM_IP}:3000"
check_http "Prometheus" "http://${MONITORING_IP}:9090/-/ready"
check_http "Grafana" "http://${MONITORING_IP}:3000/api/health"

info "Monitor check complete"

