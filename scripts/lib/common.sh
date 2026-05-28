#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}"
CONFIG_YAML="${CONFIG_YAML:-${PROJECT_ROOT}/config/infra.yaml}"

AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/llm-lab}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
die() { log "ERROR: $*" >&2; exit 1; }

audit_log() {
  if [[ "${ENABLE_AUDIT_LOG:-true}" == "true" ]]; then
    mkdir -p "$AUDIT_LOG_DIR"
    local log_file="$AUDIT_LOG_DIR/$(date +%Y%m%d).log"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file"
  fi
}

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  local script_name="${BASH_SOURCE[1]:-script}"
  log "ERROR: ${script_name} failed at line ${line_no} with exit code ${exit_code}" >&2
  audit_log "ERROR: ${script_name}:${line_no} exit ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_yq() {
  require_cmd yq || die "yq is required for YAML config parsing. Install: https://github.com/mikefarah/yq"
}

mark_step() {
  audit_log "STEP_START: $*"
  info "━━━ $* ━━━"
}

require_pve_storage() {
  local storage="$1"
  require_cmd pvesm
  pvesm status | awk 'NR > 1 {print $1}' | grep -qxF "$storage" || die "Proxmox storage not found: $storage"
}

assert_var_set() {
  [[ -n "${!1}" ]] || die "Variable $1 is not set"
}

is_dry_run() {
  [[ "$DRY_RUN" == "true" ]]
}

install_missing_packages() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    info "Installing packages: ${missing[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

ensure_line() {
  local line="$1"
  local file="$2"
  touch "$file"
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

vm_exists() {
  qm config "$1" >/dev/null 2>&1
}

vm_running() {
  qm status "$1" 2>/dev/null | grep -q 'running'
}

guest_is_ready() {
  local vmid="$1"
  local timeout="${2:-180}"
  local waited=0
  info "Waiting for guest agent on VM ${vmid}"
  until qm guest exec "$vmid" -- true >/dev/null 2>&1; do
    sleep 3
    ((waited += 3))
    if ((waited >= timeout)); then
      die "Guest agent not ready on VM ${vmid} after ${timeout}s"
    fi
  done
}

wait_for_cloud_init() {
  local vmid="$1"
  local timeout="${2:-300}"
  local waited=0
  info "Waiting for cloud-init completion on VM ${vmid}"
  until qm guest exec "$vmid" -- test -f /var/lib/cloud/boot-finished >/dev/null 2>&1; do
    sleep 5
    ((waited += 5))
    if ((waited >= timeout)); then
      die "cloud-init did not finish on VM ${vmid} after ${timeout}s"
    fi
  done
}

check_system_running() {
  local vmid="$1"
  local state
  state="$(qm guest exec "$vmid" -- systemctl is-system-running 2>/dev/null)" || {
    warn "System running check failed on VM ${vmid}"
    return 1
  }
  case "$state" in
    running.*)
      info "System is running on VM ${vmid}: ${state}"
      return 0
      ;;
    *)
      warn "System state on VM ${vmid}: ${state}"
      return 1
      ;;
  esac
}

validate_pci_device() {
  local pci_addr="$1"
  require_cmd lspci
  if [[ -n "$pci_addr" ]]; then
    if ! lspci -s "$pci_addr" >/dev/null 2>&1; then
      die "PCI device not found: $pci_addr"
    fi
    if lspci -s "$pci_addr" -vv 2>/dev/null | grep -i "flr" >/dev/null; then
      die "PCI device $pci_addr is already in use (FLR enabled)"
    fi
    info "Validated PCI device: $pci_addr"
  else
    warn "No PCI device address provided"
  fi
}

normalize_gb() {
  local value="$1"
  value="${value%G}"
  value="${value%GB}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid disk size: $1"
  echo "$value"
}

