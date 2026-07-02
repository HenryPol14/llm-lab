#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Полный передеплой llm-lab.
#   Фаза 0 — удаляет предыдущее развёртывание (LLM VM, Monitoring VM,
#            шаблон, nginx-proxy LXC, nftables-правила проекта), НЕ трогая
#            файлы образов в /var/lib/vz/template/qcow2/.
#   Фаза 1 — прогоняет полный пайплайн (тот же порядок, что и run-all.sh),
#            но после каждого шага проверяет результат и останавливается
#            (die) при первой же неудаче.
#
# Использование (на Proxmox-хосте, от root):
#   ./scripts/redeploy-clean-full.sh              # спросит подтверждение перед очисткой
#   ./scripts/redeploy-clean-full.sh --yes         # без интерактивного подтверждения
#   ./scripts/redeploy-clean-full.sh --skip-clean  # сразу Фаза 1, без очистки
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_config
require_root
require_cmd qm
require_cmd pct
require_cmd nft
require_cmd curl

SKIP_CLEAN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --skip-clean) SKIP_CLEAN=1 ;;
    *) die "Unknown argument: $arg (use --yes or --skip-clean)" ;;
  esac
done

STEP_NUM=0
step() {
  local desc="$1"; shift
  STEP_NUM=$((STEP_NUM + 1))
  mark_step "[${STEP_NUM}] ${desc}"
  "$@"
}

check() {
  local desc="$1"; shift
  if "$@"; then
    info "  ✓ ${desc}"
  else
    die "  ✗ ${desc}"
  fi
}

# ============================================================
# ФАЗА 0 — очистка предыдущего развёртывания (образы НЕ трогаем)
# ============================================================

vm_absent()  { ! qm config "$1" >/dev/null 2>&1; }
lxc_absent() { ! pct status "$1" >/dev/null 2>&1; }
nft_lab_absent() {
  ! nft list table ip llm_lab_nat >/dev/null 2>&1 &&
  ! nft list table inet llm_lab_filter >/dev/null 2>&1
}

destroy_vm() {
  local vmid="$1"
  if qm config "$vmid" >/dev/null 2>&1; then
    vm_running "$vmid" && qm stop "$vmid"
    qm destroy "$vmid" --purge
  else
    info "VM ${vmid} already absent"
  fi
}

destroy_lxc() {
  local ctid="$1"
  if pct status "$ctid" >/dev/null 2>&1; then
    pct stop "$ctid" 2>/dev/null || true
    pct destroy "$ctid" --purge
  else
    info "LXC ${ctid} already absent"
  fi
}

# Отражает flush_lab_tables() из infra-setup-nft-rules.sh — та же авторитетная
# логика ("флашим ВСЕ таблицы, которые когда-либо создавал проект").
flush_nft_lab_tables() {
  local t
  for t in \
    "ip   llm_lab_nat"    \
    "inet llm_lab_filter" \
    "inet llm_lab"        \
    "inet pve_lab"        \
    "ip   nat"
  do
    # shellcheck disable=SC2086
    if nft delete table $t 2>/dev/null; then
      info "  Deleted: $t"
    fi
  done
}

phase0_cleanup() {
  mark_step "PHASE 0: Cleanup previous deployment (images preserved)"

  step "Removing nftables lab rules" flush_nft_lab_tables
  check "nftables lab tables removed" nft_lab_absent

  step "Destroying nginx-proxy LXC ${NGINX_CTID}" destroy_lxc "$NGINX_CTID"
  check "LXC ${NGINX_CTID} destroyed" lxc_absent "$NGINX_CTID"

  step "Destroying LLM VM ${LLM_VMID}" destroy_vm "$LLM_VMID"
  check "VM ${LLM_VMID} destroyed" vm_absent "$LLM_VMID"

  step "Destroying Monitoring VM ${MONITORING_VMID}" destroy_vm "$MONITORING_VMID"
  check "VM ${MONITORING_VMID} destroyed" vm_absent "$MONITORING_VMID"

  step "Destroying template VM ${TEMPLATE_VMID}" destroy_vm "$TEMPLATE_VMID"
  check "VM ${TEMPLATE_VMID} destroyed" vm_absent "$TEMPLATE_VMID"

  check "Base cloud image intact: ${UBUNTU_IMAGE_PATH}" test -f "$UBUNTU_IMAGE_PATH"
  check "Prepared template image intact: ${PREPARED_IMAGE_PATH}" test -f "$PREPARED_IMAGE_PATH"

  info "Phase 0 complete — previous deployment removed, images preserved"
}

# ============================================================
# ФАЗА 1 — последовательный деплой с контролем каждого шага
# ============================================================

curl_ok() { curl -fsSk --max-time "${2:-8}" "$1" >/dev/null; }
template_is_template() { qm config "$TEMPLATE_VMID" 2>/dev/null | grep -qx 'template: 1'; }
guest_docker_ok() { guest_ssh "$1" 'docker version >/dev/null 2>&1'; }

