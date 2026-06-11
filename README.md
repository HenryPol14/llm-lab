# LLM Lab on Proxmox - Production‑Ready Infrastructure v3.0.0

Самодостаточный набор скриптов для развертывания LLM‑стека и мониторинга на Proxmox‑хосте с фокусом на надежность, безопасность и производительность.

## 📋 Возможности

**Инфраструктура:**
- Автоматизированная provisioning pipeline на Proxmox VE
- Config‑driven дизайн (YAML конфигурация)
- Idempotent скрипты (повторяемые и детерминированные)
- Health‑checks после каждого шага

**Надежность:**
- Разделение системных и data дисков
- Audit‑logging всех операций
- Exhaustive тесты provisioning (`scripts/test-provisioning.sh`)
- Гибкое управление через флаги `--dry-run` и `--force`

**Безопасность:**
- Firewall whitelist (только нужные порты)
- Безопасность Docker контейнеров (read-only, no-new-privileges)
- GPU passthrough с явной конфигурацией
- SSH-ключи без паролей

**Производительность:**
- Docker storage overlay2 с log-rotation
- CPU 4 ядра LLM 2 ядра резерв для контейнеров
- Отдельный data диск для LLM моделей и мониторинга данных

## 🏗️ Архитектура

```
Proxmox Host (Ubuntu)
├─ Network: vmbr0 (WAN) / vmbr1 (Internal 10.10.10.1/24)
├─ Storage: SSD-VMs / local-lvm
└─ Services: nftables firewall (whitelist only)

VM 110: llm-server
├─ Docker: Ollama + OpenWebUI + Monitoring exporters
├─ GPU: Optional PCI passthrough
└─ Mounts: /mnt/data/ollama, /mnt/data/models, /mnt/data/docker

VM 120: monitoring-vm
├─ Docker: Prometheus + Grafana + Alertmanager
└─ Mounts: /mnt/data/prometheus, /mnt/data/grafana
```

## 🚀 Быстрый старт

### 1. Настройка конфигурации

```bash
# Создайте YAML конфигурацию
cp config/infra.yaml  # уже существует, отредактируйте

# Или старый стиль (устаревший)
cp config/lab.env.example config/lab.env
```

**Ключевые параметры:**
- `proxmox.host` – адрес Proxmox хоста
- `llm_vm.gpu_pci_addr` – адрес PCI‑устройства GPU (пустой = без GPU)
- `storage` – параметры storage pools
- `network` – bridge настройки и IP адреса
- `features.gpu_passthrough` – включение GPU passthrough

### 2. Bootstrap на локальной машине

```bash
./scripts/bootstrap-remote.sh
```

### 3. На Proxmox хосте (ручной режим)

```bash
cd /root/llm-lab
./scripts/run-all.sh
```

### 4. Тестирование

```bash
# Быстрая проверка
./scripts/deployment-test-provisioning.sh quick

# Полная проверка
./scripts/deployment-test-provisioning.sh full
```

## 🔧 Доступные скрипты

| Скрипт | Описание | Требует root |
|--------|----------|--------------|
| `run-all.sh` | Главный оркестратор | Да |
| `infra-install-proxmox-tools.sh` | Установка инструментов Proxmox | Да |
| `infra-enable-iommu.sh` | IOMMU/VFIO для GPU | Да |
| `infra-configure-network.sh` | Network bridge + firewall | Да |
| `vm-download-cloud-image.sh` | Download Ubuntu cloud image | Да |
| `vm-create-cloudinit-template.sh` | Создание VM template | Да |
| `vm-create-llm-vm.sh` | Создание/обновление LLM VM | Да |
| `vm-create-monitoring-vm.sh` | Создание/обновление monitoring VM | Да |
| `deployment-install-guest-runtime-llm.sh` | Установка Docker runtime (LLM) | Нет* |
| `deployment-install-nvidia-toolkit-llm.sh` | NVIDIA Container Toolkit (LLM) | Нет* |
| `deployment-deploy-monitoring-stack.sh` | Deploy Prometheus + Grafana | Нет* |
| `proxy-deploy-nginx-proxy.sh` | Deploy nginx reverse proxy | Нет |
| `vm-verify-llm-vm.sh` | Проверка LLM VM | Безопасный |
| `vm-verify-monitoring-vm.sh` | Проверка Monitoring VM | Безопасный |
| `deployment-check-llm-vm-quick.sh` | Быстрая проверка VM | Безопасный |
| `infra-setup-logging.sh` | Audit logging setup | Нет |

