#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Быстрая диагностика Monitoring VM (созданной 07-create-monitoring-vm.sh).
# Выполняет проверки на Proxmox-хосте и (если VM запущена) внутри неё.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

VMID="${MONITORING_VMID:-120}"
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
GUEST_USER="${GUEST_USER:-ubuntu}"

echo "=== ИНФОРМАЦИЯ О VM ==="
echo "Статус VM:"
qm status "$VMID" || true

printf '\nКонфигурация VM:\n'
qm config "$VMID" | grep -E "^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig0):" || true

printf '\nСистемный диск:\n'
qm config "$VMID" | grep "^scsi0:" || true

printf '\nДиск данных:\n'
qm config "$VMID" | grep "^scsi1:" || true

printf '\nВсе параметры VM (полный список):\n'
qm config "$VMID" || true

# ========== ПРОВЕРКА ВНУТРИ VM (если VM запущена) ==========

printf '\n\n=== ПРОВЕРКА ВНУТРИ VM ===\n'

echo "IP адрес VM:"
qm guest exec "$VMID" -- ip -4 addr show || true

printf '\nМонтирование дисков:\n'
qm guest exec "$VMID" -- df -h || true

printf '\nСодержимое /mnt/data:\n'
qm guest exec "$VMID" -- ls -lah /mnt/data 2>/dev/null || echo "Директория не найдена"

printf '\nЗапись /mnt/data в /etc/fstab:\n'
qm guest exec "$VMID" -- grep "/mnt/data" /etc/fstab 2>/dev/null || echo "Запись не найдена"

printf '\nПользователь %s:\n' "$GUEST_USER"
qm guest exec "$VMID" -- id "$GUEST_USER" || true

printf '\nКонтейнеры Docker:\n'
qm guest exec "$VMID" -- docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker недоступен"

# ========== SSH ДОСТУП ==========

printf '\n\n=== SSH ДОСТУП ===\n'

echo "Проверка SSH подключения:"
ssh -o ConnectTimeout=5 -o BatchMode=yes "${GUEST_USER}@${MONITORING_IP}" "echo 'SSH работает'" \
  && echo "✓ SSH успешно" || echo "✗ SSH не работает"

printf '\nПодключение к VM:\n'
echo "ssh ${GUEST_USER}@${MONITORING_IP}"
