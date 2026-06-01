#!/usr/bin/env bash
# Описание: Настраивает сетевые мосты и правила фаервола на хосте.
# Комментарий добавлен автоматически — дополните при необходимости.
NFTABLES_DIR="${NFTABLES_DIR:-/etc/nftables.d}"
NFTABLES_CONF="${NFTABLES_CONF:-/etc/nftables.conf}"

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции
load_config                                           # загружаем конфигурацию проекта
require_root                                          # проверяем права root

mark_step "Configuring network and firewall with whitelist rules"  # фиксируем шаг в журнале

require_cmd ip
require_cmd nft

setup_internal_bridge() {
  info "Setting up internal bridge ${INTERNAL_BRIDGE}"
  mkdir -p /etc/network/interfaces.d                             # создаем каталог для дополнительных сетевых конфигураций
  cat >/etc/network/interfaces.d/llm-lab.cfg <<EOF
auto ${INTERNAL_BRIDGE}
iface ${INTERNAL_BRIDGE} inet static
    address ${INTERNAL_CIDR}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a || true
  fi

  if ! ip link show "$INTERNAL_BRIDGE" >/dev/null 2>&1; then
    info "Creating bridge ${INTERNAL_BRIDGE}"
    ip link add name "$INTERNAL_BRIDGE" type bridge
  fi

  ip link set "$INTERNAL_BRIDGE" up
  if ! ip -4 addr show "$INTERNAL_BRIDGE" | grep -q "$INTERNAL_CIDR"; then
    ip addr add "$INTERNAL_CIDR" dev "$INTERNAL_BRIDGE" 2>/dev/null || true
  fi
}

enable_ip_forwarding() {
  info "Enabling IP forwarding"
  mkdir -p /etc/sysctl.d                                       # создаем директорию для системных параметров
  cat >/etc/sysctl.d/99-llm-lab-forwarding.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null                                   # применяем изменения сразу
}

create_firewall_whitelist() {
  if [[ "${FIREWALL_ENABLED:-true}" != "true" ]]; then
    warn "Firewall disabled by config, skipping"
    return 0
  fi

  info "Creating firewall whitelist rules"
  mkdir -p "$NFTABLES_DIR"

  nftables_whitelist_config >"$NFTABLES_DIR/llm-lab.nft"

  if ! grep -q "include \"$NFTABLES_DIR/*.nft\"" "$NFTABLES_CONF"; then
    printf '\ninclude "%s/*.nft"\n' "$NFTABLES_DIR" >> "$NFTABLES_CONF"
  fi
}

apply_firewall() {
  info "Applying firewall rules"
  systemctl enable --now nftables
  nft -f "$NFTABLES_CONF"

  info "Current nftables rules:"
  nft list ruleset
}

verify_connectivity() {
  info "Verifying connectivity to internal bridge"

  if ! ip addr show "$INTERNAL_BRIDGE" >/dev/null 2>&1; then
    warn "Bridge ${INTERNAL_BRIDGE} not configured"
    return 1
  fi

  if ip -4 addr show "$INTERNAL_BRIDGE" | grep -q "$INTERNAL_CIDR"; then
    info "Bridge ${INTERNAL_BRIDGE} has correct address ${INTERNAL_CIDR}"
  else
    warn "Bridge ${INTERNAL_BRIDGE} missing address ${INTERNAL_CIDR}"
    return 1
  fi

  if iptables -t nat -L POSTROUTING -n | grep -q MASQUERADE; then
    info "NAT rules are active"
  else
    warn "NAT rules not found"
  fi
}

setup_internal_bridge
enable_ip_forwarding
create_firewall_whitelist
apply_firewall
verify_connectivity

audit_log "Network and firewall configured"
