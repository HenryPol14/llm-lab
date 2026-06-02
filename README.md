# LLM Lab on Proxmox — Production‑Ready Infrastructure

Самодостаточный набор скриптов для развертывания LLM‑стека и мониторинга на Proxmox‑хосте с фокусом на надежность, безопасность и производительность.

## Возможности

### Инфраструктура
- Автоматизированная provisioning pipeline на Proxmox VE
- Config‑driven дизайн (YAML конфигурация)
- Idempotent скрипты (повторяемые и детерминированные)
- Health‑checks после каждого шага

### Надежность
- Разделение системных и data дисков
- Audit‑logging всех операций
- Exhaustive тесты provisioning (`scripts/test-provisioning.sh`)
- Гибкое управление через флаги `--dry-run` и `--force`

### Безопасность
- Firewall whitelist (только нужные порты)
- Безопасность Docker контейнеров (read‑only, no-new-privileges)
- GPU passthrough с явной конфигурацией
- SSH‑ключи без паролей

### Производительность
- Docker storage overlay2 с log‑rotation
- CPU 4 ядра LLM 2 ядра резерв для контейнеров
- Отдельный data диск для LLM моделей и мониторинга данных

## Архитектура

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

Container 130: nginx-proxy
├─ Nginx reverse proxy
├─ WAN IP: 77.50.132.85
└─ Routes: 3000, 8080, 9090, 9093, 11434 → internal services
```

## Быстрый старт

### 1. Настройка конфигурации

```bash
# Создайте YAML конфигурацию
cp config/infra.yaml  # уже существует, отредактируйте
```

**Ключевые параметры:**
- `proxmox.host` — адрес Proxmox хоста
- `llm_vm.gpu_pci_addr` — адрес PCI‑устройства GPU (пустой = без GPU)
- `storage` — параметры storage pools
- `network` — bridge настройки и IP адреса
- `features.gpu_passthrough` — включение GPU passthrough

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
./scripts/test-provisioning.sh quick

# Полная проверка
./scripts/test-provisioning.sh full
```

## Доступные скрипты

| Скрипт | Описание | Требует root |
|--------|----------|--------------|
| `run-all.sh` | Главный оркестратор | Да |
| `01-install-proxmox-tools.sh` | Установка инструментов Proxmox | Да |
| `02-enable-iommu.sh` | IOMMU/VFIO для GPU | Да |
| `03-configure-network.sh` | Network bridge + firewall | Да |
| `04-download-cloud-image.sh` | Download Ubuntu cloud image | Да |
| `05-create-cloudinit-template.sh` | Создание VM template | Да |
| `06-create-llm-vm.sh` | Создание/обновление LLM VM | Да |
| `07-create-monitoring-vm.sh` | Создание/обновление monitoring VM | Да |
| `08-install-guest-runtime.sh` | Установка Docker runtime | Нет* |
| `09-install-nvidia-toolkit.sh` | NVIDIA Container Toolkit | Нет* |
| `10-deploy-llm-stack.sh` | Deploy Ollama + OpenWebUI | Нет* |
| `11-deploy-monitoring-stack.sh` | Deploy Prometheus + Grafana | Нет* |
| `12-audit-network.sh` | Аудит сетевой конфигурации | Нет |
| `13-deploy-nginx-proxy.sh` | Deploy nginx reverse proxy | Да |
| `14-setup-nft-rules.sh` | Настройка nftables firewall | Да |
| `bootstrap-remote.sh` | Bootstrap на удаленный хост | Нет |
| `check-llm-vm-quick.sh` | Быстрая проверка LLM VM | Нет |
| `check-monitoring-vm-quick.sh` | Быстрая проверка Monitoring VM | Нет |
| `monitor-llm.sh` | Статус и мониторинг | Нет |
| `run-all.sh` | Главный оркестратор | Да |
| `setup-logging.sh` | Audit logging setup | Нет |
| `test-config-regressions.sh` | тесты на регрессию конфигурации | Нет |
| `test-provisioning.sh` | Идемпотентность тесты | Безопасный |
| `verify-llm-vm.sh` | Верификация LLM VM | Нет |
| `verify-monitoring-vm.sh` | Верификация Monitoring VM | Нет |

\* Спрашивает root пароль для VM

## Доступные сервисы

| Сервис | URL | Аутентификация |
|--------|-----|----------------|
| OpenWebUI | `http://${LLM_IP}:3000` | guest / guest (смените!) |
| Ollama API | `http://${LLM_IP}:11434` | Без auth |
| Prometheus | `http://${MONITORING_IP}:9090` | Без auth |
| Grafana | `http://${MONITORING_IP}:3000` | admin / admin (смените!) |

**External access via nginx proxy:**
- `http://${PROXMOX_HOST}:3000` → Grafana (10.10.10.60:3000)
- `http://${PROXMOX_HOST}:8080` → OpenWebUI (10.10.10.50:3000)
- `http://${PROXMOX_HOST}:9090` → Prometheus (10.10.10.60:9090)
- `http://${PROXMOX_HOST}:9093` → Alertmanager (10.10.10.60:9093)
- `http://${PROXMOX_HOST}:11434` → Ollama API (10.10.10.50:11434)

## Безопасность

### Firewall Whitelist

