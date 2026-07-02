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
# 2. nftables: masquerade + forward-правила (единственный источник nft-правил).
#    ВАЖНО: это должно идти ДО создания любых VM/LXC — без masquerade у них
#    нет выхода в интернет, и apt/docker/ollama внутри просто зависают.
#    Ruleset строится только из статических значений config, поэтому не
#    зависит от того, что LLM/Monitoring VM или nginx LXC ещё не существуют.
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/infra-setup-nft-rules.sh"

# ---------------------------------------------------------------------------
# 3. VM: образ, шаблон, LLM, Monitoring
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/vm-download-cloud-image.sh"
"${SCRIPT_DIR}/vm-create-cloudinit-template.sh"
"${SCRIPT_DIR}/vm-create-llm-vm.sh"
"${SCRIPT_DIR}/vm-create-monitoring-vm.sh"

# ---------------------------------------------------------------------------
# 4. LLM VM: Docker + NVIDIA + стек
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/deployment-install-guest-runtime.sh"     "${LLM_IP}"
"${SCRIPT_DIR}/deployment-install-nvidia-toolkit-llm.sh" "${LLM_IP}"
"${SCRIPT_DIR}/deployment-deploy-llm-stack.sh"          "${LLM_IP}"
"${SCRIPT_DIR}/ollama-setup-models.sh"                  "${LLM_IP}"

# ---------------------------------------------------------------------------
# 5. Monitoring VM: Docker + стек
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/deployment-install-guest-runtime.sh"     "${MONITORING_IP}"
"${SCRIPT_DIR}/deployment-deploy-monitoring-stack.sh"   "${MONITORING_IP}"

# ---------------------------------------------------------------------------
# 6. Nginx proxy (nft-правила для DNAT на него уже применены в шаге 2)
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/proxy-deploy-nginx-proxy.sh"

# ---------------------------------------------------------------------------
# 7. Быстрая проверка
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/deployment-check-llm-vm-quick.sh"

audit_log "run-all.sh completed"
