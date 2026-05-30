#!/usr/bin/env bash
# Скрипт для верификации всех компонентов, созданных скриптом 06-create-llm-vm.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd qm

echo "═══════════════════════════════════════════════════════════════"
echo "Проверка VM LLM (VMID: ${LLM_VMID})"
echo "═══════════════════════════════════════════════════════════════"

# ========== ПРОВЕРКА НА ХОСТЕ PROXMOX ==========

echo ""
echo "📍 ПРОВЕРКА НА ХОСТЕ PROXMOX"
echo "───────────────────────────────────────────────────────────────"

# 1. Наличие VM
if vm_exists "$LLM_VMID"; then
  echo "✓ VM ${LLM_VMID} существует"
else
  echo "✗ VM ${LLM_VMID} не найдена"
  exit 1
fi

# 2. Статус VM
STATUS=$(qm status "$LLM_VMID" | awk '{print $2}')
echo "✓ Статус VM: $STATUS"

# 3. Имя VM
NAME=$(qm config "$LLM_VMID" | grep "^name:" | awk '{print $2}')
echo "✓ Имя VM: $NAME (ожидается: $LLM_NAME)"

# 4. Параметры железа
MEMORY=$(qm config "$LLM_VMID" | grep "^memory:" | awk '{print $2}')
CORES=$(qm config "$LLM_VMID" | grep "^cores:" | awk '{print $2}')
echo "✓ ОЗУ: ${MEMORY}MB (ожидается: ${LLM_MEMORY_MB}MB)"
echo "✓ Ядра: $CORES (ожидается: $LLM_CORES)"

# 5. CPU параметры
CPU=$(qm config "$LLM_VMID" | grep "^cpu:" | awk '{print $2}')
echo "✓ CPU: $CPU (ожидается: host)"

# 6. Balloon и NUMA
BALLOON=$(qm config "$LLM_VMID" | grep "^balloon:" | awk '{print $2}')
NUMA=$(qm config "$LLM_VMID" | grep "^numa:" | awk '{print $2}')
echo "✓ Balloon: $BALLOON (ожидается: 0)"
echo "✓ NUMA: $NUMA (ожидается: 1)"

# 7. Guest Agent
AGENT=$(qm config "$LLM_VMID" | grep "^agent:" | awk '{print $2}')
echo "✓ Guest Agent: $AGENT (ожидается: enabled=1)"

# 8. Системный диск
DISK_SCSI0=$(qm config "$LLM_VMID" | grep "^scsi0:")
if [[ -n "$DISK_SCSI0" ]]; then
  echo "✓ Системный диск (scsi0) присутствует"
  echo "  $DISK_SCSI0"
else
  echo "✗ Системный диск (scsi0) не найден"
fi

# 9. Диск данных
DISK_SCSI1=$(qm config "$LLM_VMID" | grep "^scsi1:")
if [[ -n "$DISK_SCSI1" ]]; then
  echo "✓ Диск данных (scsi1) присутствует"
  echo "  $DISK_SCSI1"
else
  echo "✗ Диск данных (scsi1) не найден"
fi

# 10. Сетевой интерфейс
NET0=$(qm config "$LLM_VMID" | grep "^net0:")
echo "✓ Сетевой интерфейс (net0):"
echo "  $NET0"

# 11. Cloud-init параметры
CIUSER=$(qm config "$LLM_VMID" | grep "^ciuser:" | awk '{print $2}')
IPCONFIG=$(qm config "$LLM_VMID" | grep "^ipconfig0:")
echo "✓ Cloud-init пользователь: $CIUSER (ожидается: $GUEST_USER)"
echo "✓ Cloud-init IP конфиг:"
echo "  $IPCONFIG"

# 12. GPU Passthrough (если включено)
if [[ "$GPU_PASSTHROUGH" == "true" ]]; then
  GPU=$(qm config "$LLM_VMID" | grep "^hostpci0:")
  if [[ -n "$GPU" ]]; then
    echo "✓ GPU Passthrough активен:"
    echo "  $GPU"
  else
    echo "⚠ GPU Passthrough должен быть активен, но не найден"
  fi
else
  echo "ℹ GPU Passthrough отключен в конфиге"
fi

# ========== ПРОВЕРКА ВНУТРИ VM ==========

if [[ "$STATUS" != "running" ]]; then
  echo ""
  echo "⚠ VM не запущена, пропуск проверок внутри VM"
  echo "Запустите VM командой: qm start ${LLM_VMID}"
  exit 0
fi

