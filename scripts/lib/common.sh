#!/usr/bin/env bash
# scripts/lib/common.sh — shared library for llm-lab scripts
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}"
CONFIG_YAML="${CONFIG_YAML:-${PROJECT_ROOT}/config/infra.yaml}"

AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/llm-lab}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

audit_log() {
  if [[ "${ENABLE_AUDIT_LOG:-true}" == "true" ]]; then
    mkdir -p "$AUDIT_LOG_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
      >> "$AUDIT_LOG_DIR/$(date +%Y%m%d).log"
  fi
}

on_error() {
  local exit_code=$? line_no=${BASH_LINENO[0]:-?} script="${BASH_SOURCE[1]:-script}"
  log "ERROR: ${script} line ${line_no} exit ${exit_code}" >&2
  audit_log "ERROR: ${script}:${line_no} exit ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Basic guards
# ---------------------------------------------------------------------------
require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }
require_cmd()  { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_yq()   { require_cmd yq; }

is_dry_run() { [[ "$DRY_RUN" == "true" ]]; }

mark_step() {
  audit_log "STEP_START: $*"
  info "━━━ $* ━━━"
}

# ---------------------------------------------------------------------------
# Package management
# ---------------------------------------------------------------------------
install_missing_packages() {
  local missing=()
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    info "Installing: ${missing[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

ensure_line() {
  local line="$1" file="$2"
  touch "$file" || true
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# Proxmox storage
# ---------------------------------------------------------------------------
require_pve_storage() {
  require_cmd pvesm
  pvesm status | awk 'NR>1{print $1}' | grep -qxF "$1" \
    || die "Proxmox storage not found: $1"
}

# ---------------------------------------------------------------------------
# VM predicates — silent, no logging (used as conditionals)
# ---------------------------------------------------------------------------
vm_exists()  { qm config "$1" >/dev/null 2>&1; }

# FIX: убран info() — vm_running() вызывается в цикле, логи засоряли вывод
vm_running() {
  local st
  st="$(qm status "$1" 2>/dev/null | awk -F': ' '/^status:/{print $2}' | tr -d '[:space:]')"
  [[ "$st" == "running" ]]
}

# ---------------------------------------------------------------------------
# LXC: fix locale warnings before package installs
# ---------------------------------------------------------------------------
fix_locale() {
  local ctid="${1:?fix_locale requires container ID}"
  info "Fixing locale in LXC ${ctid}"
  pct exec "$ctid" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq locales 2>/dev/null || true
    locale-gen en_US.UTF-8 2>/dev/null || true
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
  " || warn "fix_locale: non-fatal error in LXC ${ctid}"
}

# ---------------------------------------------------------------------------
# VM readiness — simplified, no /tmp/vm-ips hack
# ---------------------------------------------------------------------------
guest_is_ready() {
  local vmid="$1" timeout="${2:-180}" waited=0
  info "Waiting for QEMU guest agent on VM ${vmid} (timeout ${timeout}s)"
  until qm guest exec "$vmid" -- true >/dev/null 2>&1; do
    sleep 5
    ((waited += 5))
    ((waited >= timeout)) && die "Guest agent not ready on VM ${vmid} after ${timeout}s"
  done
  info "Guest agent ready on VM ${vmid}"
}

# FIX: используем SSH через guest_ssh, а не qm guest exec с жёстким таймаутом Proxmox
wait_for_cloud_init() {
  local vmid="$1" timeout="${2:-300}" waited=0
  # IP получаем из cloud-init ipconfig0 в конфиге VM
  local ip
  ip="$(qm config "$vmid" 2>/dev/null \
    | awk -F'[= ,/]' '/^ipconfig0:/{for(i=1;i<=NF;i++) if($i=="ip") print $(i+1)}')"
  [[ -n "$ip" ]] || die "Cannot determine IP for VM ${vmid} from ipconfig0"

  info "Waiting for cloud-init on VM ${vmid} (${ip}, timeout ${timeout}s)"
  while ! guest_ssh "$ip" 'test -f /var/lib/cloud/boot-finished' 2>/dev/null; do
    sleep 5; ((waited += 5))
    if ((waited % 60 == 0)); then
      local st; st="$(guest_ssh "$ip" 'cloud-init status 2>/dev/null' || echo '?')"
      info "cloud-init on VM ${vmid}: ${st}"
    fi
    ((waited >= timeout)) && die "cloud-init timed out on VM ${vmid} after ${timeout}s"
  done
  info "cloud-init completed on VM ${vmid}"
}

check_guest_network() {
  local vmid="$1" expected_ip="$2" timeout="${3:-120}" waited=0
  info "Waiting for IP ${expected_ip} on VM ${vmid}"
  while :; do
    local raw out
    raw="$(qm guest exec "$vmid" -- ip -4 addr show 2>/dev/null)" || true
    out="$(parse_qm_guest_exec_output "$raw")"
    if printf '%s' "$out" | grep -qF "$expected_ip"; then
      info "VM ${vmid} has IP ${expected_ip}"; return 0
    fi
    sleep 5; ((waited += 5))
    if ((waited >= timeout)); then
      warn "VM ${vmid}: IP ${expected_ip} not found after ${timeout}s"
      warn "Current addrs: $(printf '%s' "$out" | grep 'inet ' || echo 'none')"
      return 1
    fi
  done
}

check_system_running() {
  local vmid="$1" raw state
  raw="$(qm guest exec "$vmid" -- systemctl is-system-running 2>/dev/null)" || {
    warn "System state check failed on VM ${vmid}"; return 1
  }
  state="$(parse_qm_guest_exec_output "$raw")"
  state="${state//[$'\r\n']/}"
  case "$state" in
    running)          info "VM ${vmid} system: running"; return 0 ;;
    degraded|starting) warn "VM ${vmid} system: ${state} (proceeding)"; return 0 ;;
    *)                warn "VM ${vmid} system: ${state}"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# qm guest exec output parsing
# ---------------------------------------------------------------------------
parse_qm_guest_exec_output() {
  local raw="$1"
  if [[ "$raw" == *'"out-data"'* ]]; then
    local parsed
    parsed="$(printf '%s\n' "$raw" \
      | grep '"out-data"' \
      | sed -e 's/^.*"out-data"[[:space:]]*:[[:space:]]*"//' \
            -e 's/"[[:space:]]*,.*$//' \
            -e 's/"[[:space:]]*}[[:space:]]*$//' \
            -e 's/"$//')"
    parsed="${parsed%\\n}"; parsed="${parsed//\\n/ }"
    [[ -n "$parsed" ]] && { printf '%s' "$parsed"; return; }
  fi
  printf '%s' "$raw"
}

