#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Настраивает nftables — NAT, DNAT, forward для llm-lab.
# Заменяет дублированные и конкурирующие таблицы единым чистым ruleset.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd nft

LLM_IP="${LLM_IP:-10.10.10.50}"
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
NGINX_IP="${NGINX_IP:-10.10.10.70}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.10.10.0/24}"
WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"

mark_step "Configuring nftables for llm-lab"

backup_ruleset() {
  local backup
  backup="/etc/nftables-backup-$(date +%Y%m%d%H%M%S).conf"
  nft list ruleset > "$backup"
  info "Current ruleset backed up to ${backup}"
}

flush_lab_tables() {
  info "Removing old lab tables"
  for table in "inet llm_lab" "inet pve_lab" "ip nat"; do
    nft delete table "$table" 2>/dev/null && info "Deleted table: $table" || true
  done
}

apply_ruleset() {
  info "Applying new nftables ruleset"
  nft -f - << EOF
# llm-lab nftables ruleset
# NAT: masquerade для внутренней подсети + DNAT для nginx proxy

table ip llm_lab_nat {

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;

    # DNAT: публичный IP → nginx proxy (10.10.10.70)
    iifname "${WAN_BRIDGE}" tcp dport 3000  dnat to "${NGINX_IP}:3000"
    iifname "${WAN_BRIDGE}" tcp dport 8080  dnat to "${NGINX_IP}:8080"
    iifname "${WAN_BRIDGE}" tcp dport 9090  dnat to "${NGINX_IP}:9090"
    iifname "${WAN_BRIDGE}" tcp dport 9093  dnat to "${NGINX_IP}:9093"
    iifname "${WAN_BRIDGE}" tcp dport 11434 dnat to "${NGINX_IP}:11434"
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    # Masquerade для всей внутренней подсети
    ip saddr "${INTERNAL_SUBNET}" oifname "${WAN_BRIDGE}" masquerade
  }
}

table inet llm_lab_filter {

  chain forward {
    type filter hook forward priority filter; policy drop;

    # Разрешаем установленные соединения
    ct state established,related accept

    # Внутренняя подсеть → интернет (через masquerade)
    ip saddr "${INTERNAL_SUBNET}" oifname "${WAN_BRIDGE}" accept

    # nginx proxy → LLM VM
    ip saddr "${NGINX_IP}" ip daddr "${LLM_IP}" tcp dport { 3000, 11434 } accept

    # nginx proxy → Monitoring VM
    ip saddr "${NGINX_IP}" ip daddr "${MONITORING_IP}" tcp dport { 3000, 9090, 9093, 9100 } accept

    # DNAT forwarding: входящий трафик к nginx
    ip daddr "${NGINX_IP}" tcp dport { 3000, 8080, 9090, 9093, 11434 } accept

    # Prometheus scraping: monitoring → llm node-exporter, gpu-exporter
    # + blackbox-exporter probes Ollama (11434) и OpenWebUI (3000)
    ip saddr "${MONITORING_IP}" ip daddr "${LLM_IP}" tcp dport { 3000, 9100, 9400, 11434 } accept

    # Запрет трафика между VM (кроме разрешённого выше)
    ip saddr "${INTERNAL_SUBNET}" ip daddr "${INTERNAL_SUBNET}" drop
  }

  chain input {
    type filter hook input priority filter; policy accept;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
  info "nftables ruleset applied"
}

persist_ruleset() {
  info "Persisting ruleset to /etc/nftables.conf"

  # Сохраняем текущий ruleset (proxmox-firewall + наш)
  # Пишем отдельный файл для llm-lab и включаем его из основного
  nft list table ip llm_lab_nat > /etc/nftables-llm-lab.conf
  nft list table inet llm_lab_filter >> /etc/nftables-llm-lab.conf

  # Добавляем include в /etc/nftables.conf если его ещё нет
  if ! grep -q "nftables-llm-lab" /etc/nftables.conf 2>/dev/null; then
    echo 'include "/etc/nftables-llm-lab.conf"' >> /etc/nftables.conf
    info "Added include to /etc/nftables.conf"
  fi

  # Включаем и перезапускаем сервис
  systemctl enable nftables
  info "nftables rules will persist across reboots"
}

verify_ruleset() {
  info "Verifying ruleset"
  nft list table ip llm_lab_nat
  nft list table inet llm_lab_filter
}

print_summary() {
  local pub_ip="${PROXMOX_HOST:-77.50.132.85}"
  info "nftables configured:"
  info "  DNAT ${pub_ip}:3000  → ${NGINX_IP}:3000  (Grafana)"
  info "  DNAT ${pub_ip}:8080  → ${NGINX_IP}:8080  (Open WebUI)"
  info "  DNAT ${pub_ip}:9090  → ${NGINX_IP}:9090  (Prometheus)"
  info "  DNAT ${pub_ip}:9093  → ${NGINX_IP}:9093  (Alertmanager)"
  info "  DNAT ${pub_ip}:11434 → ${NGINX_IP}:11434 (Ollama API)"
}

backup_ruleset
flush_lab_tables
apply_ruleset
persist_ruleset
verify_ruleset
print_summary

audit_log "nftables llm-lab rules applied"