echo ""
echo "📍 ПРОВЕРКА ВНУТРИ VM"
echo "───────────────────────────────────────────────────────────────"

# 1. IP адрес
IP_CONFIG=$(qm guest exec "$LLM_VMID" -- ip -4 addr show 2>/dev/null | grep -E "inet " | tail -1)
echo "✓ IP конфигурация внутри VM:"
echo "  $IP_CONFIG"

# 2. Проверка наличия целевого IP
if qm guest exec "$LLM_VMID" -- ip addr show | grep -q "$LLM_IP"; then
  echo "✓ Целевой IP $LLM_IP присутствует"
else
  echo "✗ Целевой IP $LLM_IP не найден"
fi

# 3. Диски
echo "✓ Диски внутри VM:"
qm guest exec "$LLM_VMID" -- lsblk 2>/dev/null | head -10 || echo "  (не удалось получить информацию)"

# 4. Монтирование /mnt/llm-data
if qm guest exec "$LLM_VMID" -- test -d "/mnt/llm-data" 2>/dev/null; then
  echo "✓ Директория /mnt/llm-data существует"
  
  # Проверка подзаданий
  MOUNT_INFO=$(qm guest exec "$LLM_VMID" -- df -h /mnt/llm-data 2>/dev/null)
  echo "  $MOUNT_INFO" | tail -1
  
  # Проверка подпапок
  SUBDIRS=$(qm guest exec "$LLM_VMID" -- ls -la /mnt/llm-data/ 2>/dev/null | grep "^d")
  if echo "$SUBDIRS" | grep -q "ollama"; then
    echo "✓ Подпапка /mnt/llm-data/ollama существует"
  fi
  if echo "$SUBDIRS" | grep -q "models"; then
    echo "✓ Подпапка /mnt/llm-data/models существует"
  fi
  if echo "$SUBDIRS" | grep -q "docker"; then
    echo "✓ Подпапка /mnt/llm-data/docker существует"
  fi
else
  echo "✗ Директория /mnt/llm-data не найдена"
fi

# 5. Проверка fstab
echo "✓ Содержимое /etc/fstab (для /mnt/llm-data):"
qm guest exec "$LLM_VMID" -- grep "llm-data" /etc/fstab 2>/dev/null || echo "  (запись не найдена)"

# 6. Пользователь
if qm guest exec "$LLM_VMID" -- id "$GUEST_USER" >/dev/null 2>&1; then
  echo "✓ Пользователь $GUEST_USER существует"
  
  # Проверка прав на /mnt/llm-data
  OWNER=$(qm guest exec "$LLM_VMID" -- stat -c "%U:%G" /mnt/llm-data 2>/dev/null)
  echo "  Владелец /mnt/llm-data: $OWNER (ожидается: $GUEST_USER:$GUEST_USER)"
else
  echo "✗ Пользователь $GUEST_USER не найден"
fi

# 7. Docker конфигурация
if qm guest exec "$LLM_VMID" -- command -v docker >/dev/null 2>&1; then
  echo "✓ Docker установлен"
  
  # Проверка конфига daemon.json
  if qm guest exec "$LLM_VMID" -- test -f /etc/docker/daemon.json 2>/dev/null; then
    echo "✓ /etc/docker/daemon.json существует"
    DOCKER_ROOT=$(qm guest exec "$LLM_VMID" -- grep "data-root" /etc/docker/daemon.json 2>/dev/null || echo "не найдено")
    echo "  Docker root: $DOCKER_ROOT"
  fi
else
  echo "⚠ Docker не установлен или не доступен"
fi

# 8. Cloud-init статус
CLOUD_INIT=$(qm guest exec "$LLM_VMID" -- cloud-init status 2>/dev/null)
if echo "$CLOUD_INIT" | grep -q "done"; then
  echo "✓ Cloud-init завершен"
else
  echo "⚠ Cloud-init статус: $CLOUD_INIT"
fi

# ========== ПРОВЕРКА SSH ДОСТУПА ==========

echo ""
echo "📍 ПРОВЕРКА SSH ДОСТУПА"
echo "───────────────────────────────────────────────────────────────"

if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${GUEST_USER}@${LLM_IP}" "echo 'SSH OK'" >/dev/null 2>&1; then
  echo "✓ SSH доступ работает"
  echo "  ssh ${GUEST_USER}@${LLM_IP}"
else
  echo "✗ SSH доступ не работает или VM недоступна"
  echo "  Попробуйте: ssh ${GUEST_USER}@${LLM_IP}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✓ Проверка завершена"
echo "═══════════════════════════════════════════════════════════════"