parse_qm_guest_exec_exitcode() {
  printf '%s' "$(printf '%s\n' "$1" \
    | sed -nE 's/.*"exitcode"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
}

# ---------------------------------------------------------------------------
# PCI validation
# ---------------------------------------------------------------------------
validate_pci_device() {
  local pci_addr="$1"
  require_cmd lspci
  [[ -n "$pci_addr" ]] || { warn "No PCI device address provided"; return 0; }
  lspci -s "$pci_addr" >/dev/null 2>&1 || die "PCI device not found: $pci_addr"
  local drv
  drv="$(lspci -s "$pci_addr" -k 2>/dev/null \
         | awk -F': ' '/Kernel driver in use:/{print $2; exit}')"
  if [[ -n "$drv" && "$drv" != "vfio-pci" ]]; then
    warn "PCI ${pci_addr} bound to '${drv}'; passthrough needs vfio-pci binding"
  fi
  info "PCI device validated: $pci_addr"
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
normalize_gb() {
  local v="${1%G}"; v="${v%GB}"
  [[ "$v" =~ ^[0-9]+$ ]] || die "Invalid disk size: $1"
  printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------
guest_ssh() {
  local host="$1"; shift
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30}"
  if is_dry_run; then
    info "[DRY RUN] ssh ${GUEST_USER:-ubuntu}@${host} $*"; return 0
  fi
  audit_log "SSH ${host}: $*"
  # shellcheck disable=SC2086
  ssh $opts "${GUEST_USER:-ubuntu}@${host}" "$@"
}

wait_for_ssh() {
  local host="$1" timeout="${2:-180}" waited=0
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30}"
  info "Waiting for SSH on ${GUEST_USER:-ubuntu}@${host} (timeout ${timeout}s)"
  ssh-keygen -R "$host" >/dev/null 2>&1 || true
  while :; do
    # shellcheck disable=SC2086
    if ssh $opts -o ConnectTimeout=5 -o BatchMode=yes \
        "${GUEST_USER:-ubuntu}@${host}" true >/dev/null 2>&1; then
      info "SSH ready on ${host}"; return 0
    fi
    sleep 5; ((waited += 5))
    ((waited >= timeout)) && die "SSH not ready on ${host} after ${timeout}s"
  done
}