\* Спрашивает root пароль для VM

## 🌐 Доступные сервисы

| Сервис | URL | Аутентификация |
|--------|-----|----------------|
| OpenWebUI | `http://${LLM_IP}:3000` | guest / guest (смените!) |
| Ollama API | `http://${LLM_IP}:11434` | Без auth |
| Prometheus | `http://${MONITORING_IP}:9090` | Без auth |
| Grafana | `http://${MONITORING_IP}:3000` | admin / admin (смените!) |

## 🔒 Безопасность

**Firewall Whitelist:**
- LLM VM → только порты 11434, 3000 inbound
- Monitoring VM → только порты 9090, 3000 inbound
- Интер‑VM трафик запрещен
- Outbound → только DNS (53, 443) к Google/Cloudflare

**Docker Security:**
- `read_only: true` (где возможно)
- `no-new-privileges:true`
- Явные CPU/memory limits
- Healthchecks для всех сервисов

**GPU Passthrough:**
- Требуется явный `GPU_PCI_ADDR`
- Валидация: устройство свободно и не используется
- Возможность запуска без GPU

## 📊 Мониторинг

### Проверка состояния

```bash
# Статус VM
qm status 110  # LLM VM
qm status 120  # Monitoring VM

# Статус контейнеров
ssh ubuntu@${LLM_IP} "cd /opt/llm-stack && docker compose ps"
ssh ubuntu@${MONITORING_IP} "cd /opt/monitoring-stack && docker compose ps"

# Журнал
tail -f /var/log/llm-lab/$(date +%Y%m%d).log
```

### Метрики

- **Ollama:** `http://${LLM_IP}:11434/api/tags`
- **Metrics:** `http://${LLM_IP}:9100/metrics` (node), `:9400/metrics` (DCGM)
- **Prometheus:** `http://${MONITORING_IP}:9090`

## 🧪 Тестирование

### Idempotency тесты

```bash
# Быстрая проверка (синтаксис + конфиг)
./scripts/test-provisioning.sh quick

# Полная проверка (включая работающие VM)
./scripts/test-provisioning.sh full

# Только sanity проверка
./scripts/test-provisioning.sh sanity
```

### Dry-run режим

```bash
DRY_RUN=true ./scripts/run-all.sh  # Не выполняет команды, только выводит
```

### Force rebuild

```bash
FORCE_REBUILD=1 ./scripts/run-all.sh  # Пересоздает VM
```

## 🔄 Обновление

### Обновление LLM stack

```bash
./scripts/deployment-install-guest-runtime-llm.sh ${LLM_IP}
./scripts/deployment-install-nvidia-toolkit-llm.sh ${LLM_IP}
./scripts/deployment-deploy-monitoring-stack.sh ${LLM_IP}
```

### Обновление Monitoring stack

```bash
./scripts/deployment-install-guest-runtime-monitoring.sh ${MONITORING_IP}
```

### Обновление Infrastructure

```bash
# Измените config/infra.yaml
# Затем перезапустите конкретные скрипты
./scripts/infra-configure-network.sh
./scripts/vm-create-llm-vm.sh
```

## 📝 Конфигурация

### Основные параметры (YAML)

