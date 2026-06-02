#!/usr/bin/env bash
# Быстрый справочник команд для проверки Monitoring VM

VMID=${MONITORING_VMID:-120}
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
GUEST_USER="${GUEST_USER:-ubuntu}"

echo "=== Проверка Monitoring VM ==="
echo "VMID: $VMID"
echo "Monitoring IP: $MONITORING_IP"
echo "Guest user: $GUEST_USER"

printf '\n# Статус VM\n'
echo "qm status \"$VMID\""

printf '\n# Конфигурация VM\n'
echo "qm config \"$VMID\" | grep -E '^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig0):'"

printf '\n# Системный диск\n'
echo "qm config \"$VMID\" | grep '^scsi0:'"

printf '\n# Диск данных\n'
echo "qm config \"$VMID\" | grep '^scsi1:'"

printf '\n# IP внутри VM\n'
echo "qm guest exec \"$VMID\" -- ip -4 addr show"

printf '\n# Содержимое /mnt/data\n'
echo "qm guest exec \"$VMID\" -- ls -lah /mnt/data"

printf '\n# Запись fstab\n'
echo "qm guest exec \"$VMID\" -- grep '/mnt/data' /etc/fstab"

printf '\n# Проверка пользователя\n'
echo "qm guest exec \"$VMID\" -- id \"$GUEST_USER\""

printf '\n# SSH доступ\n'
echo "ssh -o ConnectTimeout=5 \"${GUEST_USER}@${MONITORING_IP}\" 'echo SSH OK'"
