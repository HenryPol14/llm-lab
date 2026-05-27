#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"
INTERNAL_BRIDGE="${INTERNAL_BRIDGE:-vmbr1}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.10.10.0/24}"

info "System"
hostnamectl || true
pveversion || true

info "Interfaces"
ip -br addr
bridge link || true

info "Routing"
ip route
ip route | grep -q '^default' && info "Default route present" || warn "Default route missing"

info "Forwarding"
sysctl net.ipv4.ip_forward

info "NAT"
nft list ruleset || true
if nft list ruleset 2>/dev/null | grep -q "masquerade"; then
  info "NAT masquerade is present"
else
  warn "NAT masquerade is missing"
fi

info "Connectivity"
ping -c 2 1.1.1.1 >/dev/null 2>&1 && info "Internet ping OK" || warn "Internet ping failed"
ping -c 2 github.com >/dev/null 2>&1 && info "DNS OK" || warn "DNS failed"

info "VM network configs"
if command -v qm >/dev/null 2>&1; then
  qm list || true
  for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    echo "VMID ${vmid}"
    qm config "$vmid" | grep -E '^(name|net0|ipconfig0|agent):' || true
  done
fi

info "Expected WAN bridge: ${WAN_BRIDGE}"
info "Expected internal bridge: ${INTERNAL_BRIDGE}"
info "Expected internal subnet: ${INTERNAL_SUBNET}"

