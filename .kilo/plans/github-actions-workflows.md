# GitHub Actions CI/CD Workflow Plan

## Цель
Автоматизация тестирования, проверки синтаксиса и развертывания скриптов через GitHub Actions.

---

## Структура workflow

### 1. `.github/workflows/lint.yml` - Проверка скриптов

**Триггеры:**
- `push` на все ветки
- `pull_request`

**Jobs:**
1. **shellcheck** - статический анализ bash-скриптов
   - Использует `koalaman/shellcheck@stable`
   - Проверяет все `.sh` файлы в `scripts/`
   - Выдает ошибки при нарушениях

2. **bash-syntax** - проверка синтаксиса
   - Команда: `bash -n scripts/*.sh`
   - Проверяет корректность bash-синтаксиса

3. **bash-semicheck** - дополнительные проверки
   - Проверка переменных (обязательны `|| true` для потенциально неудачных команд)
   - Проверка закрывающих кавычек

---

### 2. `.github/workflows/test.yml` - Юнит-тесты

**Триггеры:**
- `push` на `main`
- `pull_request` на `main`
- `workflow_dispatch` (ручной запуск)

**Jobs:**
1. **syntax-test** - тест синтаксиса
   - Запускает `bash -n` для всех скриптов
   - Проверяет отсутствие синтаксических ошибок

2. **config-regression** - тесты регрессий
   - Запускает `deployment-test-config-regressions.sh`
   - Проверяет валидность YAML и переменных

3. **provisioning-quick** - быстрый тест provision
   - Запускает `deployment-test-provisioning.sh quick`
   - Базовая проверка работоспособности

---

### 3. `.github/workflows/deploy.yml` - Деплой

**Триггеры:**
- `push` на `main` (автоматически)
- `workflow_dispatch` (ручной запуск)

**Jobs:**
1. **ssh-connectivity** - проверка доступа к Proxmox
   - Использует `appleboy/ssh-action@v1`
   - Тестирует SSH-подключение к `${PROXMOX_HOST}`
   - Использует `PROXMOX_HOST`, `PROXMOX_USER` из secrets

2. **deploy-infrastructure** - развертывание инфраструктуры
   - Запускает скрипт на удалённом хосте
   - `./scripts/infra-install-proxmox-tools.sh`
   - `./scripts/infra-enable-iommu.sh`
   - `./scripts/infra-configure-network.sh`

3. **deploy-vms** - создание VM
   - `./scripts/vm-download-cloud-image.sh`
   - `./scripts/vm-create-cloudinit-template.sh`
   - `./scripts/vm-create-llm-vm.sh`
   - `./scripts/vm-create-monitoring-vm.sh`

4. **deploy-runtime** - установка runtime
   - `./scripts/deployment-install-guest-runtime-llm.sh`
   - `./scripts/deployment-install-nvidia-toolkit-llm.sh`
   - `./scripts/deployment-deploy-monitoring-stack.sh`

5. **verify-deployment** - верификация
   - `./scripts/deployment-check-llm-vm-quick.sh`
   - `./scripts/proxy-deploy-nginx-proxy.sh`
   - `./scripts/infra-setup-nft-rules.sh`

---

## Переменные среды (GitHub Secrets)

|_SECRET_NAME_ | _Description_ | _Required_ |
|--------------|---------------|------------|
| `PROXMOX_HOST` | IP или hostname Proxmox | YES |
| `PROXMOX_USER` | 用户 для SSH (обычно root) | YES |
| `SSH_PRIVATE_KEY` | Приватный SSH ключ | YES |
| `SSH_PUBLIC_KEY` | Публичный SSH ключ (для VM) | YES |

---

## Улучшения после внедрения

1. **Добавить `shellcheck` в `.github/workflows/lint.yml`**
   - Установить скрипт проверки
   - Настроить вывод ошибок

2. **Добавить проверку прав доступа**
   - Проверять, что `PROXMOX_HOST` доступен по SSH
   - Проверять права root на хосте

3. **Добавить артефакты**
   - Логи выполнения как артефакты
   - Ошибки в формате JUnit XML

4. **Добавить notify**
   - Уведомления в Discord/Telegram
   - Email при провале

---

## Пример workflow файла

```yaml
# .github/workflows/lint.yml
name: Lint Scripts

on:
  push:
    branches: [**]
  pull_request:
    branches: [main]

jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run ShellCheck
        uses: koalaman/shellcheck-disabled@v0.10.0
        with:
          filter_mode: nofilter
          path: scripts/
          exclude: SC2034,SC2154
```

---

## Приоритеты реализации

1. **High**: `lint.yml` - проверка синтаксиса (безопасность)
2. **High**: `test.yml` - модульные тесты (качество)
3. **Medium**: `deploy.yml` - деплой (автоматизация)
4. **Low**: notify + артефакты (удобство)

---

## Ссылки
- [GitHub Actions Docs](https://docs.github.com/en/actions)
- [ShellCheck](https://github.com/koalaman/shellcheck)
- [Proxmox API](https://pve.proxmox.com/pve-docs/api-viewer/index.html)