load_yaml_config() {
  require_yq
  if [[ -f "$CONFIG_YAML" ]]; then
    info "Loading YAML config from $CONFIG_YAML"
    export LLM_VMID="$(yq '.llm_vm.vmid' "$CONFIG_YAML")"
    export LLM_IP="$(yq '.llm_vm.ip' "$CONFIG_YAML")"
    export LLM_MEMORY_MB="$(yq '.llm_vm.memory_mb' "$CONFIG_YAML")"
    export LLM_CORES="$(yq '.llm_vm.cores' "$CONFIG_YAML")"
    export LLM_SYSTEM_DISK_GB="$(normalize_gb "$(yq '.llm_vm.system_disk_gb' "$CONFIG_YAML")")"
    export LLM_DATA_DISK_GB="$(normalize_gb "$(yq '.llm_vm.data_disk_gb' "$CONFIG_YAML")")"
    export MONITORING_VMID="$(yq '.monitoring_vm.vmid' "$CONFIG_YAML")"
    export MONITORING_IP="$(yq '.monitoring_vm.ip' "$CONFIG_YAML")"
    export MONITORING_MEMORY_MB="$(yq '.monitoring_vm.memory_mb' "$CONFIG_YAML")"
    export MONITORING_CORES="$(yq '.monitoring_vm.cores' "$CONFIG_YAML")"
    export MONITORING_SYSTEM_DISK_GB="$(normalize_gb "$(yq '.monitoring_vm.system_disk_gb' "$CONFIG_YAML")")"
    export MONITORING_DATA_DISK_GB="$(normalize_gb "$(yq '.monitoring_vm.data_disk_gb' "$CONFIG_YAML")")"
    export INTERNAL_BRIDGE="$(yq '.network.internal_bridge' "$CONFIG_YAML")"
    export INTERNAL_GATEWAY="$(yq '.network.internal_gateway' "$CONFIG_YAML")"
    export DNS_SERVER="$(yq '.network.dns_server' "$CONFIG_YAML")"
    export INTERNAL_CIDR="$(yq '.network.internal_cidr' "$CONFIG_YAML")"
    export INTERNAL_SUBNET="$(yq '.network.internal_subnet' "$CONFIG_YAML")"
    export WAN_BRIDGE="$(yq '.network.wan_bridge' "$CONFIG_YAML")"
    export TEMPLATE_VMID="$(yq '.template.vmid' "$CONFIG_YAML")"
    export TEMPLATE_STORAGE="$(yq '.template.storage' "$CONFIG_YAML")"
    export LLM_STORAGE="$(yq '.storage.llm' "$CONFIG_YAML")"
    export MONITORING_STORAGE="$(yq '.storage.monitoring' "$CONFIG_YAML")"
    export GUEST_USER="$(yq '.guest.user' "$CONFIG_YAML")"
    export SSH_OPTS="$(yq '.guest.ssh_opts' "$CONFIG_YAML")"
    export GPU_PCI_ADDR="$(yq '.llm_vm.gpu_pci_addr' "$CONFIG_YAML")"
    export GPU_PASSTHROUGH="$(yq '.features.gpu_passthrough' "$CONFIG_YAML")"
    export FIREWALL_ENABLED="$(yq '.features.firewall_enabled' "$CONFIG_YAML")"
    export LOGGING_ENABLED="$(yq '.features.logging_enabled' "$CONFIG_YAML")"
    export AUDIT_ENABLED="$(yq '.features.audit_enabled' "$CONFIG_YAML")"
    audit_log "Loaded YAML config"
  else
    warn "YAML config not found: $CONFIG_YAML. Falling back to environment variables."
  fi
}

load_legacy_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    warn "Loading legacy config from $CONFIG_FILE (deprecated, use YAML)"
    source "$CONFIG_FILE"
    set +a
    audit_log "Loaded legacy config"
  fi
}

load_config() {
  if [[ -f "$CONFIG_YAML" ]]; then
    load_yaml_config
  elif [[ -f "$CONFIG_FILE" ]]; then
    load_legacy_config
  else
    die "No config file found. Create $CONFIG_YAML or $CONFIG_FILE"
  fi
}

qm_command() {
  local cmd=("qm" "$@")
  if is_dry_run; then
    info "[DRY RUN] Would run: ${cmd[*]}"
    return 0
  else
    audit_log "Executing: ${cmd[*]}"
    "${cmd[@]}"
  fi
}

guest_ssh() {
  local host="$1"
  shift
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  local cmd=("ssh" ${opts} "${GUEST_USER:-ubuntu}@${host}" "$@")
  if is_dry_run; then
    info "[DRY RUN] Would run: ${cmd[*]}"
    return 0
  else
    audit_log "SSH to ${host}: $*"
    ssh ${opts} "${GUEST_USER:-ubuntu}@${host}" "$@"
  fi
}