phase1_deploy() {
  mark_step "PHASE 1: Sequential deployment with per-step verification"

  step "1/15 infra-install-proxmox-tools.sh" "${SCRIPT_DIR}/infra-install-proxmox-tools.sh"
  check "nft available on host" bash -c 'command -v nft >/dev/null'

  step "2/15 infra-enable-iommu.sh" "${SCRIPT_DIR}/infra-enable-iommu.sh"
  if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline; then
    info "  ✓ IOMMU active in running kernel"
  else
    warn "  ⚠ IOMMU not active in current kernel — reboot Proxmox host before GPU passthrough is needed"
  fi

  step "3/15 infra-configure-network.sh" "${SCRIPT_DIR}/infra-configure-network.sh"
  check "bridge ${INTERNAL_BRIDGE} up" bash -c "ip link show ${INTERNAL_BRIDGE} >/dev/null 2>&1"
  # shellcheck disable=SC2016
  check "ip_forward enabled" bash -c '[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]'

  step "4/15 vm-download-cloud-image.sh" "${SCRIPT_DIR}/vm-download-cloud-image.sh"
  check "cloud image present" test -f "$UBUNTU_IMAGE_PATH"

  step "5/15 vm-create-cloudinit-template.sh" "${SCRIPT_DIR}/vm-create-cloudinit-template.sh"
  check "template ${TEMPLATE_VMID} ready" template_is_template

  step "6/15 vm-create-llm-vm.sh" "${SCRIPT_DIR}/vm-create-llm-vm.sh"
  "${SCRIPT_DIR}/vm-verify-llm-vm.sh"

  step "7/15 vm-create-monitoring-vm.sh" "${SCRIPT_DIR}/vm-create-monitoring-vm.sh"
  "${SCRIPT_DIR}/vm-verify-monitoring-vm.sh"

  step "8/15 deployment-install-guest-runtime.sh (LLM)" "${SCRIPT_DIR}/deployment-install-guest-runtime.sh" "$LLM_IP"
  check "docker on LLM VM" guest_docker_ok "$LLM_IP"

  step "9/15 deployment-install-nvidia-toolkit-llm.sh" "${SCRIPT_DIR}/deployment-install-nvidia-toolkit-llm.sh" "$LLM_IP"

  step "10/15 deployment-deploy-llm-stack.sh" "${SCRIPT_DIR}/deployment-deploy-llm-stack.sh" "$LLM_IP"
  check "Ollama API responding" curl_ok "http://${LLM_IP}:11434/api/tags"
  check "Open WebUI responding" curl_ok "http://${LLM_IP}:3000"

  step "11/15 ollama-setup-models.sh" "${SCRIPT_DIR}/ollama-setup-models.sh" "$LLM_IP"

  step "12/15 deployment-install-guest-runtime.sh (Monitoring)" "${SCRIPT_DIR}/deployment-install-guest-runtime.sh" "$MONITORING_IP"
  check "docker on Monitoring VM" guest_docker_ok "$MONITORING_IP"

  step "13/15 deployment-deploy-monitoring-stack.sh" "${SCRIPT_DIR}/deployment-deploy-monitoring-stack.sh" "$MONITORING_IP"
  check "Prometheus ready" curl_ok "http://${MONITORING_IP}:9090/-/ready"
  check "Grafana healthy" curl_ok "http://${MONITORING_IP}:3000/api/health"

  step "14/15 proxy-deploy-nginx-proxy.sh" "${SCRIPT_DIR}/proxy-deploy-nginx-proxy.sh"
  check "nginx active in LXC ${NGINX_CTID}" bash -c "pct exec ${NGINX_CTID} -- systemctl is-active --quiet nginx"

  step "15/15 infra-setup-nft-rules.sh" "${SCRIPT_DIR}/infra-setup-nft-rules.sh"
  check "DNAT table present" bash -c "nft list table ip llm_lab_nat >/dev/null 2>&1"
  check "forward filter table present" bash -c "nft list table inet llm_lab_filter >/dev/null 2>&1"
  check "public HTTPS entrypoint responding" curl_ok "https://${PROXMOX_HOST}/" 10

  "${SCRIPT_DIR}/deployment-check-llm-vm-quick.sh"

  info "Phase 1 complete — full stack deployed and verified"
}

# ============================================================
# MAIN
# ============================================================

if (( SKIP_CLEAN == 0 )); then
  if (( ASSUME_YES == 0 )); then
    echo "This will DESTROY VM ${LLM_VMID}, VM ${MONITORING_VMID}, VM ${TEMPLATE_VMID}, LXC ${NGINX_CTID} and flush llm_lab nftables tables."
    echo "Downloaded/prepared images under /var/lib/vz/template/qcow2/ are preserved."
    read -r -p "Type 'yes' to continue: " ans
    [[ "$ans" == "yes" ]] || die "Aborted by user"
  fi
  phase0_cleanup
else
  info "Skipping Phase 0 (cleanup) as requested (--skip-clean)"
fi

phase1_deploy

audit_log "redeploy-clean-full.sh completed successfully"
info "Redeploy finished successfully. Access: https://${PROXMOX_HOST}/"
