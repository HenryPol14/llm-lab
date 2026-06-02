#!/bin/bash
# Быстрые команды для проверки компонентов LLM VM (06-create-llm-vm.sh)
# Используйте эти команды для диагностики созданной VM

# ========== ПАРАМЕТРЫ ДЛЯ РЕДАКТИРОВАНИЯ ==========
VMID=110                    # ID вашей LLM VM (по умолчанию)
LLM_IP="10.10.10.50"       # IP адрес VM
GUEST_USER="ubuntu"        # Пользователь гостя

# ========== КОМАНДЫ ПРОВЕРКИ НА ХОСТЕ PROXMOX ==========

echo "=== ИНФОРМАЦИЯ О VM ==="
echo "Статус VM:"
qm status "$VMID"

  printf '\nКонфигурация VM:\n'
qm config "$VMID" | grep -E "^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig|hostpci):"

  printf '\nДиски VM:\n'
qm config "$VMID" | grep -E "^(scsi|ide|virtio)"

  printf '\nСетевые параметры VM:\n'
qm config "$VMID" | grep "^net0:"

printf '\nCloud-init параметры:\n'
qm config "$VMID" | grep -E "^(ciuser|cipassword|ipconfig|nameserver|searchdomain)"

  printf '\nВсе параметры VM (полный список):\n'
qm config "$VMID"

# ========== КОМАНДЫ ПРОВЕРКИ ВНУТРИ VM (если VM запущена) ==========

printf '\n\n=== ПРОВЕРКА ВНУТРИ VM ===\n'

echo "IP адрес VM:"
qm guest exec "$VMID" -- ip -4 addr show

  printf '\nДиски и разделы:\n'
qm guest exec "$VMID" -- lsblk

  printf '\nМонтирование дисков:\n'
qm guest exec "$VMID" -- df -h

  printf '\nСодержимое /mnt/data:\n'
qm guest exec "$VMID" -- ls -lah /mnt/data 2>/dev/null || echo "Директория не найдена"

  printf '\nФайл /etc/fstab:\n'
qm guest exec "$VMID" -- grep -E "^UUID" /etc/fstab 2>/dev/null || echo "UUID записей не найдено"

  printf '\nПользователь %s:\n' "$GUEST_USER"
qm guest exec "$VMID" -- id "$GUEST_USER"

  printf '\nПраво доступа на /mnt/data:\n'
qm guest exec "$VMID" -- stat /mnt/data 2>/dev/null | grep -E "^.*(Uid|Gid|Access):"

  printf '\nCloud-init статус:\n'
qm guest exec "$VMID" -- cloud-init status

  printf '\nКонфиг Docker (если установлен):\n'
qm guest exec "$VMID" -- cat /etc/docker/daemon.json 2>/dev/null || echo "daemon.json не найден"

  printf '\nДиск данных UUID в fstab:\n'
qm guest exec "$VMID" -- grep "/mnt/data" /etc/fstab

# ========== КОМАНДЫ SSH ДОСТУПА ==========

printf '\n\n=== SSH ДОСТУП ===\n'

echo "Проверка SSH подключения:"
ssh -o ConnectTimeout=5 -o BatchMode=yes "${GUEST_USER}@${LLM_IP}" "echo 'SSH работает'" && echo "✓ SSH успешно" || echo "✗ SSH не работает"

  printf '\nПодключение к VM:\n'
echo "ssh ${GUEST_USER}@${LLM_IP}"

# ========== БЫСТРЫЕ ОДНОИМЕННЫЕ КОМАНДЫ ==========

printf '\n\n=== БЫСТРЫЕ КОМАНДЫ ДЛЯ СКОПИРОВАНИЯ ===\n'
echo ""
echo "# Общая информация о VM"
echo "qm config \"$VMID\""
echo ""
echo "# Статус VM"
echo "qm status \"$VMID\""
echo ""
echo "# Диски VM"
echo "qm config \"$VMID\" | grep scsi"
echo ""
echo "# IP VM"
echo "qm guest exec \"$VMID\" -- hostname -I"
echo ""
echo "# Проверка /mnt/data"
echo "qm guest exec \"$VMID\" -- df -h /mnt/data"
echo ""
echo "# Проверка docker root"
echo "qm guest exec \"$VMID\" -- docker info | grep 'Docker Root Dir'"
echo ""
echo "# SSH подключение"
echo "ssh ${GUEST_USER}@${LLM_IP}"
