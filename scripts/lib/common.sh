#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
die() { log "ERROR: $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  log "ERROR: ${BASH_SOURCE[1]:-script} failed at line ${line_no} with exit code ${exit_code}" >&2
  exit "$exit_code"
}
trap on_error ERR

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
  else
    warn "Config file not found: $CONFIG_FILE. Using defaults from scripts."
  fi
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_pve_storage() {
  local storage="$1"
  require_cmd pvesm
  pvesm status | awk 'NR > 1 {print $1}' | grep -qxF "$storage" || die "Proxmox storage not found: $storage"
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

wait_for_guest_agent() {
  local vmid="$1"
  local timeout="${2:-180}"
  local waited=0
  info "Waiting for QEMU Guest Agent in VM ${vmid}"
  until qm guest exec "$vmid" -- uptime >/dev/null 2>&1; do
    sleep 3
    waited=$((waited + 3))
    if ((waited >= timeout)); then
      die "QEMU Guest Agent did not become ready in VM ${vmid} after ${timeout}s"
    fi
  done
}

normalize_gb() {
  local value="$1"
  value="${value%G}"
  value="${value%GB}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid disk size: $1"
  echo "$value"
}

guest_ssh() {
  local host="$1"
  shift
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  # shellcheck disable=SC2086
  ssh ${opts} "${GUEST_USER:-ubuntu}@${host}" "$@"
}

wait_for_ssh() {
  local host="$1"
  local timeout="${2:-180}"
  local waited=0
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  info "Waiting for SSH on ${host}"
  until ssh ${opts} -o ConnectTimeout=5 "${GUEST_USER:-ubuntu}@${host}" true >/dev/null 2>&1; do
    sleep 5
    waited=$((waited + 5))
    if ((waited >= timeout)); then
      die "SSH did not become ready on ${host} after ${timeout}s"
    fi
  done
}
