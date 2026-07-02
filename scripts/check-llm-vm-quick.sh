#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Быстрая диагностика LLM VM (созданной 06-create-llm-vm.sh).
# Выполняет проверки на Proxmox-хосте и (если VM запущена) внутри неё.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

VMID="${LLM_VMID:-110}"
LLM_IP="${LLM_IP:-10.10.10.50}"
GUEST_USER="${GUEST_USER:-ubuntu}"

echo "=== ИНФОРМАЦИЯ О VM ==="
echo "Статус VM:"
qm status "$VMID" || true

printf '\nКонфигурация VM:\n'
qm config "$VMID" | grep -E "^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig|hostpci):" || true

printf '\nДиски VM:\n'
qm config "$VMID" | grep -E "^(scsi|ide|virtio)" || true

printf '\nСетевые параметры VM:\n'
qm config "$VMID" | grep "^net0:" || true

printf '\nCloud-init параметры:\n'
qm config "$VMID" | grep -E "^(ciuser|cipassword|ipconfig|nameserver|searchdomain)" || true

printf '\nВсе параметры VM (полный список):\n'
qm config "$VMID" || true

# ========== ПРОВЕРКА ВНУТРИ VM (если VM запущена) ==========

printf '\n\n=== ПРОВЕРКА ВНУТРИ VM ===\n'

echo "IP адрес VM:"
qm guest exec "$VMID" -- ip -4 addr show || true

printf '\nДиски и разделы:\n'
qm guest exec "$VMID" -- lsblk || true

printf '\nМонтирование дисков:\n'
qm guest exec "$VMID" -- df -h || true

printf '\nСодержимое /mnt/data:\n'
qm guest exec "$VMID" -- ls -lah /mnt/data 2>/dev/null || echo "Директория не найдена"

printf '\nФайл /etc/fstab:\n'
qm guest exec "$VMID" -- grep -E "^UUID" /etc/fstab 2>/dev/null || echo "UUID записей не найдено"

printf '\nПользователь %s:\n' "$GUEST_USER"
qm guest exec "$VMID" -- id "$GUEST_USER" || true

printf '\nПрава доступа на /mnt/data:\n'
qm guest exec "$VMID" -- stat /mnt/data 2>/dev/null | grep -E "^.*(Uid|Gid|Access):" || true

printf '\nCloud-init статус:\n'
qm guest exec "$VMID" -- cloud-init status || true

printf '\nКонфиг Docker (если установлен):\n'
qm guest exec "$VMID" -- cat /etc/docker/daemon.json 2>/dev/null || echo "daemon.json не найден"

printf '\nКонтейнеры Docker:\n'
qm guest exec "$VMID" -- docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker недоступен"

# ========== SSH ДОСТУП ==========

printf '\n\n=== SSH ДОСТУП ===\n'

echo "Проверка SSH подключения:"
ssh -o ConnectTimeout=5 -o BatchMode=yes "${GUEST_USER}@${LLM_IP}" "echo 'SSH работает'" \
  && echo "✓ SSH успешно" || echo "✗ SSH не работает"

printf '\nПодключение к VM:\n'
echo "ssh ${GUEST_USER}@${LLM_IP}"