# ---------------------------------------------------------------------------
# qm wrapper
# ---------------------------------------------------------------------------
qm_command() {
  if is_dry_run; then
    info "[DRY RUN] qm $*"; return 0
  fi
  audit_log "qm $*"
  qm "$@"
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
yaml_get() {
  local v
  v="$(yq -r "$1" "$CONFIG_YAML")"
  [[ "$v" == "null" ]] && v=""
  printf '%s' "$v"
}

validate_network_config() {
  local vars=(INTERNAL_BRIDGE WAN_BRIDGE INTERNAL_CIDR INTERNAL_SUBNET INTERNAL_GATEWAY)
  for var in "${vars[@]}"; do
    local val="${!var:-}"
    [[ -n "$val" ]]        || die "Network variable $var is empty"
    [[ "$val" != *'"'* ]]  || die "Network variable $var contains quotes: $val"
  done
  [[ "$INTERNAL_BRIDGE"  =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid INTERNAL_BRIDGE: $INTERNAL_BRIDGE"
  [[ "$WAN_BRIDGE"       =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid WAN_BRIDGE: $WAN_BRIDGE"
  [[ "$INTERNAL_SUBNET"  =~ ^[0-9./]+$ ]]         || die "Invalid INTERNAL_SUBNET: $INTERNAL_SUBNET"
  [[ "$INTERNAL_CIDR"    =~ ^[0-9./]+$ ]]         || die "Invalid INTERNAL_CIDR: $INTERNAL_CIDR"
  [[ "$INTERNAL_GATEWAY" =~ ^[0-9.]+$ ]]           || die "Invalid INTERNAL_GATEWAY: $INTERNAL_GATEWAY"
}

load_yaml_config() {
  require_yq
  [[ -f "$CONFIG_YAML" ]] || { warn "YAML config not found: $CONFIG_YAML"; return 1; }
  info "Loading YAML config from $CONFIG_YAML"

  # --- LLM VM ---
  export LLM_VMID LLM_NAME LLM_IP LLM_PREFIX LLM_MEMORY_MB LLM_CORES \
         LLM_SYSTEM_DISK_GB LLM_DATA_DISK_GB GPU_PCI_ADDR GPU_PASSTHROUGH
  LLM_VMID="$(yaml_get '.llm_vm.vmid')"
  LLM_NAME="$(yaml_get '.llm_vm.name')"
  LLM_IP="$(yaml_get '.llm_vm.ip')"
  LLM_PREFIX="$(yaml_get '.llm_vm.prefix')"
  LLM_MEMORY_MB="$(yaml_get '.llm_vm.memory_mb')"
  LLM_CORES="$(yaml_get '.llm_vm.cores')"
  LLM_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.system_disk_gb')")"
  LLM_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.data_disk_gb')")"
  GPU_PCI_ADDR="$(yaml_get '.llm_vm.gpu_pci_addr')"
  GPU_PASSTHROUGH="$(yaml_get '.features.gpu_passthrough')"

  # --- Monitoring VM ---
  export MONITORING_VMID MONITORING_NAME MONITORING_IP MONITORING_PREFIX \
         MONITORING_MEMORY_MB MONITORING_CORES MONITORING_SYSTEM_DISK_GB MONITORING_DATA_DISK_GB
  MONITORING_VMID="$(yaml_get '.monitoring_vm.vmid')"
  MONITORING_NAME="$(yaml_get '.monitoring_vm.name')"
  MONITORING_IP="$(yaml_get '.monitoring_vm.ip')"
  MONITORING_PREFIX="$(yaml_get '.monitoring_vm.prefix')"
  MONITORING_MEMORY_MB="$(yaml_get '.monitoring_vm.memory_mb')"
  MONITORING_CORES="$(yaml_get '.monitoring_vm.cores')"
  MONITORING_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.system_disk_gb')")"
  MONITORING_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.data_disk_gb')")"

  # --- Network ---
  export INTERNAL_BRIDGE INTERNAL_GATEWAY INTERNAL_CIDR INTERNAL_SUBNET WAN_BRIDGE DNS_SERVER
  INTERNAL_BRIDGE="$(yaml_get '.network.internal_bridge')"
  INTERNAL_GATEWAY="$(yaml_get '.network.internal_gateway')"
  INTERNAL_CIDR="$(yaml_get '.network.internal_cidr')"
  INTERNAL_SUBNET="$(yaml_get '.network.internal_subnet')"
  WAN_BRIDGE="$(yaml_get '.network.wan_bridge')"
  DNS_SERVER="$(yaml_get '.network.dns_server')"

  # --- Storage / Template ---
  export TEMPLATE_VMID TEMPLATE_STORAGE LLM_STORAGE MONITORING_STORAGE \
         UBUNTU_IMAGE_PATH PREPARED_IMAGE_PATH SSH_PUBLIC_KEY
  TEMPLATE_VMID="$(yaml_get '.template.vmid')"
  TEMPLATE_STORAGE="$(yaml_get '.template.storage')"
  LLM_STORAGE="$(yaml_get '.storage.llm')"
  MONITORING_STORAGE="$(yaml_get '.storage.monitoring')"
  UBUNTU_IMAGE_PATH="$(yaml_get '.template.ubuntu_image_path')"
  PREPARED_IMAGE_PATH="$(yaml_get '.template.prepared_image_path')"
  SSH_PUBLIC_KEY="$(yaml_get '.template.ssh_public_key')"

  # --- Guest ---
  export GUEST_USER SSH_OPTS
  GUEST_USER="$(yaml_get '.guest.user')"
  SSH_OPTS="$(yaml_get '.guest.ssh_opts')"

  # --- Proxmox ---
  export PROXMOX_HOST PROXMOX_USER REMOTE_DIR
  PROXMOX_HOST="$(yaml_get '.proxmox.host')"
  PROXMOX_USER="$(yaml_get '.proxmox.user')"
  REMOTE_DIR="$(yaml_get '.proxmox.remote_dir')"

  # --- Nginx proxy ---
  # FIX: NGINX_IP экспортируется явно (раньше только NGINX_WAN_IP, что ломало infra-setup-nft-rules.sh)
  export NGINX_CTID NGINX_HOSTNAME NGINX_STORAGE NGINX_DISK_GB NGINX_MEMORY_MB NGINX_CORES \
         NGINX_WAN_IP NGINX_IP NGINX_WAN_GW LXC_TEMPLATE
  NGINX_CTID="$(yaml_get '.nginx_proxy.ctid')"
  NGINX_HOSTNAME="$(yaml_get '.nginx_proxy.hostname')"
  NGINX_STORAGE="$(yaml_get '.nginx_proxy.storage')"
  NGINX_DISK_GB="$(yaml_get '.nginx_proxy.disk_gb')"
  NGINX_MEMORY_MB="$(yaml_get '.nginx_proxy.memory_mb')"
  NGINX_CORES="$(yaml_get '.nginx_proxy.cores')"
  NGINX_WAN_IP="$(yaml_get '.nginx_proxy.wan_ip')"
  NGINX_IP="${NGINX_WAN_IP%/*}"   # strip prefix length (10.10.10.70/24 → 10.10.10.70)
  NGINX_WAN_GW="$(yaml_get '.nginx_proxy.wan_gw')"
  LXC_TEMPLATE="$(yaml_get '.nginx_proxy.lxc_template')"

  # --- Features ---
  export FIREWALL_ENABLED LOGGING_ENABLED AUDIT_ENABLED
  FIREWALL_ENABLED="$(yaml_get '.features.firewall_enabled')"
  LOGGING_ENABLED="$(yaml_get '.features.logging_enabled')"
  AUDIT_ENABLED="$(yaml_get '.features.audit_enabled')"

  validate_network_config
  audit_log "Loaded YAML config from $CONFIG_YAML"
}

load_legacy_config() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  warn "Loading legacy .env config (deprecated — migrate to infra.yaml)"
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
  audit_log "Loaded legacy config from $CONFIG_FILE"
}

load_config() {
  if [[ -f "$CONFIG_YAML" ]]; then
    load_yaml_config
  elif [[ -f "$CONFIG_FILE" ]]; then
    load_legacy_config
  else
    die "No config found. Create $CONFIG_YAML (see config/lab.env.example)"
  fi
}
