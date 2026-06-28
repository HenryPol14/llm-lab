#!/usr/bin/env bash
# Описание: Оркестратор — запускается ТОЛЬКО на Proxmox хосте.
# Для первоначальной загрузки проекта на хост используй 00-bootstrap-remote.sh
# с локальной машины (он сам вызовет этот скрипт после upload).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# FIX: убран вызов 00-bootstrap-remote.sh — он вызывается с локальной машины
# и сам запускает run-all.sh на хосте, что создавало рекурсию.

# Infrastructure
"${SCRIPT_DIR}/infra-install-proxmox-tools.sh"
"${SCRIPT_DIR}/infra-enable-iommu.sh"
"${SCRIPT_DIR}/infra-configure-network.sh"

# VM creation
"${SCRIPT_DIR}/vm-download-cloud-image.sh"
"${SCRIPT_DIR}/vm-create-cloudinit-template.sh"
"${SCRIPT_DIR}/vm-create-llm-vm.sh"
"${SCRIPT_DIR}/vm-create-monitoring-vm.sh"

# FIX: используем единый скрипт вместо двух дублирующих
# Deployment LLM
"${SCRIPT_DIR}/deployment-install-guest-runtime.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/deployment-install-nvidia-toolkit-llm.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/deployment-deploy-llm-stack.sh" "${LLM_IP:-}"

# Verification
"${SCRIPT_DIR}/deployment-check-llm-vm-quick.sh" "${LLM_IP:-}" "${MONITORING_IP:-}"

# Deployment Monitoring
"${SCRIPT_DIR}/deployment-install-guest-runtime.sh" "${MONITORING_IP:-}"
"${SCRIPT_DIR}/deployment-deploy-monitoring-stack.sh" "${MONITORING_IP:-}"

# Proxy + firewall
"${SCRIPT_DIR}/proxy-deploy-nginx-proxy.sh"
"${SCRIPT_DIR}/infra-setup-nft-rules.sh"
