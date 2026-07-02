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
#   ./scripts/redeploy-clean-full.sh                    # спросит подтверждение перед очисткой
#   ./scripts/redeploy-clean-full.sh --yes               # без интерактивного подтверждения
#   ./scripts/redeploy-clean-full.sh --skip-clean        # сразу Фаза 1, без очистки
#   ./scripts/redeploy-clean-full.sh --from-step 8        # повтор с шага 8/15 (Фаза 0 пропускается автоматически)
#   ./scripts/redeploy-clean-full.sh --skip-steps 9,11    # пропустить конкретные шаги Фазы 1 (например, уже выполненные)
#
# Шаги Фазы 1 (для --from-step / --skip-steps):
#   1 infra-install-proxmox-tools    6 vm-create-llm-vm            11 ollama-setup-models
#   2 infra-enable-iommu             7 vm-create-monitoring-vm     12 deployment-install-guest-runtime (Monitoring)
#   3 infra-configure-network        8 deployment-install-guest-runtime (LLM)  13 deployment-deploy-monitoring-stack
#   4 vm-download-cloud-image        9 deployment-install-nvidia-toolkit-llm  14 proxy-deploy-nginx-proxy
#   5 vm-create-cloudinit-template   10 deployment-deploy-llm-stack           15 infra-setup-nft-rules
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
FROM_STEP=1
declare -A SKIP_STEP_SET=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --skip-clean) SKIP_CLEAN=1; shift ;;
    --from-step)
      FROM_STEP="${2:?--from-step requires a number}"
      [[ "$FROM_STEP" =~ ^[0-9]+$ ]] || die "--from-step expects a number, got: $FROM_STEP"
      shift 2
      ;;
    --skip-steps)
      IFS=',' read -ra _skip_list <<< "${2:?--skip-steps requires a comma-separated list}"
      for _n in "${_skip_list[@]}"; do
        [[ "$_n" =~ ^[0-9]+$ ]] || die "--skip-steps expects numbers, got: $_n"
        SKIP_STEP_SET["$_n"]=1
      done
      shift 2
      ;;
    *) die "Unknown argument: $1 (use --yes, --skip-clean, --from-step N, --skip-steps a,b,c)" ;;
  esac
done

if (( FROM_STEP > 1 )) && (( SKIP_CLEAN == 0 )); then
  info "--from-step ${FROM_STEP} given: implying --skip-clean (won't destroy VMs already created by earlier steps)"
  SKIP_CLEAN=1
fi

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

CLEAN_STEP_NUM=0
clean_step() {
  local desc="$1"; shift
  CLEAN_STEP_NUM=$((CLEAN_STEP_NUM + 1))
  mark_step "[clean ${CLEAN_STEP_NUM}] ${desc}"
  "$@"
}

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

  clean_step "Removing nftables lab rules" flush_nft_lab_tables
  check "nftables lab tables removed" nft_lab_absent

  clean_step "Destroying nginx-proxy LXC ${NGINX_CTID}" destroy_lxc "$NGINX_CTID"
  check "LXC ${NGINX_CTID} destroyed" lxc_absent "$NGINX_CTID"

  clean_step "Destroying LLM VM ${LLM_VMID}" destroy_vm "$LLM_VMID"
  check "VM ${LLM_VMID} destroyed" vm_absent "$LLM_VMID"

  clean_step "Destroying Monitoring VM ${MONITORING_VMID}" destroy_vm "$MONITORING_VMID"
  check "VM ${MONITORING_VMID} destroyed" vm_absent "$MONITORING_VMID"

  clean_step "Destroying template VM ${TEMPLATE_VMID}" destroy_vm "$TEMPLATE_VMID"
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

# deploy_step — как clean_step, но умеет пропускать шаги по номеру:
# --from-step N пропускает всё, что < N; --skip-steps a,b,c пропускает
# конкретные номера. Пропуск затрагивает только выполнение самого шага —
# идущие следом check(...)/verify-скрипты всегда выполняются, чтобы
# подтвердить, что пропущенный шаг реально не нужен.
DEPLOY_STEP_NUM=0
deploy_step() {
  local desc="$1"; shift
  DEPLOY_STEP_NUM=$((DEPLOY_STEP_NUM + 1))
  if (( DEPLOY_STEP_NUM < FROM_STEP )) || [[ -n "${SKIP_STEP_SET[$DEPLOY_STEP_NUM]:-}" ]]; then
    info "[${DEPLOY_STEP_NUM}/15] ${desc} — SKIPPED"
    return 0
  fi
  mark_step "[${DEPLOY_STEP_NUM}/15] ${desc}"
  "$@"
}

