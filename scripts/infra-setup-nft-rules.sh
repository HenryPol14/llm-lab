#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: единственный авторитетный источник правил nftables для llm-lab.
#
#   Таблицы:
#     ip   llm_lab_nat    — DNAT (WAN→nginx) + masquerade (internal→WAN)
#     inet llm_lab_filter — forward whitelist
#
#   Идемпотентность:
#     flush_lab_tables → apply_ruleset → persist_ruleset
#     При каждом запуске: старые таблицы удаляются, применяются новые.
#     Наслоения правил нет.
#
#   Персистентность после reboot:
#     Правила пишутся в /etc/nftables.d/llm-lab.nft (drop-in директория).
#     systemd nftables.service загружает /etc/nftables.conf, который на Proxmox
#     содержит 'include "/etc/nftables.d/*.nft"' по умолчанию — наш файл
#     подхватывается автоматически без правки основного конфига.
#     Если drop-in не поддерживается — добавляем include сами, один раз.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd nft

# NGINX_IP экспортируется из load_config как ${NGINX_WAN_IP%/*}.
# Страховка на случай прямого вызова без load_config.
NGINX_IP="${NGINX_IP:-${NGINX_WAN_IP:-}}"
NGINX_IP="${NGINX_IP%/*}"
NGINX_IP="${NGINX_IP:-10.10.10.70}"

[[ -n "$LLM_IP" ]]           || die "LLM_IP is not set"
[[ -n "$MONITORING_IP" ]]    || die "MONITORING_IP is not set"
[[ -n "$NGINX_IP" ]]         || die "NGINX_IP is not set"
[[ -n "$INTERNAL_SUBNET" ]]  || die "INTERNAL_SUBNET is not set"
[[ -n "$INTERNAL_GATEWAY" ]] || die "INTERNAL_GATEWAY is not set"
[[ -n "$WAN_BRIDGE" ]]       || die "WAN_BRIDGE is not set"

NFT_DROPIN_DIR="/etc/nftables.d"
NFT_DROPIN_FILE="${NFT_DROPIN_DIR}/llm-lab.nft"
NFT_MAIN_CONF="/etc/nftables.conf"

mark_step "Configuring nftables for llm-lab"
info "  LLM=${LLM_IP}  MON=${MONITORING_IP}  NGX=${NGINX_IP}"
info "  SUBNET=${INTERNAL_SUBNET}  GW=${INTERNAL_GATEWAY}  WAN=${WAN_BRIDGE}"

# ---------------------------------------------------------------------------
backup_ruleset() {
  local backup="/etc/nftables-backup-$(date +%Y%m%d%H%M%S).conf"
  nft list ruleset > "$backup" 2>/dev/null || true
  info "Ruleset backed up to ${backup}"
}

# ---------------------------------------------------------------------------
# Флашим ВСЕ таблицы которые когда-либо создавал проект.
# Это главная гарантия отсутствия наслоений при повторных запусках.
flush_lab_tables() {
  info "Flushing existing lab tables"
  local t
  for t in \
    "ip   llm_lab_nat"    \
    "inet llm_lab_filter" \
    "inet llm_lab"        \
    "inet pve_lab"        \
    "ip   nat"
  do
    # shellcheck disable=SC2086
    if nft delete table $t 2>/dev/null; then
      info "  Deleted: $t"
    fi
  done
}

# ---------------------------------------------------------------------------
apply_ruleset() {
  info "Applying nftables ruleset"

  # Shell раскрывает переменные до передачи в nft.
  # Повторный вызов безопасен только после flush_lab_tables().
  nft -f - <<EOF
# llm-lab nftables ruleset
# Управляется infra-setup-nft-rules.sh — не редактируй вручную.

table ip llm_lab_nat {

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    # DNAT: WAN 80/443 → nginx proxy. nginx — единая точка входа с TLS и
    # path-based роутингом (/, /ollama/, /prometheus/, /grafana/,
    # /alertmanager/), поэтому отдельный DNAT на сервисные порты не нужен.
    iifname "${WAN_BRIDGE}" tcp dport { 80, 443 } \
      dnat to ${NGINX_IP}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    # Masquerade: VM → WAN (даёт VM доступ в интернет).
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" masquerade
  }
}

