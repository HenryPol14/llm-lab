# Проверка компонентов LLM VM (vm-create-llm-vm.sh)

Этот документ содержит команды для верификации всех компонентов, которые должны быть созданы скриптом `vm-create-llm-vm.sh`.

## Предварительные переменные

Замените значения на ваши:
```bash
VMID=110                    # ID вашей LLM VM
LLM_IP="10.10.10.50"       # IP адрес VM
GUEST_USER="ubuntu"        # Пользователь гостя
LLM_NAME="llm-vm"          # Имя VM
```

## 1. Проверка на хосте Proxmox

### Базовая информация о VM

```bash
# Статус VM
qm status $VMID

# Конфигурация VM (краткая)
qm config $VMID | grep -E "^(name|memory|cores|cpu|balloon|numa|agent):"

# Все параметры VM (полная)
qm config $VMID
```

### Проверка характеристик железа

```bash
# Память (должна быть как LLM_MEMORY_MB)
qm config $VMID | grep "^memory:"

# Ядра (должны быть как LLM_CORES)
qm config $VMID | grep "^cores:"

# CPU (должно быть host)
qm config $VMID | grep "^cpu:"

# Balloon (должно быть 0)
qm config $VMID | grep "^balloon:"

# NUMA (должно быть 1)
qm config $VMID | grep "^numa:"

# Guest Agent (должно быть enabled=1)
qm config $VMID | grep "^agent:"
```

### Проверка дисков

```bash
# Все диски VM
qm config $VMID | grep -E "^(scsi|ide|virtio):"

# Системный диск (должен быть scsi0)
qm config $VMID | grep "^scsi0:"

# Диск данных (должен быть scsi1)
qm config $VMID | grep "^scsi1:"
```

### Проверка сетевых параметров

```bash
# Сетевой интерфейс (должен быть на внутреннем мосту)
qm config $VMID | grep "^net0:"

# Cloud-init параметры
qm config $VMID | grep -E "^(ciuser|ipconfig|nameserver):"
```

### Проверка GPU (если включен)

```bash
# GPU Passthrough конфигурация
qm config $VMID | grep "^hostpci0:"
```

## 2. Проверка внутри VM

### Перед проверками убедитесь, что VM запущена

```bash
# Запустить VM
qm start $VMID

# Подождать, пока VM будет готова
sleep 30
```

### IP и сеть

```bash
# IP адрес VM
qm guest exec $VMID -- ip -4 addr show

# Проверить наличие целевого IP
qm guest exec $VMID -- ip addr | grep $LLM_IP

# Маршруты и шлюз
qm guest exec $VMID -- ip route show

# DNS
qm guest exec $VMID -- cat /etc/resolv.conf
```

### Диски и монтирование

```bash
# Все диски и разделы
qm guest exec $VMID -- lsblk

# Информация о диске /dev/sdb
qm guest exec $VMID -- lsblk -f /dev/sdb

# Монтированные системы
qm guest exec $VMID -- df -h

# Размер /mnt/data
qm guest exec $VMID -- du -sh /mnt/data

# UUID разделов в fstab
qm guest exec $VMID -- grep -E "^UUID" /etc/fstab
```

### Содержимое /mnt/data

```bash
# Проверить наличие директории
qm guest exec $VMID -- test -d /mnt/data && echo "✓ Директория существует" || echo "✗ Директория не найдена"

# Содержимое директории
qm guest exec $VMID -- ls -lah /mnt/data

# Проверить подпапки
qm guest exec $VMID -- ls /mnt/data/{ollama,models,docker} 2>/dev/null && echo "✓ Все подпапки созданы"

# Владелец директории (должен быть ubuntu:ubuntu)
qm guest exec $VMID -- stat -c "%U:%G %a" /mnt/data
```

### Пользователь и права

```bash
# Информация о пользователе
qm guest exec $VMID -- id $GUEST_USER

# Члены группы docker (если установлен)
qm guest exec $VMID -- groups $GUEST_USER

# Подробная информация о /mnt/data
qm guest exec $VMID -- stat /mnt/data
```

### Cloud-init статус

```bash
# Статус cloud-init
qm guest exec $VMID -- cloud-init status

# Логи cloud-init
qm guest exec $VMID -- tail -50 /var/log/cloud-init-output.log
```

### Docker конфигурация

