#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Настраивает внутренний bridge и IP-forwarding на Proxmox-хосте.
#
#   ЧТО ДЕЛАЕТ ЭТОТ СКРИПТ:
#     1. Создаёт bridge vmbr1 (INTERNAL_BRIDGE) с адресом INTERNAL_CIDR
#     2. Включает net.ipv4.ip_forward
#
#   ЧТО НЕ ДЕЛАЕТ:
#     - nftables правила — только infra-setup-nft-rules.sh
#       (один авторитетный источник правил, нет конфликта таблиц)
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd ip

mark_step "Configuring internal bridge and IP forwarding"

# ---------------------------------------------------------------------------
setup_internal_bridge() {
  info "Setting up bridge ${INTERNAL_BRIDGE} with address ${INTERNAL_CIDR}"

  # Запись в /etc/network/interfaces.d/ — персистентна после reboot
  mkdir -p /etc/network/interfaces.d
  cat > /etc/network/interfaces.d/llm-lab.cfg <<EOF
auto ${INTERNAL_BRIDGE}
iface ${INTERNAL_BRIDGE} inet static
    address ${INTERNAL_CIDR}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

  # Применяем без перезагрузки
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a 2>/dev/null || true
  fi

  # Создаём bridge если не существует
  if ! ip link show "$INTERNAL_BRIDGE" >/dev/null 2>&1; then
    ip link add name "$INTERNAL_BRIDGE" type bridge
    info "Created bridge ${INTERNAL_BRIDGE}"
  fi

  ip link set "$INTERNAL_BRIDGE" up

  # Назначаем адрес если ещё не назначен
  if ! ip -4 addr show "$INTERNAL_BRIDGE" | grep -qF "${INTERNAL_CIDR}"; then
    ip addr add "$INTERNAL_CIDR" dev "$INTERNAL_BRIDGE" 2>/dev/null || true
    info "Assigned ${INTERNAL_CIDR} to ${INTERNAL_BRIDGE}"
  else
    info "Bridge ${INTERNAL_BRIDGE} already has ${INTERNAL_CIDR}"
  fi
}

# ---------------------------------------------------------------------------
enable_ip_forwarding() {
  info "Enabling IP forwarding"
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-llm-lab-forwarding.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null 2>&1
  info "IP forwarding enabled"
}

# ---------------------------------------------------------------------------
verify() {
  info "Verifying bridge and forwarding"

  if ! ip link show "$INTERNAL_BRIDGE" >/dev/null 2>&1; then
    die "Bridge ${INTERNAL_BRIDGE} missing after setup"
  fi

  if ip -4 addr show "$INTERNAL_BRIDGE" | grep -qF "$INTERNAL_CIDR"; then
    info "✓ ${INTERNAL_BRIDGE} has ${INTERNAL_CIDR}"
  else
    warn "✗ ${INTERNAL_BRIDGE} missing ${INTERNAL_CIDR}"
  fi

  local fwd
  fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  if [[ "$fwd" == "1" ]]; then
    info "✓ IP forwarding enabled"
  else
    warn "✗ IP forwarding not active"
  fi

  info "Next step: run infra-setup-nft-rules.sh to configure NAT and firewall"
}

# ---------------------------------------------------------------------------
setup_internal_bridge
enable_ip_forwarding
verify

audit_log "Network bridge ${INTERNAL_BRIDGE} configured"
