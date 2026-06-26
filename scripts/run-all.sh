#!/usr/bin/env bash
# Описание: Оркестратор запуска всех шагов по подготовке хоста и VM (последовательность скриптов).
# Комментарий добавлен автоматически — дополните при необходимости.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap
"${SCRIPT_DIR}/00-bootstrap-remote.sh"

# Infrastructure
"${SCRIPT_DIR}/infra-install-proxmox-tools.sh"
"${SCRIPT_DIR}/infra-enable-iommu.sh"
"${SCRIPT_DIR}/infra-configure-network.sh"

# VM creation
"${SCRIPT_DIR}/vm-download-cloud-image.sh"
"${SCRIPT_DIR}/vm-create-cloudinit-template.sh"
"${SCRIPT_DIR}/vm-create-llm-vm.sh"
"${SCRIPT_DIR}/vm-create-monitoring-vm.sh"

# Deployment LLM
"${SCRIPT_DIR}/deployment-install-guest-runtime-llm.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/deployment-install-nvidia-toolkit-llm.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/deployment-deploy-llm-stack.sh" "${LLM_IP:-}"

# Verification
"${SCRIPT_DIR}/deployment-check-llm-vm-quick.sh" "${LLM_IP:-}" "${MONITORING_IP:-}"

# Deployment Monitoring
"${SCRIPT_DIR}/deployment-install-guest-runtime-monitoring.sh" "${MONITORING_IP:-}"
"${SCRIPT_DIR}/deployment-deploy-monitoring-stack.sh" "${MONITORING_IP:-}"

# Proxy
"${SCRIPT_DIR}/proxy-deploy-nginx-proxy.sh"
"${SCRIPT_DIR}/infra-setup-nft-rules.sh"
