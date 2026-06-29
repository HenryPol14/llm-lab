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
    └─ Services: nftables (NAT, DNAT, whitelist)

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
| `infra-install-proxmox-tools.sh` | Установка инструментов Proxmox (nftables) | Да |
| `infra-enable-iommu.sh` | IOMMU/VFIO для GPU | Да |
| `infra-configure-network.sh` | Network bridge + firewall | Да |
| `vm-download-cloud-image.sh` | Download Ubuntu cloud image | Да |
| `vm-create-cloudinit-template.sh` | Создание VM template | Да |
| `infra-setup-nft-rules.sh` | NAT, DNAT, whitelist nftables | Да |
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

| Сервис | VM | Локальный порт | Внешний (через nginx) | Аутентификация |
|--------|-----|----------------|----------------------|----------------|
| OpenWebUI | LLM (10.10.10.50) | 3000 | `https://77.50.132.85/` | guest / guest (смените!) |
| Ollama API | LLM (10.10.10.50) | 11434 | `https://77.50.132.85/ollama/` | Без auth |
| Prometheus | Monitoring (10.10.10.60) | 9090 | `https://77.50.132.85/prometheus/` | Без auth |
| Grafana | Monitoring (10.10.10.60) | 3000 | `https://77.50.132.85/grafana/` | admin / admin (смените!) |
| Alertmanager | Monitoring (10.10.10.60) | 9093 | `https://77.50.132.85/alertmanager/` | Без auth |
| Node Exporter | LLM (10.10.10.50) | 9100 | — | — |
| DCGM Exporter | LLM (10.10.10.50) | 9400 | — | — |

## 🔒 Безопасность

**Firewall Whitelist:**
- nftables единый ruleset (`inet llm_lab_filter`)
- HTTPS (443) через DNAT → nginx proxy (10.10.10.70)
- HTTP (80) перенаправляется на HTTPS
- OpenWebUI (3000), Ollama (11434) → LLM VM (10.10.10.50) через nginx
- Prometheus (9090), Grafana (3000), Alertmanager (9093) → Monitoring VM (10.10.10.60) через nginx
- Inter VM traffic запрещен (кроме разрешенного в firewall)
- Outbound NAT (masquerade) для интернет

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

### Обновление Network Firewall (nftables)

```bash
./scripts/infra-setup-nft-rules.sh
./scripts/infra-configure-network.sh
```

## 📝 Конфигурация

### Network (nftables)

Используется **nftables** (без iptables) для всех сетевых функций:
- **NAT:** `table ip llm_lab_nat` — masquerade для внутренней подсети
- **DNAT:** входящий трафик → nginx proxy (10.10.10.70)
- **Whitelist:** `table inet llm_lab_filter` — строгий фильтр запрета VM→VM

**DNAT порты (77.50.132.85 → 10.10.10.70 → внутренние сервисы):**
| Внешний порт | Целевой VM | Порт сервиса | Сервис |
|--------------|------------|--------------|--------|
| 8080 | LLM (10.10.10.50) | 3000 | Open WebUI |
| 3000 | Monitoring (10.10.10.60) | 3000 | Grafana |
| 9090 | Monitoring (10.10.10.60) | 9090 | Prometheus |
| 9093 | Monitoring (10.10.10.60) | 9093 | Alertmanager |
| 11434 | LLM (10.10.10.50) | 11434 | Ollama API |

### GPU usage

Для использования GPU:
- Установлен драйвер NVIDIA 565.57.01
- NVIDIA Container Toolkit настроен на Docker runtime
- Контейнеры получают доступ к GPU через `gpus: all` в docker-compose.yml
- Переменные окружения: `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility`

**Проверка GPU в контейнере:**
```bash
docker exec -it ollama nvidia-smi -L
docker exec -it ollama ollama list
```

**Проверка GPU usage:**
```bash
nvidia-smi          # на хосте — видно процессы
curl localhost:9400/metrics | grep -i gpu  # DCGM exporter
```

**Важно:** Ollama использует GPU только при вычислениях. Во время простоя GPU Util = 0% — это нормально.

### Основные параметры (YAML)

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

# Проверить GPU в контейнере
docker exec -it ollama nvidia-smi -L

# Проверить, что контейнер видит GPU (даже если не используется)
docker exec -it ollama ollama list

# GPU Util = 0% — нормально, если модель не загружается или Ollama просто запущен
# Для нагрузки запустите генерацию текста в Open WebUI
```

**Firewall блокирует:**
```bash
# Проверьте правила nftables
nft list ruleset
nft list table inet llm_lab_filter
nft list table ip llm_lab_nat

# Временно отключите firewall (не production!)
nft delete table inet llm_lab
nft delete table ip llm_lab_nat
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
**Сеть:** контейнер на INTERNAL_BRIDGE (vmbr1) с IP 10.10.10.70 — интернет через NAT.  
**Firewall:** nftables — единый ruleset для NAT, DNAT и whitelist (без iptables).  
**DNAT:** 77.50.132.85:PORT → 10.10.10.70:PORT (Grafana/ OpenWebUI/ Prometheus/ Alertmanager/ Ollama API).  
**fix_locale:** убирает warning setlocale перед установкой пакетов.