table inet llm_lab_filter {

  chain forward {
    type filter hook forward priority filter; policy drop;

    # 1. Established/related — не трогаем уже открытые соединения.
    ct state established,related accept

    # 2. Internal → WAN (после masquerade).
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" accept

    # 3. WAN → nginx (после DNAT).
    ip daddr ${NGINX_IP} tcp dport { 80, 443 } accept

    # 4. nginx → LLM VM.
    ip saddr ${NGINX_IP} ip daddr ${LLM_IP} tcp dport { 3000, 11434 } accept

    # 5. nginx → Monitoring VM.
    ip saddr ${NGINX_IP} ip daddr ${MONITORING_IP} \
      tcp dport { 3000, 9090, 9093, 9100 } accept

    # 6. Prometheus → exporters на LLM VM.
    ip saddr ${MONITORING_IP} ip daddr ${LLM_IP} tcp dport { 9100, 9400 } accept

    # 7. Monitoring VM внутри себя (inter-container).
    ip saddr ${MONITORING_IP} ip daddr ${MONITORING_IP} accept

    # 8. Запрет VM↔VM, кроме явно разрешённого выше.
    ip saddr ${INTERNAL_SUBNET} ip daddr ${INTERNAL_SUBNET} drop
  }

  chain input  { type filter hook input  priority filter; policy accept; }
  chain output { type filter hook output priority filter; policy accept; }
}
EOF

  info "Ruleset applied"
}

# ---------------------------------------------------------------------------
persist_ruleset() {
  info "Persisting ruleset to ${NFT_DROPIN_FILE}"

  # Всегда ПЕРЕЗАПИСЫВАЕМ (>), не дописываем — идемпотентно.
  mkdir -p "$NFT_DROPIN_DIR"
  {
    nft list table ip   llm_lab_nat
    nft list table inet llm_lab_filter
  } > "$NFT_DROPIN_FILE"
  info "Written: ${NFT_DROPIN_FILE}"

  # Proxmox/Debian имеют в /etc/nftables.conf строку:
  #   include "/etc/nftables.d/*.nft"
  # Если она есть — drop-in подхватится автоматически, ничего не трогаем.
  # Если нет (старый Proxmox) — добавляем explicit include, один раз.
  if grep -qE 'include.*nftables\.d/\*' "$NFT_MAIN_CONF" 2>/dev/null; then
    info "Drop-in glob already in ${NFT_MAIN_CONF} — nothing to add"
  elif ! grep -qF "$NFT_DROPIN_FILE" "$NFT_MAIN_CONF" 2>/dev/null; then
    printf '\ninclude "%s"\n' "$NFT_DROPIN_FILE" >> "$NFT_MAIN_CONF"
    info "Added include to ${NFT_MAIN_CONF}"
  else
    info "Explicit include already in ${NFT_MAIN_CONF}"
  fi

  systemctl enable nftables 2>/dev/null || true
  info "Rules will persist after reboot"
}

# ---------------------------------------------------------------------------
verify_ruleset() {
  info "Current ruleset:"
  nft list table ip   llm_lab_nat
  nft list table inet llm_lab_filter
}

print_summary() {
  local pub="${PROXMOX_HOST:-<proxmox-ip>}"
  info "DNAT: ${pub}:{80,443} → ${NGINX_IP} (nginx-proxy, TLS, path-based routing)"
  info "  :80  HTTP redirect (→ HTTPS)"
  info "  :443 HTTPS unified entry:"
  info "    https://${pub}/               → Open WebUI"
  info "    https://${pub}/ollama/        → Ollama API"
  info "    https://${pub}/prometheus/    → Prometheus"
  info "    https://${pub}/grafana/       → Grafana"
  info "    https://${pub}/alertmanager/  → Alertmanager"
}

# ---------------------------------------------------------------------------
# Порядок при каждом запуске:
#   backup → flush → apply → persist → verify
#
#   flush гарантирует: нет наслоений, нет дублей цепочек.
#   persist(>) гарантирует: файл всегда актуален, нет накопления строк.
#   include в nftables.conf добавляется только один раз (idempotent grep).
# ---------------------------------------------------------------------------
backup_ruleset
flush_lab_tables
apply_ruleset
persist_ruleset
verify_ruleset
print_summary

audit_log "nftables applied: LLM=${LLM_IP} MON=${MONITORING_IP} NGX=${NGINX_IP}"