```yaml
llm_vm:
  vmid: 110
  ip: "10.10.10.50"
  memory_mb: 16384
  cores: 4
  data_disk_gb: 120
  gpu_pci_addr: ""  # "0000:01:00.0" для конкретного GPU

network:
  internal_bridge: "vmbr1"
  internal_cidr: "10.10.10.1/24"

features:
  gpu_passthrough: false
  firewall_enabled: true
  audit_enabled: true
```

### Переменные окружения

| Переменная | По умолчанию | Описание |
|-----------|---------------|----------|
| `DRY_RUN` | false | Не выполнять команды |
| `FORCE_REBUILD` | 0 | Удалить существующие VM |
| `REFORMAT_DATA_DISK` | 0 | Отформатировать data диски |
| `ENABLE_AUDIT_LOG` | true | Вести audit журнал |
| `LOGGING_ENABLED` | true | Docker log rotation |

## 🐛 Troubleshooting

**VM не запускается:**
```bash
# Проверьте логи
qm config 110
qm monitor 110
tail -f /var/log/llm-lab/$(date +%Y%m%d).log

# Проверьте cloud-init
qm guest exec 110 -- cat /var/log/cloud-init-output.log
```

**Контейнеры не запускаются:**
```bash
ssh ubuntu@${LLM_IP}
cd /opt/llm-stack
docker compose logs
docker compose ps
```

**GPU не работает:**
```bash
# На хосте
lspci -D -d 10de:
qm config 110 | grep hostpci

# В VM
lspci | grep -i nvidia
nvidia-smi
```

**Firewall блокирует:**
```bash
# Проверьте правила
nft list ruleset
nft list table inet llm_lab

# Временно отключите firewall (не production!)
nft delete table inet llm_lab
```

## 📚 Подробности

### Idempotency

Все скрипты проверяют существование ресурсов перед созданием:
- VM создаются только если отсутствуют
- Диски форматируются только при явном подтверждении
- Docker compose обновляется (`--remove-orphans`)

### Health-checks

- `guest_is_ready()` – ждет QEMU guest agent
- `wait_for_cloud_init()` – ждет cloud-init
- `check_system_running()` – проверяет systemd
- Docker healthchecks – curl к endpoint

### Audit logging

Все шаги логируются в `/var/log/llm-lab/`:
- Датированные файлы (`YYYYMMDD.log`)
- Logrotate: 30 дней, сжатие
- Метки: `STEP_START`, `SUCCESS`, `FAILURE`

## 🤝 Contributing

При разработке:
- Следуйте bash strict mode (`set -Eeuo pipefail`)
- Добавляйте health‑checks после изменения
- Обновляйте `scripts/test-provisioning.sh`
- Документируйте изменения в README

## 📄 Лицензия

MIT

## ⚖️ Гарантии

**Critical Issues:**
- ❌ Data disk formatting без подтверждения → ✅ Исправлено
- ❌ Docker data migration без stop → ✅ Исправлено
- ❌ GPU auto‑detect conflict → ✅ Исправлено
- ❌ Firewall allow all → ✅ Исправлено

**Important Issues:**
- ❌ Нет health‑checks → ✅ Добавлено
- ❌ Нет idempotency → ✅ Реализовано
- ❌ Нет логирования → ✅ Реализовано

**Refactoring:**
- ✅ Config‑driven (YAML)
- ✅ Разделение конфигурации и кода
- ✅ Тесты provisioning
- ✅ Dry‑run и force флаги

---
**Статус:** Production‑Ready (v3.0.0)  
**Сеть:** контейнер теперь на INTERNAL_BRIDGE (vmbr1) с IP 10.10.10.70 — интернет через NAT хоста, без конфликта IP.  
**Новая функция:** setup_dnat настраивает на Proxmox хосте проброс портов 77.50.132.85:PORT → 10.10.10.70:PORT через iptables PREROUTING + MASQUERADE.  
**fix_locale:** убирает warning setlocale перед установкой пакетов.
