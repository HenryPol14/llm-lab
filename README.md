# LLM Lab on Proxmox

Самодостаточный набор скриптов для развертывания LLM-стека и мониторинга на Proxmox-хосте `77.50.132.85`.

Проект объединяет наработки из:

- `HenryPol14/llm-lab`: простой workflow `cloud-init -> template -> VM -> monitor`.
- `HenryPol14/proxmox-llm-lab`: идемпотентные Proxmox-скрипты, GPU passthrough, отдельная monitoring VM и network audit.

## Что разворачивается

- Proxmox host bootstrap:
  - нужные пакеты;
  - IOMMU/VFIO для GPU passthrough;
  - Ubuntu cloud image;
  - cloud-init template.
- VM `llm-server`:
  - Docker;
  - NVIDIA Container Toolkit;
  - Ollama;
  - Open WebUI;
  - node-exporter;
  - NVIDIA DCGM exporter.
- VM `monitoring-vm`:
  - Prometheus;
  - Grafana;
  - Alertmanager;
  - Blackbox exporter;
  - готовый Grafana datasource и dashboard.

## Быстрый старт

1. Скопируйте пример конфига:

```bash
cp config/lab.env.example config/lab.env
```

2. Проверьте значения в `config/lab.env`, особенно:

- `PROXMOX_HOST=77.50.132.85`
- `PROXMOX_USER=root`
- `SSH_PUBLIC_KEY`
- `TEMPLATE_STORAGE=SSD-VMs`
- `LLM_STORAGE=SSD-VMs`
- `MONITORING_STORAGE=local-lvm`
- `WAN_BRIDGE`
- `INTERNAL_BRIDGE`
- IP-адреса VM.

Storage разделён намеренно: template и `llm-server` создаются на `SSD-VMs`, а `monitoring-vm` создаётся на `local-lvm`.

3. Запустите bootstrap с локальной машины:

```bash
./scripts/bootstrap-remote.sh
```

Скрипт отправит проект на Proxmox в `/root/llm-lab`, затем выполнит `scripts/run-all.sh` уже на хосте.

## Ручной запуск на Proxmox

```bash
cd /root/llm-lab
cp config/lab.env.example config/lab.env
vi config/lab.env
./scripts/run-all.sh
```

## Проверка состояния

```bash
./scripts/monitor-llm.sh
./scripts/12-audit-network.sh
```

После успешного запуска:

- Open WebUI: `http://10.10.10.50:3000`
- Ollama API: `http://10.10.10.50:11434`
- Prometheus: `http://10.10.10.60:9090`
- Grafana: `http://10.10.10.60:3000`

По умолчанию Grafana: `admin` / `admin`. Смените пароль после первого входа.
