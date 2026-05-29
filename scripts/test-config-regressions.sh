#!/usr/bin/env bash
# Описание: Тесты регрессий конфигурации проекта.
# Комментарий добавлен автоматически — дополните при необходимости.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

FAILURES=0
PASS=0

run_test() {
  local name="$1"
  shift
  printf 'Running test: %s... ' "$name"
  if "$@"; then
    printf 'PASS\n'
    ((PASS++))
  else
    printf 'FAIL\n'
    ((FAILURES++))
  fi
}

assert() {
  local msg="$1"
  shift
  if ! "$@"; then
    die "$msg"
  fi
}

test_yaml_get_raw_values() {
  load_config
  local bridge
  bridge="$(yaml_get '.network.wan_bridge')"
  [[ "$bridge" == "vmbr0" ]]
}

test_yaml_strings_have_no_quotes() {
  load_config
  for var in INTERNAL_BRIDGE WAN_BRIDGE INTERNAL_SUBNET INTERNAL_CIDR INTERNAL_GATEWAY; do
    local value="${!var:-}"
    [[ -n "$value" ]] || return 1
    [[ "$value" != *"\""* ]] || return 1
  done
  return 0
}

test_nftables_rendering() {
  load_config
  local rendered
  rendered="$(nftables_whitelist_config)"

  [[ "$rendered" != *'""'* ]]
  [[ "$rendered" == *"oifname \"${WAN_BRIDGE}\""* ]]
  [[ "$rendered" == *"ip saddr ${INTERNAL_SUBNET}"* ]]
  [[ "$rendered" == *"ip daddr ${LLM_IP}"* ]]
  return 0
}

info "Starting config regression tests"
run_test "YAML raw output" test_yaml_get_raw_values
run_test "YAML variables contain no embedded quotes" test_yaml_strings_have_no_quotes
run_test "nftables rendering syntax" test_nftables_rendering

info "Regression test summary: $PASS passed, $FAILURES failed"
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
