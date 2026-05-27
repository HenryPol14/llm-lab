#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"
INTERNAL_BRIDGE="${INTERNAL_BRIDGE:-vmbr1}"
INTERNAL_CIDR="${INTERNAL_CIDR:-10.10.10.1/24}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.10.10.0/24}"

require_cmd ip
require_cmd nft

mkdir -p /etc/network/interfaces.d
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
  info "Creating internal bridge ${INTERNAL_BRIDGE}"
  ip link add name "$INTERNAL_BRIDGE" type bridge
fi

ip link set "$INTERNAL_BRIDGE" up
if ! ip -4 addr show "$INTERNAL_BRIDGE" | grep -q "$INTERNAL_CIDR"; then
  ip addr add "$INTERNAL_CIDR" dev "$INTERNAL_BRIDGE" 2>/dev/null || true
fi

cat >/etc/sysctl.d/99-llm-lab-forwarding.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

mkdir -p /etc/nftables.d
cat >/etc/nftables.d/llm-lab.nft <<EOF
table inet llm_lab {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" masquerade
  }
}
EOF

if ! grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf; then
  printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
fi

systemctl enable --now nftables
nft -f /etc/nftables.conf

info "Internal bridge ${INTERNAL_BRIDGE} and NAT are configured"