phase1_deploy() {
  mark_step "PHASE 1: Sequential deployment with per-step verification"

  deploy_step "infra-install-proxmox-tools.sh" "${SCRIPT_DIR}/infra-install-proxmox-tools.sh"
  check "nft available on host" bash -c 'command -v nft >/dev/null'

  deploy_step "infra-enable-iommu.sh" "${SCRIPT_DIR}/infra-enable-iommu.sh"
  if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline; then
    info "  ✓ IOMMU active in running kernel"
  else
    warn "  ⚠ IOMMU not active in current kernel — reboot Proxmox host before GPU passthrough is needed"
  fi

  deploy_step "infra-configure-network.sh" "${SCRIPT_DIR}/infra-configure-network.sh"
  check "bridge ${INTERNAL_BRIDGE} up" bash -c "ip link show ${INTERNAL_BRIDGE} >/dev/null 2>&1"
  # shellcheck disable=SC2016
  check "ip_forward enabled" bash -c '[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]'

  deploy_step "vm-download-cloud-image.sh" "${SCRIPT_DIR}/vm-download-cloud-image.sh"
  check "cloud image present" test -f "$UBUNTU_IMAGE_PATH"

  deploy_step "vm-create-cloudinit-template.sh" "${SCRIPT_DIR}/vm-create-cloudinit-template.sh"
  check "template ${TEMPLATE_VMID} ready" template_is_template

  deploy_step "vm-create-llm-vm.sh" "${SCRIPT_DIR}/vm-create-llm-vm.sh"
  "${SCRIPT_DIR}/vm-verify-llm-vm.sh"

  deploy_step "vm-create-monitoring-vm.sh" "${SCRIPT_DIR}/vm-create-monitoring-vm.sh"
  "${SCRIPT_DIR}/vm-verify-monitoring-vm.sh"

  deploy_step "deployment-install-guest-runtime.sh (LLM)" "${SCRIPT_DIR}/deployment-install-guest-runtime.sh" "$LLM_IP"
  check "docker on LLM VM" guest_docker_ok "$LLM_IP"

  deploy_step "deployment-install-nvidia-toolkit-llm.sh" "${SCRIPT_DIR}/deployment-install-nvidia-toolkit-llm.sh" "$LLM_IP"

  deploy_step "deployment-deploy-llm-stack.sh" "${SCRIPT_DIR}/deployment-deploy-llm-stack.sh" "$LLM_IP"
  check "Ollama API responding" curl_ok "http://${LLM_IP}:11434/api/tags"
  check "Open WebUI responding" curl_ok "http://${LLM_IP}:3000"

  deploy_step "ollama-setup-models.sh" "${SCRIPT_DIR}/ollama-setup-models.sh" "$LLM_IP"

  deploy_step "deployment-install-guest-runtime.sh (Monitoring)" "${SCRIPT_DIR}/deployment-install-guest-runtime.sh" "$MONITORING_IP"
  check "docker on Monitoring VM" guest_docker_ok "$MONITORING_IP"

  deploy_step "deployment-deploy-monitoring-stack.sh" "${SCRIPT_DIR}/deployment-deploy-monitoring-stack.sh" "$MONITORING_IP"
  check "Prometheus ready" curl_ok "http://${MONITORING_IP}:9090/-/ready"
  check "Grafana healthy" curl_ok "http://${MONITORING_IP}:3000/api/health"

  deploy_step "proxy-deploy-nginx-proxy.sh" "${SCRIPT_DIR}/proxy-deploy-nginx-proxy.sh"
  check "nginx active in LXC ${NGINX_CTID}" bash -c "pct exec ${NGINX_CTID} -- systemctl is-active --quiet nginx"

  deploy_step "infra-setup-nft-rules.sh" "${SCRIPT_DIR}/infra-setup-nft-rules.sh"
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
  info "Skipping Phase 0 (cleanup) as requested"
fi

phase1_deploy

audit_log "redeploy-clean-full.sh completed successfully"
info "Redeploy finished successfully. Access: https://${PROXMOX_HOST}/"
