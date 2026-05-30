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
qm status $VMID

echo -e "\nКонфигурация VM:"
qm config $VMID | grep -E "^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig|hostpci):"

echo -e "\nДиски VM:"
qm config $VMID | grep -E "^(scsi|ide|virtio)"

echo -e "\nСетевые параметры VM:"
qm config $VMID | grep "^net0:"

echo -e "\nCloud-init параметры:"
qm config $VMID | grep -E "^(ciuser|cipassword|ipconfig|nameserver|searchdomain)"

echo -e "\nВсе параметры VM (полный список):"
qm config $VMID

# ========== КОМАНДЫ ПРОВЕРКИ ВНУТРИ VM (если VM запущена) ==========

echo -e "\n\n=== ПРОВЕРКА ВНУТРИ VM ==="

echo "IP адрес VM:"
qm guest exec $VMID -- ip -4 addr show

echo -e "\nДиски и разделы:"
qm guest exec $VMID -- lsblk

echo -e "\nМонтирование дисков:"
qm guest exec $VMID -- df -h

echo -e "\nСодержимое /mnt/llm-data:"
qm guest exec $VMID -- ls -lah /mnt/llm-data 2>/dev/null || echo "Директория не найдена"

echo -e "\nФайл /etc/fstab:"
qm guest exec $VMID -- grep -E "^UUID" /etc/fstab 2>/dev/null || echo "UUID записей не найдено"

echo -e "\nПользователь $GUEST_USER:"
qm guest exec $VMID -- id $GUEST_USER

echo -e "\nПраво доступа на /mnt/llm-data:"
qm guest exec $VMID -- stat /mnt/llm-data 2>/dev/null | grep -E "^.*(Uid|Gid|Access):"

echo -e "\nCloud-init статус:"
qm guest exec $VMID -- cloud-init status

echo -e "\nКонфиг Docker (если установлен):"
qm guest exec $VMID -- cat /etc/docker/daemon.json 2>/dev/null || echo "daemon.json не найден"

echo -e "\nДиск данных UUID в fstab:"
qm guest exec $VMID -- grep "/mnt/llm-data" /etc/fstab

# ========== КОМАНДЫ SSH ДОСТУПА ==========

echo -e "\n\n=== SSH ДОСТУП ==="

echo "Проверка SSH подключения:"
ssh -o ConnectTimeout=5 -o BatchMode=yes $GUEST_USER@$LLM_IP "echo 'SSH работает'" && echo "✓ SSH успешно" || echo "✗ SSH не работает"

echo -e "\nПодключение к VM:"
echo "ssh $GUEST_USER@$LLM_IP"

# ========== БЫСТРЫЕ ОДНОИМЕННЫЕ КОМАНДЫ ==========

echo -e "\n\n=== БЫСТРЫЕ КОМАНДЫ ДЛЯ СКОПИРОВАНИЯ ==="
echo ""
echo "# Общая информация о VM"
echo "qm config $VMID"
echo ""
echo "# Статус VM"
echo "qm status $VMID"
echo ""
echo "# Диски VM"
echo "qm config $VMID | grep scsi"
echo ""
echo "# IP VM"
echo "qm guest exec $VMID -- hostname -I"
echo ""
echo "# Проверка /mnt/llm-data"
echo "qm guest exec $VMID -- df -h /mnt/llm-data"
echo ""
echo "# Проверка docker root"
echo "qm guest exec $VMID -- docker info | grep 'Docker Root Dir'"
echo ""
echo "# SSH подключение"
echo "ssh $GUEST_USER@$LLM_IP"
