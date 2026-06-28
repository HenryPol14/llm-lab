#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}"
CONFIG_YAML="${CONFIG_YAML:-${PROJECT_ROOT}/config/infra.yaml}"

AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/llm-lab}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

log()   { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info()  { log "INFO: $*"; }
warn()  { log "WARN: $*" >&2; }
die()   { log "ERROR: $*" >&2; exit 1; }

audit_log() {
  if [[ "${ENABLE_AUDIT_LOG:-true}" == "true" ]]; then
    mkdir -p "$AUDIT_LOG_DIR"
    local log_file
    log_file="$AUDIT_LOG_DIR/$(date +%Y%m%d).log"
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

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }
require_cmd()  { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_yq()   { require_cmd yq || die "yq is required. Install: https://github.com/mikefarah/yq"; }

yaml_get() {
  local query="$1"
  local value
  value="$(yq -r "$query" "$CONFIG_YAML")"
  [[ "$value" == "null" ]] && value=""
  printf '%s' "$value"
}

validate_network_variable() {
  local name="$1" value="$2"
  [[ -n "$value" ]]       || die "Network config value $name is required and must not be empty"
  [[ "$value" != *"\""* ]] || die "Invalid quoted value loaded for $name: $value"
}

validate_network_config() {
  validate_network_variable INTERNAL_BRIDGE  "$INTERNAL_BRIDGE"
  validate_network_variable WAN_BRIDGE       "$WAN_BRIDGE"
  validate_network_variable INTERNAL_CIDR    "$INTERNAL_CIDR"
  validate_network_variable INTERNAL_SUBNET  "$INTERNAL_SUBNET"
  validate_network_variable INTERNAL_GATEWAY "$INTERNAL_GATEWAY"

  [[ "$INTERNAL_BRIDGE"  =~ ^[a-zA-Z0-9._-]+$ ]]                     || die "Invalid bridge name: $INTERNAL_BRIDGE"
  [[ "$WAN_BRIDGE"       =~ ^[a-zA-Z0-9._-]+$ ]]                     || die "Invalid bridge name: $WAN_BRIDGE"
  [[ "$INTERNAL_SUBNET"  =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid subnet: $INTERNAL_SUBNET"
  [[ "$INTERNAL_CIDR"    =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid CIDR: $INTERNAL_CIDR"
  [[ "$INTERNAL_GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]         || die "Invalid gateway: $INTERNAL_GATEWAY"
}

nftables_whitelist_config() {
  cat <<EOF
table inet llm_lab {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${LLM_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${LLM_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade
    ip saddr ${MONITORING_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${MONITORING_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" drop
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ip daddr ${LLM_IP} tcp dport { 3000, 11434 } accept
    ip daddr ${MONITORING_IP} tcp dport { 3000, 9090 } accept
    ct state established,related accept
    ip saddr ${INTERNAL_SUBNET} ip daddr ${INTERNAL_SUBNET} drop
  }
  chain input  { type filter hook input  priority 0; policy accept; }
  chain output { type filter hook output priority 0; policy accept; }
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
  pvesm status | awk 'NR > 1 {print $1}' | grep -qxF "$storage" \
    || die "Proxmox storage not found: $storage"
}

assert_var_set() { [[ -n "${!1}" ]] || die "Variable $1 is not set"; }
is_dry_run()     { [[ "$DRY_RUN" == "true" ]]; }

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
  local line="$1" file="$2"
  touch "$file" || true
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

vm_exists()  { qm config "$1" >/dev/null 2>&1; }
vm_running() { qm status "$1" 2>/dev/null | grep -q 'running' || true; }

# FIX: добавлена функция fix_locale — устраняет locale warnings в LXC контейнерах
fix_locale() {
  local ctid="${1:-${NGINX_CTID:-}}"
  [[ -n "$ctid" ]] || die "fix_locale: container ID required"
  info "Fixing locale in container ${ctid}"
  pct exec "$ctid" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq locales 2>/dev/null || true
    locale-gen en_US.UTF-8 2>/dev/null || true
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
  " || warn "fix_locale: non-fatal error in container ${ctid}"
}

guest_is_ready() {
  local vmid="$1" timeout="${2:-180}" waited=0
  info "Waiting for guest agent on VM ${vmid}"
  until qm guest exec "$vmid" -- true >/dev/null 2>&1; do
    sleep 3; ((waited += 3))
    ((waited >= timeout)) && die "Guest agent not ready on VM ${vmid} after ${timeout}s"
  done
}

wait_for_cloud_init() {
  local vmid="$1" timeout="${2:-300}" waited=0
  info "Waiting for cloud-init on VM ${vmid}"
  while ! qm guest exec "$vmid" -- test -f /var/lib/cloud/boot-finished >/dev/null 2>&1; do
    sleep 5; ((waited += 5))
    if ((waited % 30 == 0)); then
      local status; status="$(qm guest exec "$vmid" -- cloud-init status 2>/dev/null || true)"
      info "cloud-init status on VM ${vmid}: ${status}"
    fi
    ((waited >= timeout)) && die "cloud-init did not finish on VM ${vmid} after ${timeout}s"
  done
  info "cloud-init completed on VM ${vmid}"
}

parse_qm_guest_exec_output() {
  local raw="$1"
  if [[ "$raw" == *'"out-data"'* ]]; then
    local parsed
    parsed="$(printf '%s\n' "$raw" \
      | grep '"out-data"' \
      | sed -e 's/^.*"out-data"[[:space:]]*:[[:space:]]*"//' \
            -e 's/"[[:space:]]*,[[:space:]]*"[^"]*"[[:space:]]*:.*$//' \
            -e 's/"[[:space:]]*}[[:space:]]*$//' \
            -e 's/"[,]$//' \
            -e 's/"$//')"
    if [[ -n "$parsed" ]]; then
      parsed="${parsed%\\n}"; parsed="${parsed//\\n/ }"
      printf '%s' "$parsed"; return
    fi
  fi
  printf '%s' "$raw"
}

parse_qm_guest_exec_error() {
  local raw="$1" parsed
  parsed="$(printf '%s\n' "$raw" \
    | grep '"err-data"' \
    | sed -e 's/^.*"err-data"[[:space:]]*:[[:space:]]*"//' \
          -e 's/"[[:space:]]*,[[:space:]]*"[^"]*"[[:space:]]*:.*$//' \
          -e 's/"[[:space:]]*}[[:space:]]*$//' \
          -e 's/"[,]$//' \
          -e 's/"$//')" || true
  if [[ -n "$parsed" ]]; then
    parsed="${parsed%\\n}"; parsed="${parsed//\\n/ }"
    printf '%s' "$parsed"
  fi
}

parse_qm_guest_exec_exitcode() {
  local raw="$1" exitcode
  exitcode="$(printf '%s\n' "$raw" \
    | sed -nE 's/.*"exitcode"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' \
    | head -n1)" || true
  printf '%s' "${exitcode:-0}"
}

assert_qm_guest_exec_success() {
  local raw="$1" context="${2:-qm guest exec}" exitcode
  exitcode="$(parse_qm_guest_exec_exitcode "$raw")"
  if [[ "$exitcode" != "0" ]]; then
    warn "$context failed inside guest with exitcode ${exitcode}"
    warn "Guest output: $(parse_qm_guest_exec_output "$raw")"
    local err; err="$(parse_qm_guest_exec_error "$raw")"
    [[ -n "$err" ]] && warn "Guest error: $err"
    return 1
  fi
}

check_system_running() {
  local vmid="$1" result state
  result="$(qm guest exec "$vmid" -- systemctl is-system-running 2>/dev/null)" || {
    warn "System running check failed on VM ${vmid}"; return 1
  }
  state="$(parse_qm_guest_exec_output "$result")"
  state="${state//$'\r'/}"; state="${state//$'\n'/}"
  case "$state" in
    running*)          info "System is running on VM ${vmid}: ${state}"; return 0 ;;
    degraded|starting*) warn "System state on VM ${vmid}: ${state} (continuing)"; return 0 ;;
    *)                 warn "System state on VM ${vmid}: ${state}"; return 1 ;;
  esac
}

check_guest_network() {
  local vmid="$1" expected_ip="$2" timeout="${3:-120}" waited=0
  info "Verifying guest network IP ${expected_ip} on VM ${vmid}"
  while :; do
    local result out iface_list
    result="$(qm guest exec "$vmid" -- ip -4 addr show 2>/dev/null)" || { sleep 3; ((waited+=3)); ((waited>=timeout)) && { warn "check_guest_network: ip failed"; return 1; }; continue; }
    out="$(parse_qm_guest_exec_output "$result")"
    iface_list="$(qm guest exec "$vmid" -- ip -4 addr show 2>/dev/null)" || true
    info "check_guest_network: iface output on VM ${vmid}: ${iface_list}"
    printf '%s' "$out" | grep -q -- "$expected_ip" && { info "Guest ${vmid} has IP ${expected_ip}"; return 0; }
    sleep 3; ((waited+=3))
    ((waited>=timeout)) && { warn "Guest ${vmid} missing IP ${expected_ip} after ${timeout}s"; return 1; }
  done
}

validate_pci_device() {
  local pci_addr="$1"
  require_cmd lspci
  if [[ -n "$pci_addr" ]]; then
    lspci -s "$pci_addr" >/dev/null 2>&1 || die "PCI device not found: $pci_addr"
    local kernel_driver
    kernel_driver="$(lspci -s "$pci_addr" -k 2>/dev/null \
      | awk -F': ' '/Kernel driver in use:/ {print $2; exit}')"
    if [[ -n "$kernel_driver" && "$kernel_driver" != "vfio-pci" ]]; then
      warn "PCI device $pci_addr bound to host driver '$kernel_driver'; passthrough may need vfio-pci"
    fi
    info "Validated PCI device: $pci_addr"
  else
    warn "No PCI device address provided"
  fi
}

normalize_gb() {
  local value="$1"
  value="${value%G}"; value="${value%GB}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid disk size: $1"
  echo "$value"
}

load_yaml_config() {
  require_yq
  if [[ -f "$CONFIG_YAML" ]]; then
    info "Loading YAML config from $CONFIG_YAML"

    export LLM_VMID LLM_NAME LLM_IP LLM_PREFIX LLM_MEMORY_MB LLM_CORES LLM_SYSTEM_DISK_GB LLM_DATA_DISK_GB
    export MONITORING_VMID MONITORING_NAME MONITORING_IP MONITORING_PREFIX
    export MONITORING_MEMORY_MB MONITORING_CORES MONITORING_SYSTEM_DISK_GB MONITORING_DATA_DISK_GB
    export INTERNAL_BRIDGE INTERNAL_GATEWAY DNS_SERVER INTERNAL_CIDR INTERNAL_SUBNET WAN_BRIDGE
    export TEMPLATE_VMID TEMPLATE_STORAGE LLM_STORAGE MONITORING_STORAGE GUEST_USER SSH_OPTS
    export GPU_PCI_ADDR GPU_PASSTHROUGH FIREWALL_ENABLED LOGGING_ENABLED AUDIT_ENABLED
    export PROXMOX_HOST PROXMOX_USER REMOTE_DIR
    export NGINX_CTID NGINX_HOSTNAME NGINX_STORAGE NGINX_DISK_GB NGINX_MEMORY_MB NGINX_CORES
    export NGINX_WAN_IP NGINX_WAN_GW LXC_TEMPLATE

    # FIX: LLM_VMID был пропущен — добавлен
    LLM_VMID="$(yaml_get '.llm_vm.vmid')"
    LLM_NAME="$(yaml_get '.llm_vm.name')"
    LLM_IP="$(yaml_get '.llm_vm.ip')"
    LLM_PREFIX="$(yaml_get '.llm_vm.prefix')"
    LLM_MEMORY_MB="$(yaml_get '.llm_vm.memory_mb')"
    LLM_CORES="$(yaml_get '.llm_vm.cores')"
    LLM_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.system_disk_gb')")"
    LLM_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.data_disk_gb')")"

    MONITORING_VMID="$(yaml_get '.monitoring_vm.vmid')"
    MONITORING_NAME="$(yaml_get '.monitoring_vm.name')"
    MONITORING_IP="$(yaml_get '.monitoring_vm.ip')"
    MONITORING_PREFIX="$(yaml_get '.monitoring_vm.prefix')"
    MONITORING_MEMORY_MB="$(yaml_get '.monitoring_vm.memory_mb')"
    MONITORING_CORES="$(yaml_get '.monitoring_vm.cores')"
    MONITORING_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.system_disk_gb')")"
    MONITORING_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.data_disk_gb')")"

    INTERNAL_BRIDGE="$(yaml_get '.network.internal_bridge')"
    INTERNAL_GATEWAY="$(yaml_get '.network.internal_gateway')"
    DNS_SERVER="$(yaml_get '.network.dns_server')"
    INTERNAL_CIDR="$(yaml_get '.network.internal_cidr')"
    INTERNAL_SUBNET="$(yaml_get '.network.internal_subnet')"
    WAN_BRIDGE="$(yaml_get '.network.wan_bridge')"

    TEMPLATE_VMID="$(yaml_get '.template.vmid')"
    TEMPLATE_STORAGE="$(yaml_get '.template.storage')"
    LLM_STORAGE="$(yaml_get '.storage.llm')"
    MONITORING_STORAGE="$(yaml_get '.storage.monitoring')"

    GUEST_USER="$(yaml_get '.guest.user')"
    SSH_OPTS="$(yaml_get '.guest.ssh_opts')"

    GPU_PCI_ADDR="$(yaml_get '.llm_vm.gpu_pci_addr')"
    GPU_PASSTHROUGH="$(yaml_get '.features.gpu_passthrough')"
    FIREWALL_ENABLED="$(yaml_get '.features.firewall_enabled')"
    LOGGING_ENABLED="$(yaml_get '.features.logging_enabled')"
    AUDIT_ENABLED="$(yaml_get '.features.audit_enabled')"

    PROXMOX_HOST="$(yaml_get '.proxmox.host')"
    PROXMOX_USER="$(yaml_get '.proxmox.user')"
    REMOTE_DIR="$(yaml_get '.proxmox.remote_dir')"

    # FIX: nginx_proxy теперь читает flat-структуру (после исправления infra.yaml)
    NGINX_CTID="$(yaml_get '.nginx_proxy.ctid')"
    NGINX_HOSTNAME="$(yaml_get '.nginx_proxy.hostname')"
    NGINX_STORAGE="$(yaml_get '.nginx_proxy.storage')"
    NGINX_DISK_GB="$(yaml_get '.nginx_proxy.disk_gb')"
    NGINX_MEMORY_MB="$(yaml_get '.nginx_proxy.memory_mb')"
    NGINX_CORES="$(yaml_get '.nginx_proxy.cores')"
    NGINX_WAN_IP="$(yaml_get '.nginx_proxy.wan_ip')"
    NGINX_WAN_GW="$(yaml_get '.nginx_proxy.wan_gw')"
    LXC_TEMPLATE="$(yaml_get '.nginx_proxy.lxc_template')"

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
    # shellcheck disable=SC1090
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
    info "[DRY RUN] Would run: ${cmd[*]}"; return 0
  else
    audit_log "Executing: ${cmd[*]}"
    "${cmd[@]}"
  fi
}

guest_ssh() {
  local host="$1"; shift
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  if is_dry_run; then
    info "[DRY RUN] Would ssh to ${host}: $*"; return 0
  else
    audit_log "SSH to ${host}: $*"
    ssh $opts "${GUEST_USER:-ubuntu}@${host}" "$@"
  fi
}

wait_for_ssh() {
  local host="$1" timeout="${2:-180}" waited=0
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  info "Waiting for SSH on ${GUEST_USER:-ubuntu}@${host}"
  while :; do
    if ssh $opts -o ConnectTimeout=5 -o BatchMode=yes "${GUEST_USER:-ubuntu}@${host}" true >/dev/null 2>&1; then
      info "SSH is ready on ${host}"; return 0
    fi
    sleep 3; ((waited += 3))
    ((waited >= timeout)) && die "SSH not ready on ${host} after ${timeout}s"
  done
}
