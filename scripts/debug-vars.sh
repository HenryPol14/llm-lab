#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_config

echo "LLM_IP: ${LLM_IP:-empty}"
echo "MONITORING_IP: ${MONITORING_IP:-empty}"
echo "NGINX_IP: ${NGINX_IP:-empty}"
echo "NGINX_WAN_IP: ${NGINX_WAN_IP:-empty}"
echo "INTERNAL_SUBNET: ${INTERNAL_SUBNET:-empty}"
echo "WAN_BRIDGE: ${WAN_BRIDGE:-empty}"
