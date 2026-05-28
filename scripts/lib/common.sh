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

yaml_get() {
  local query="$1"
  local value
  value="$(yq -r "$query" "$CONFIG_YAML")"
  if [[ "$value" == "null" ]]; then
    value=""
  fi
  printf '%s' "$value"
}

validate_network_variable() {
  local name="$1"
  local value="$2"

  [[ -n "$value" ]] || die "Network config value $name is required and must not be empty"
  [[ "$value" != *"\""* ]] || die "Invalid quoted value loaded for $name: $value"
}

validate_network_config() {
  validate_network_variable INTERNAL_BRIDGE "$INTERNAL_BRIDGE"
  validate_network_variable WAN_BRIDGE "$WAN_BRIDGE"
  validate_network_variable INTERNAL_CIDR "$INTERNAL_CIDR"
  validate_network_variable INTERNAL_SUBNET "$INTERNAL_SUBNET"
  validate_network_variable INTERNAL_GATEWAY "$INTERNAL_GATEWAY"

  [[ "$INTERNAL_BRIDGE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid bridge name: $INTERNAL_BRIDGE"
  [[ "$WAN_BRIDGE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid bridge name: $WAN_BRIDGE"
  [[ "$INTERNAL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid subnet format: $INTERNAL_SUBNET"
  [[ "$INTERNAL_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid CIDR format: $INTERNAL_CIDR"
  [[ "$INTERNAL_GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid gateway address: $INTERNAL_GATEWAY"
}

nftables_whitelist_config() {
  cat <<EOF
table inet llm_lab {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    # Allow only specific services to internet
    ip saddr ${LLM_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${LLM_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade

    ip saddr ${MONITORING_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${MONITORING_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade

    # Deny all other outbound
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;

    # LLM VM services - inbound
    ip daddr ${LLM_IP} tcp dport { 3000, 11434 } accept

    # Monitoring VM services - inbound
    ip daddr ${MONITORING_IP} tcp dport { 3000, 9090 } accept

    # Allow established connections
    ct state established,related accept

    # Drop inter-VM communication
    ip saddr ${INTERNAL_SUBNET} ip daddr ${INTERNAL_SUBNET} drop
  }

  chain input {
    type filter hook input priority 0; policy accept;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF
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
    export LLM_VMID="$(yaml_get '.llm_vm.vmid')"
    export LLM_NAME="$(yaml_get '.llm_vm.name')"
    export LLM_IP="$(yaml_get '.llm_vm.ip')"
    export LLM_PREFIX="$(yaml_get '.llm_vm.prefix')"
    export LLM_MEMORY_MB="$(yaml_get '.llm_vm.memory_mb')"
    export LLM_CORES="$(yaml_get '.llm_vm.cores')"
    export LLM_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.system_disk_gb')")"
    export LLM_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.data_disk_gb')")"
    export MONITORING_VMID="$(yaml_get '.monitoring_vm.vmid')"
    export MONITORING_NAME="$(yaml_get '.monitoring_vm.name')"
    export MONITORING_IP="$(yaml_get '.monitoring_vm.ip')"
    export MONITORING_PREFIX="$(yaml_get '.monitoring_vm.prefix')"
    export MONITORING_MEMORY_MB="$(yaml_get '.monitoring_vm.memory_mb')"
    export MONITORING_CORES="$(yaml_get '.monitoring_vm.cores')"
    export MONITORING_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.system_disk_gb')")"
    export MONITORING_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.data_disk_gb')")"
    export INTERNAL_BRIDGE="$(yaml_get '.network.internal_bridge')"
    export INTERNAL_GATEWAY="$(yaml_get '.network.internal_gateway')"
    export DNS_SERVER="$(yaml_get '.network.dns_server')"
    export INTERNAL_CIDR="$(yaml_get '.network.internal_cidr')"
    export INTERNAL_SUBNET="$(yaml_get '.network.internal_subnet')"
    export WAN_BRIDGE="$(yaml_get '.network.wan_bridge')"
    export TEMPLATE_VMID="$(yaml_get '.template.vmid')"
    export TEMPLATE_STORAGE="$(yaml_get '.template.storage')"
    export LLM_STORAGE="$(yaml_get '.storage.llm')"
    export MONITORING_STORAGE="$(yaml_get '.storage.monitoring')"
    export GUEST_USER="$(yaml_get '.guest.user')"
    export SSH_OPTS="$(yaml_get '.guest.ssh_opts')"
    export GPU_PCI_ADDR="$(yaml_get '.llm_vm.gpu_pci_addr')"
    export GPU_PASSTHROUGH="$(yaml_get '.features.gpu_passthrough')"
    export FIREWALL_ENABLED="$(yaml_get '.features.firewall_enabled')"
    export LOGGING_ENABLED="$(yaml_get '.features.logging_enabled')"
    export AUDIT_ENABLED="$(yaml_get '.features.audit_enabled')"
    validate_network_config
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
