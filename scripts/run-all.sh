#!/usr/bin/env bash
# Описание: Оркестратор запуска всех шагов по подготовке хоста и VM (последовательность скриптов).
# Комментарий добавлен автоматически — дополните при необходимости.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # директория скриптов

"${SCRIPT_DIR}/01-install-proxmox-tools.sh"
"${SCRIPT_DIR}/02-enable-iommu.sh"
"${SCRIPT_DIR}/03-configure-network.sh"
"${SCRIPT_DIR}/04-download-cloud-image.sh"
"${SCRIPT_DIR}/05-create-cloudinit-template.sh"
"${SCRIPT_DIR}/10-create-llm-vm.sh"
"${SCRIPT_DIR}/11-create-monitoring-vm.sh"
"${SCRIPT_DIR}/08-install-guest-runtime.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/09-install-nvidia-toolkit.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/08-install-guest-runtime.sh" "${MONITORING_IP:-}"
"${SCRIPT_DIR}/11-deploy-llm-stack.sh" "${LLM_IP:-}"
"${SCRIPT_DIR}/check-llm-vm-quick.sh" "${LLM_IP:-}" "${MONITORING_IP:-}"

