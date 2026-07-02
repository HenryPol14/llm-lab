#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_config

# Set defaults if not loaded
LLM_IP="${LLM_IP:-10.10.10.50}"
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
NGINX_IP="${NGINX_IP:-10.10.10.70}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.10.10.0/24}"
WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"

cat << EOF
table ip test_nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "${WAN_BRIDGE}" tcp dport 3000 dnat to "${NGINX_IP}:3000"
  }
}
EOF
