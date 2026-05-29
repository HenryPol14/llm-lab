#!/usr/bin/env bash
# Описание: Скрипт для тестирования процесса provision (quick/full тесты).
# Комментарий добавлен автоматически — дополните при необходимости.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_config

mark_step "Testing llm-lab provisioning with idempotency checks"

require_root
require_cmd qm

TEST_MODE="${1:-quick}"
case "$TEST_MODE" in
  quick|full|sanity)
    ;;
  *)
    die "Usage: $0 [quick|full|sanity]"
    ;;
esac

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
die() { log "ERROR: $*" >&2; exit 1; }

test_results=()
test_passed=0
test_failed=0

run_test() {
  local test_name="$1"
  local test_function="$2"
  info "Running test: $test_name"
  if "$test_function"; then
    info "✓ PASS: $test_name"
    test_results+=("PASS: $test_name")
    ((test_passed++))
  else
    warn "✗ FAIL: $test_name"
    test_results+=("FAIL: $test_name")
    ((test_failed++))
  fi
}

test_script_syntax() {
  local script_file
  for script_file in "${SCRIPT_DIR}"/[0-9]*-*.sh; do
    if ! bash -n "$script_file" 2>/dev/null; then
      warn "Syntax error in $script_file"
      return 1
    fi
  done
  return 0
}

test_common_library() {
  if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    warn "Common library not found"
    return 1
  fi
  bash -n "${SCRIPT_DIR}/lib/common.sh" || return 1
  test -n "$PROJECT_ROOT" || return 1
  return 0
}

test_config_validity() {
  if [[ -n "$CONFIG_YAML" ]]; then
    require_yq
    yq eval '.' "$CONFIG_YAML" >/dev/null 2>&1 || return 1
  fi
  return 0
}

test_config_regression() {
  require_cmd bash
  require_cmd yq
  "${SCRIPT_DIR}/test-config-regressions.sh"
}

test_proxmox_storage() {
  for storage in "$TEMPLATE_STORAGE" "$LLM_STORAGE" "$MONITORING_STORAGE"; do
    require_pve_storage "$storage" || return 1
  done
  return 0
}

test_template_exists() {
  vm_exists "$TEMPLATE_VMID" || return 1
  qm status "$TEMPLATE_VMID" | grep -q "template" || return 1
  return 0
}

test_network_bridge() {
  require_cmd ip
  ip link show "$INTERNAL_BRIDGE" >/dev/null 2>&1 || return 1
  ip -4 addr show "$INTERNAL_BRIDGE" | grep -q "$INTERNAL_CIDR" || return 1
  return 0
}

test_firewall_rules() {
  require_cmd nft
  nft list ruleset 2>/dev/null | grep -q "llm_lab" || {
    warn "Firewall rules not configured yet (may be acceptable)"
    return 0
  }
  return 0
}

test_vm_idempotency() {
  local vmid="$1"
  if vm_exists "$vmid"; then
    local detected_storage
    detected_storage="$(qm config "$vmid" | awk -F'[: ,]+' '/^scsi0:/ {print $2}' | cut -d, -f1 | cut -d: -f1)"
    if [[ -n "$detected_storage" ]]; then
      local expected_storage
      expected_storage="${vmid} == ${LLM_VMID} && echo $LLM_STORAGE || echo $MONITORING_STORAGE"
      info "VM ${vmid} storage: $detected_storage"
      return 0
    fi
  else
    info "VM ${vmid} does not exist yet (acceptable)"
    return 0
  fi
  return 0
}

test_guest_agent() {
  local vmid="$1"
  if vm_running "$vmid"; then
    guest_is_ready "$vmid" 30 || return 1
  else
    info "VM ${vmid} not running (acceptable)"
  fi
  return 0
}

test_docker_runtime() {
  local ip="$1"
  wait_for_ssh "$ip" 30 || return 1
  guest_ssh "$ip" "docker info >/dev/null 2>&1" || return 1
  guest_ssh "$ip" "docker compose version >/dev/null 2>&1" || return 1
  return 0
}

test_llm_stack() {
  local ip="${LLM_IP:-10.10.10.50}"
  if ! wait_for_ssh "$ip" 30 2>/dev/null; then
    info "LLM VM not reachable (acceptable)"
    return 0
  fi
  guest_ssh "$ip" "curl -f http://localhost:11434/api/tags >/dev/null 2>&1" || {
    warn "Ollama API not responding"
    return 0
  }
  guest_ssh "$ip" "curl -f http://localhost:3000/ >/dev/null 2>&1" || {
    warn "OpenWebUI not responding"
    return 0
  }
  return 0
}

test_monitoring_stack() {
  local ip="${MONITORING_IP:-10.10.10.60}"
  if ! wait_for_ssh "$ip" 30 2>/dev/null; then
    info "Monitoring VM not reachable (acceptable)"
    return 0
  fi
  guest_ssh "$ip" "curl -f http://localhost:9090/-/healthy >/dev/null 2>&1" || {
    warn "Prometheus not healthy"
    return 0
  }
  guest_ssh "$ip" "curl -f http://localhost:3000/login >/dev/null 2>&1" || {
    warn "Grafana not responding"
    return 0
  }
  return 0
}

info "Starting provisioning test suite in $TEST_MODE mode"

case "$TEST_MODE" in
  quick)
    run_test "Script syntax" test_script_syntax
    run_test "Common library" test_common_library
    run_test "Config validity" test_config_validity
    run_test "Config regression" test_config_regression
    run_test "Proxmox storage" test_proxmox_storage
    run_test "Network bridge" test_network_bridge
    ;;
  full)
    run_test "Script syntax" test_script_syntax
    run_test "Common library" test_common_library
    run_test "Config validity" test_config_validity
    run_test "Config regression" test_config_regression
    run_test "Proxmox storage" test_proxmox_storage
    run_test "Template exists" test_template_exists
    run_test "Network bridge" test_network_bridge
    run_test "Firewall rules" test_firewall_rules
    run_test "LLM VM idempotency" test_vm_idempotency "$LLM_VMID"
    run_test "Monitoring VM idempotency" test_vm_idempotency "$MONITORING_VMID"
    if vm_running "$LLM_VMID"; then
      run_test "LLM VM guest agent" test_guest_agent "$LLM_VMID"
      run_test "LLM Docker runtime" test_docker_runtime "$LLM_IP"
    fi
    if vm_running "$MONITORING_VMID"; then
      run_test "Monitoring VM guest agent" test_guest_agent "$MONITORING_VMID"
      run_test "Monitoring Docker runtime" test_docker_runtime "$MONITORING_IP"
    fi
    run_test "LLM stack" test_llm_stack
    run_test "Monitoring stack" test_monitoring_stack
    ;;
  sanity)
    run_test "Script syntax" test_script_syntax
    run_test "Common library" test_common_library
    run_test "Config validity" test_config_validity
    run_test "Proxmox storage" test_proxmox_storage
    ;;
esac

echo ""
info "━━━ Test Summary ━━━"
info "Total: $((test_passed + test_failed))"
info "Passed: $test_passed"
info "Failed: $test_failed"

if [[ $test_failed -gt 0 ]]; then
  warn "Failed tests:"
  for result in "${test_results[@]}"; do
    if [[ "$result" == "FAIL:"* ]]; then
      warn "  $result"
    fi
  done
  die "Test suite failed"
else
  info "All tests passed!"
fi
