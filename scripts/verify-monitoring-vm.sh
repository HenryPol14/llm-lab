#!/usr/bin/env bash
# Скрипт для верификации всех компонентов, созданных скриптом 11-create-monitoring-vm.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd qm

echo "═══════════════════════════════════════════════════════════════"
echo "Проверка Monitoring VM (VMID: ${MONITORING_VMID})"
echo "═══════════════════════════════════════════════════════════════"

guest_exec_raw() {
  qm guest exec "$MONITORING_VMID" -- "$@" 2>/dev/null
}

guest_exec() {
  local raw
  local status
  raw="$(guest_exec_raw "$@")"
  status="$?"
  parse_qm_guest_exec_output "$raw"
  if [[ "$raw" == *'"exitcode"'* ]]; then
    local remote_status
    remote_status="$(printf '%s\n' "$raw" | sed -n 's/.*"exitcode"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | tail -n1)"
    if [[ -n "$remote_status" ]]; then
      return "$remote_status"
    fi
  fi
  return "$status"
}

# ========== ПРОВЕРКА НА ХОСТЕ PROXMOX ==========

echo ""
echo "📍 ПРОВЕРКА НА ХОСТЕ PROXMOX"
echo "───────────────────────────────────────────────────────────────"

if vm_exists "$MONITORING_VMID"; then
  echo "✓ VM ${MONITORING_VMID} существует"
else
  echo "✗ VM ${MONITORING_VMID} не найдена"
  exit 1
fi

STATUS=$(qm status "$MONITORING_VMID" | awk '{print $2}')
echo "✓ Статус VM: $STATUS"

NAME=$(qm config "$MONITORING_VMID" | grep "^name:" | awk '{print $2}')
echo "✓ Имя VM: $NAME (ожидается: ${MONITORING_NAME:-})"

MEMORY=$(qm config "$MONITORING_VMID" | grep "^memory:" | awk '{print $2}')
CORES=$(qm config "$MONITORING_VMID" | grep "^cores:" | awk '{print $2}')
echo "✓ ОЗУ: ${MEMORY}MB (ожидается: ${MONITORING_MEMORY_MB:-})"
echo "✓ Ядра: $CORES (ожидается: ${MONITORING_CORES:-})"

CPU=$(qm config "$MONITORING_VMID" | grep "^cpu:" | awk '{print $2}')
echo "✓ CPU: $CPU (ожидается: host)"

BALLOON=$(qm config "$MONITORING_VMID" | grep "^balloon:" | awk '{print $2}')
NUMA=$(qm config "$MONITORING_VMID" | grep "^numa:" | awk '{print $2}')
echo "✓ Balloon: $BALLOON (ожидается: 0)"
echo "✓ NUMA: $NUMA (ожидается: 1)"

AGENT=$(qm config "$MONITORING_VMID" | grep "^agent:" | awk '{print $2}')
echo "✓ Guest Agent: $AGENT (ожидается: enabled=1)"

DISK_SCSI0=$(qm config "$MONITORING_VMID" | grep "^scsi0:")
if [[ -n "$DISK_SCSI0" ]]; then
  echo "✓ Системный диск (scsi0) присутствует"
  echo "  $DISK_SCSI0"
else
  echo "✗ Системный диск (scsi0) не найден"
fi

DISK_SCSI1=$(qm config "$MONITORING_VMID" | grep "^scsi1:")
if [[ -n "$DISK_SCSI1" ]]; then
  echo "✓ Диск данных (scsi1) присутствует"
  echo "  $DISK_SCSI1"
else
  echo "⚠ Диск данных (scsi1) не найден"
fi

echo "✓ Сетевой интерфейс (net0):"
qm config "$MONITORING_VMID" | grep "^net0:"

echo "✓ Cloud-init параметры:"
qm config "$MONITORING_VMID" | grep -E "^(ciuser|ipconfig0|nameserver):" || true

# ========== ПРОВЕРКА ВНУТРИ VM ==========

if [[ "$STATUS" != "running" ]]; then
  echo ""
  echo "⚠ VM не запущена, пропуск проверок внутри VM"
  echo "Запустите VM командой: qm start ${MONITORING_VMID}"
  exit 0
fi

echo ""
echo "📍 ПРОВЕРКА ВНУТРИ VM"
echo "───────────────────────────────────────────────────────────────"

IP_CONFIG=$(guest_exec ip -4 addr show 2>/dev/null | grep -E "inet " | tail -1)
echo "✓ IP конфигурация внутри VM:"
echo "  $IP_CONFIG"

if guest_exec ip addr show | grep -q "${MONITORING_IP:-}"; then
  echo "✓ Целевой IP ${MONITORING_IP} присутствует"
else
  echo "⚠ Целевой IP ${MONITORING_IP} не найден"
fi

echo ""
echo "✓ Диски внутри VM:"
guest_exec lsblk 2>/dev/null | head -15 || echo "  (не удалось получить информацию)"

echo ""
echo "✓ Монтирование /mnt/data:"
if guest_exec test -d /mnt/data 2>/dev/null; then
  echo "✓ Директория /mnt/data существует"
  guest_exec df -h /mnt/data 2>/dev/null
else
  echo "✗ Директория /mnt/data не найдена"
fi

echo ""
echo "✓ Запись в /etc/fstab для /mnt/data:"
guest_exec grep "/mnt/data" /etc/fstab 2>/dev/null || echo "  (запись не найдена)"

echo ""
echo "✓ Проверка пользователя ${GUEST_USER}:"
if guest_exec id "$GUEST_USER" >/dev/null 2>&1; then
  echo "✓ Пользователь $GUEST_USER существует"
  if guest_exec test -d "/mnt/data"; then
    OWNER=$(guest_exec stat -c "%U:%G" /mnt/data 2>/dev/null)
    echo "  Владелец /mnt/data: $OWNER (ожидается: $GUEST_USER:$GUEST_USER)"
  else
    echo "  Директория /mnt/data отсутствует, проверка владельца пропущена"
  fi
else
  echo "✗ Пользователь $GUEST_USER не найден"
fi

echo ""
echo "✓ Программное обеспечение внутри VM:"
guest_exec bash -lc 'command -v docker >/dev/null 2>&1 && echo "Docker installed" || echo "Docker not installed"'

CLOUD_INIT_STATUS=$(guest_exec cloud-init status 2>/dev/null || true)
if [[ "$CLOUD_INIT_STATUS" == *done* || "$CLOUD_INIT_STATUS" == *"status: done"* ]]; then
  echo "✓ Cloud-init завершен"
else
  echo "⚠ Cloud-init статус: $CLOUD_INIT_STATUS"
fi

echo ""
echo "📍 ПРОВЕРКА SSH ДОСТУПА"
echo "───────────────────────────────────────────────────────────────"
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${GUEST_USER}@${MONITORING_IP}" "echo 'SSH OK'" >/dev/null 2>&1; then
  echo "✓ SSH доступ работает"
else
  echo "✗ SSH доступ не работает"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✓ Проверка Monitoring VM завершена"
echo "══════════════════════════════════════════════════════════════="
