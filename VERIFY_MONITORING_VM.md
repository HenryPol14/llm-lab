# Проверка Monitoring VM (07-create-monitoring-vm.sh)

Этот документ содержит команды для верификации всех шагов, созданных скриптом `07-create-monitoring-vm.sh`.

## Переменные

Задайте значения в зависимости от вашей конфигурации:

```bash
VMID=120
MONITORING_IP="10.10.10.60"
GUEST_USER="ubuntu"
MONITORING_NAME="monitoring-vm"
```

## Проверка на хосте Proxmox

### Статус и конфигурация VM

```bash
qm status $VMID
qm config $VMID | grep -E "^(name|memory|cores|cpu|balloon|numa|agent):"
qm config $VMID | grep -E "^(scsi|net|ciuser|ipconfig0):"
```

### Проверка дисков

```bash
qm config $VMID | grep '^scsi0:'
qm config $VMID | grep '^scsi1:'
```

### Проверка Cloud-init

```bash
qm config $VMID | grep -E "^(ciuser|ipconfig0|nameserver):"
```

## Проверка внутри VM

### Сеть и IP

```bash
qm guest exec $VMID -- ip -4 addr show
qm guest exec $VMID -- ip addr | grep $MONITORING_IP
qm guest exec $VMID -- ip route
qm guest exec $VMID -- cat /etc/resolv.conf
```

### Диски и монтирование

```bash
qm guest exec $VMID -- lsblk
qm guest exec $VMID -- df -h
qm guest exec $VMID -- ls -lah /mnt/monitoring-data
qm guest exec $VMID -- grep '/mnt/monitoring-data' /etc/fstab
```

### Пользователь и права

```bash
qm guest exec $VMID -- id $GUEST_USER
qm guest exec $VMID -- stat /mnt/monitoring-data
```

### Cloud-init

```bash
qm guest exec $VMID -- cloud-init status
qm guest exec $VMID -- tail -50 /var/log/cloud-init-output.log
```

## SSH доступ

```bash
ssh -o ConnectTimeout=5 -o BatchMode=yes $GUEST_USER@$MONITORING_IP "echo 'SSH OK'"
```

## Быстрая проверка скриптами

```bash
scripts/verify-monitoring-vm.sh
scripts/check-monitoring-vm-quick.sh
```
