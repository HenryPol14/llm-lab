#!/usr/bin/env bash
# Описание: Оркестратор — запускается ТОЛЬКО на Proxmox хосте.
#   Для первоначальной загрузки используй 00-bootstrap-remote.sh с локальной машины.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_config
require_root

# ---------------------------------------------------------------------------
# 1. Инфраструктура хоста
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/infra-install-proxmox-tools.sh"
"${SCRIPT_DIR}/infra-enable-iommu.sh"
"${SCRIPT_DIR}/infra-configure-network.sh"     # bridge + ip_forward (без nft)

# ---------------------------------------------------------------------------
# 2. VM: образ, шаблон, LLM, Monitoring
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/vm-download-cloud-image.sh"
"${SCRIPT_DIR}/vm-create-cloudinit-template.sh"
"${SCRIPT_DIR}/vm-create-llm-vm.sh"
"${SCRIPT_DIR}/vm-create-monitoring-vm.sh"

# ---------------------------------------------------------------------------
# 3. LLM VM: Docker + NVIDIA + стек
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/deployment-install-guest-runtime.sh"     "${LLM_IP}"
"${SCRIPT_DIR}/deployment-install-nvidia-toolkit-llm.sh" "${LLM_IP}"
"${SCRIPT_DIR}/deployment-deploy-llm-stack.sh"          "${LLM_IP}"
"${SCRIPT_DIR}/ollama-setup-models.sh"                  "${LLM_IP}"

# ---------------------------------------------------------------------------
# 4. Monitoring VM: Docker + стек
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/deployment-install-guest-runtime.sh"     "${MONITORING_IP}"
"${SCRIPT_DIR}/deployment-deploy-monitoring-stack.sh"   "${MONITORING_IP}"

# ---------------------------------------------------------------------------
# 5. Nginx proxy + nftables (порядок важен: сначала LXC, потом правила)
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/proxy-deploy-nginx-proxy.sh"
"${SCRIPT_DIR}/infra-setup-nft-rules.sh"               # единственный источник nft-правил

# ---------------------------------------------------------------------------
# 6. Быстрая проверка
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/deployment-check-llm-vm-quick.sh"

audit_log "run-all.sh completed"
