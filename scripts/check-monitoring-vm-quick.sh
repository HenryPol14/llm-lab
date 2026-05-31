#!/usr/bin/env bash
# Быстрый справочник команд для проверки Monitoring VM

VMID=${MONITORING_VMID:-120}
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
GUEST_USER="${GUEST_USER:-ubuntu}"

echo "=== Проверка Monitoring VM ==="
echo "VMID: $VMID"
echo "Monitoring IP: $MONITORING_IP"
echo "Guest user: $GUEST_USER"

echo "\n# Статус VM"
echo "qm status $VMID"

echo "\n# Конфигурация VM"
echo "qm config $VMID | grep -E '^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig0):'"

echo "\n# Системный диск"
echo "qm config $VMID | grep '^scsi0:'"

echo "\n# Диск данных"
echo "qm config $VMID | grep '^scsi1:'"

echo "\n# IP внутри VM"
echo "qm guest exec $VMID -- ip -4 addr show"

echo "\n# Содержимое /mnt/data"
echo "qm guest exec $VMID -- ls -lah /mnt/data"

echo "\n# Запись fstab"
echo "qm guest exec $VMID -- grep '/mnt/data' /etc/fstab"

echo "\n# Проверка пользователя"
echo "qm guest exec $VMID -- id $GUEST_USER"

echo "\n# SSH доступ"
echo "ssh -o ConnectTimeout=5 $GUEST_USER@$MONITORING_IP 'echo SSH OK'"
