#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

mark_step "Configuring network and firewall with whitelist rules"

require_cmd ip
require_cmd nft

setup_internal_bridge() {
  info "Setting up internal bridge ${INTERNAL_BRIDGE}"
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
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-llm-lab-forwarding.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

create_firewall_whitelist() {
  if [[ "${FIREWALL_ENABLED:-true}" != "true" ]]; then
    warn "Firewall disabled by config, skipping"
    return 0
  fi

  info "Creating firewall whitelist rules"
  mkdir -p /etc/nftables.d

  cat >/etc/nftables.d/llm-lab.nft <<EOF
table inet llm_lab {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    
    # Allow only specific services to internet
    ip saddr ${LLM_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${LLM_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade
    
    ip saddr ${MONITORING_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${MONITORING_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade
    
    # Deny all other outbound
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    
    # LLM VM services - inbound
    ip daddr ${LLM_IP} tcp dport { 3000, 11434 } accept
    
    # Monitoring VM services - inbound
    ip daddr ${MONITORING_IP} tcp dport { 3000, 9090 } accept
    
    # Allow established connections
    ct state established,related accept
    
    # Drop inter-VM communication
    ip saddr ${INTERNAL_SUBNET} ip daddr ${INTERNAL_SUBNET} drop
  }

  chain input {
    type filter hook input priority 0; policy accept;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF

  if ! grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
  fi
}

apply_firewall() {
  info "Applying firewall rules"
  systemctl enable --now nftables
  nft -f /etc/nftables.conf

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