**NFTABLES Rules:**
- LLM VM → только порты 11434, 3000 inbound
- Monitoring VM → только порты 9090, 3000 inbound
- Nginx Proxy → DNAT для внешних портов
- Интер‑VM трафик запрещен
- Outbound → только DNS (53, 443) к Google/Cloudflare
- Masquerade для внутренней подсети

### Docker Security

- `read_only: true` (где возможно)
- `no-new-privileges:true`
- Явные CPU/memory limits
- Healthchecks для всех сервисов

### GPU Passthrough

- Требуется явный `GPU_PCI_ADDR`
- Валидация: устройство свободно и не используется
- Возможность запуска без GPU

## Мониторинг

### Проверка состояния

```bash
# Статус VM
qm status 110  # LLM VM
qm status 120  # Monitoring VM
qm status 130  # Nginx Proxy

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

## Тестирование

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

### Проверка конфигурации

```bash
# Устранение camelCase в именах переменных при копировании YAML .env
./scripts/test-config-regressions.sh
```

## Обновление

### Обновление LLM stack

```bash
./scripts/08-install-guest-runtime.sh ${LLM_IP}
./scripts/09-install-nvidia-toolkit.sh ${LLM_IP}
./scripts/10-deploy-llm-stack.sh ${LLM_IP}
```

### Обновление Monitoring stack

```bash
./scripts/08-install-guest-runtime.sh ${MONITORING_IP}
./scripts/11-deploy-monitoring-stack.sh ${MONITORING_IP}
```

### Обновление Infrastructure

```bash
# Измените config/infra.yaml
# Затем перезапустите конкретные скрипты
./scripts/03-configure-network.sh
./scripts/06-create-llm-vm.sh
```

### Обновление Nginx Proxy

```bash
./scripts/13-deploy-nginx-proxy.sh
./scripts/14-setup-nft-rules.sh
```

## Конфигурация

### Основные параметры (YAML)

```yaml
llm_vm:
  vmid: 110
  ip: "10.10.10.50"
  memory_mb: 16384
  cores: 4
  data_disk_gb: 120
  gpu_pci_addr: ""  # "0000:01:00.0" для конкретного GPU

monitoring_vm:
  vmid: 120
  ip: "10.10.10.60"
  memory_mb: 8192
  cores: 2
  data_disk_gb: 80

nginx_proxy:
  ctid: 130
  ip: "10.10.10.70"
  wan_ip: "77.50.132.85"
  wan_gw: "77.50.132.65"

network:
  internal_bridge: "vmbr1"
  internal_cidr: "10.10.10.1/24"
  internal_subnet: "10.10.10.0/24"
  internal_gateway: "10.10.10.1"
  wan_bridge: "vmbr0"

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
| `SKIP_MODEL_PULL` | 0 | Пропустить загрузку моделей LLM |

## Troubleshooting

### VM не запускается

```bash
# Проверьте логи
qm config 110
qm monitor 110
tail -f /var/log/llm-lab/$(date +%Y%m%d).log

# Проверьте cloud-init
qm guest exec 110 -- cat /var/log/cloud-init-output.log
```

### Контейнеры не запускаются

```bash
ssh ubuntu@${LLM_IP}
cd /opt/llm-stack
docker compose logs
docker compose ps
```

### GPU не работает

```bash
# На хосте
lspci -D -d 10de:
qm config 110 | grep hostpci

# В VM
lspci | grep -i nvidia
nvidia-smi
```

### Firewall блокирует

```bash
# Проверьте правила
nft list ruleset
nft list table inet llm_lab

# Временно отключите firewall (не production!)
nft delete table inet llm_lab
```

### Nginx proxy не работает

```bash
# Проверьте контейнер
pct status 130
pct exec 130 -- systemctl status nginx

# Проверьте правила nftables
nft list table ip llm_lab_nat
```

## Подробности

### Idempotency

Все скрипты проверяют существование ресурсов перед созданием:
- VM создаются только если отсутствуют
- Диски форматируются только при явном подтверждении
- Docker compose обновляется (`--remove-orphans`)
- LXC контейнеры обновляются при изменении конфигурации

### Health-checks

- `guest_is_ready()` — ждет QEMU guest agent
- `wait_for_cloud_init()` — ждет cloud-init
- `check_system_running()` — проверяет systemd
- Docker healthchecks — curl к endpoint
- Валидация конфигурации — проверка YAML

### Audit logging

Все шаги логируются в `/var/log/llm-lab/`:
- Датированные файлы (`YYYYMMDD.log`)
- Logrotate: 30 дней, сжатие
- Метки: `STEP_START`, `SUCCESS`, `FAILURE`

### ShellCheck

Все скрипты проверены через ShellCheck:
- Статус: нет ошибок и предупреждений
- Исправлены все warning level проблемы
- Info level проблемы документированы и ожидаемы

## Contributing

При разработке:
- Следуйте bash strict mode (`set -Eeuo pipefail`)
- Добавляйте health‑checks после изменения
- Обновляйте `scripts/test-provisioning.sh`
- Проверяйте скрипты через ShellCheck
- Документируйте изменения в README

## Лицензия

MIT

## Статус developed

**Версия:** 3.0.0 (Production‑Ready)

**Особенности версии:**
- YAML конфигурация
- Nginx reverse proxy для внешнего доступа
- Nftables firewall с DNAT
- Обновленный provisioning pipeline
- Полный аудит безопасности
- Шелчек проверки всех скриптов