```bash
# Проверить, установлен ли Docker
qm guest exec $VMID -- command -v docker && echo "✓ Docker установлен" || echo "✗ Docker не найден"

# Версия Docker
qm guest exec $VMID -- docker --version

# Docker root directory
qm guest exec $VMID -- docker info | grep "Docker Root Dir"

# Содержимое /etc/docker/daemon.json
qm guest exec $VMID -- cat /etc/docker/daemon.json

# Статус Docker
qm guest exec $VMID -- systemctl status docker
```

## 3. SSH доступ

### Проверка SSH подключения

```bash
# Добавить ключ хоста
ssh-keyscan -H $LLM_IP >> ~/.ssh/known_hosts 2>/dev/null

# Тест SSH подключения
ssh -o ConnectTimeout=5 $GUEST_USER@$LLM_IP "echo 'SSH works!'"

# Интерактивное подключение
ssh $GUEST_USER@$LLM_IP

# Проверить SSH на хосте
ssh $GUEST_USER@$LLM_IP "cat ~/.ssh/authorized_keys" 2>/dev/null | head -1
```

## 4. Комплексная проверка (один скрипт)

Запустите скрипт верификации:

```bash
# Автоматическая проверка всех компонентов
scripts/vm-verify-llm-vm.sh

# Или быстрые команды
scripts/deployment-check-llm-vm-quick.sh
```

## 5. Список проверяемых компонентов

✅ **На хосте Proxmox:**
- [ ] VM существует и имеет ID: $VMID
- [ ] Имя VM: $LLM_NAME
- [ ] Память: $LLM_MEMORY_MB MB
- [ ] Ядра: $LLM_CORES
- [ ] CPU: host
- [ ] Balloon: 0
- [ ] NUMA: 1
- [ ] Guest Agent: enabled
- [ ] Системный диск (scsi0)
- [ ] Диск данных (scsi1)
- [ ] Сетевой интерфейс на внутреннем мосту
- [ ] Cloud-init параметры установлены
- [ ] GPU Passthrough (если включен)

✅ **Внутри VM:**
- [ ] IP адрес: $LLM_IP
- [ ] Диск /dev/sdb присутствует
- [ ] /mnt/data смонтирован
- [ ] Подпапки: ollama, models, docker
- [ ] Владелец: $GUEST_USER:$GUEST_USER
- [ ] Записи в /etc/fstab
- [ ] Cloud-init завершен
- [ ] Docker установлен и конфигурирован
- [ ] Docker root: /mnt/data/docker

✅ **SSH доступ:**
- [ ] SSH подключение работает
- [ ] SSH ключи настроены
- [ ] Пользователь может выполнять команды

## 6. Типичные проблемы и их решение

### VM не запущена
```bash
# Запустить VM
qm start $VMID

# Подождать готовности
qm guest exec $VMID -- echo "Проверка"
```

### Cloud-init не завершен
```bash
# Посмотреть статус
qm guest exec $VMID -- cloud-init status

# Просмотреть логи
qm guest exec $VMID -- tail -100 /var/log/cloud-init-output.log
```

### /mnt/data не смонтирован
```bash
# Проверить диск
qm guest exec $VMID -- lsblk

# Проверить fstab
qm guest exec $VMID -- cat /etc/fstab

# Попытаться смонтировать вручную
qm guest exec $VMID -- sudo mount -a
```

### SSH не работает
```bash
# Проверить SSH сервер
qm guest exec $VMID -- sudo systemctl status ssh

# Проверить файрволл
qm guest exec $VMID -- sudo ufw status

# Перезагрузить VM
qm shutdown $VMID
qm start $VMID
```

### Docker не работает
```bash
# Проверить статус
qm guest exec $VMID -- sudo systemctl status docker

# Посмотреть ошибки
qm guest exec $VMID -- sudo journalctl -u docker -n 20

# Перезагрузить Docker
qm guest exec $VMID -- sudo systemctl restart docker
```

## Справка

- **qm status $VMID** — показать статус VM
- **qm config $VMID** — показать конфигурацию VM
- **qm guest exec $VMID -- КОМАНДА** — выполнить команду внутри VM
- **qm start $VMID** — запустить VM
- **qm shutdown $VMID** — выключить VM
- **qm stop $VMID** — остановить VM (принудительно)
