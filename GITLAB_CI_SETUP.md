# GitLab CI/CD Setup Guide

## Настройка переменных среды (Secrets)

Для работы GitLab CI/CD необходимо добавить следующие переменные в настройки проекта:

### Обязательные переменные:

| KEY | VALUE | Type | Protected | Masked | Description |
|-----|-------|------|-----------|--------|-------------|
| `PROXMOX_HOST` | `77.50.132.85` | env_var | ❌ | ❌ | IP Proxmox хоста |
| `PROXMOX_USER` | `root` | env_var | ❌ | ❌ | Пользователь для доступа |
| `SSH_PRIVATE_KEY` | Содержимое `~/.ssh/ai-off_id_rsa` | env_var | ❌ | ✅ | Приватный SSH ключ |
| `SSH_HOST_KEY` | `$(ssh-keyscan -p 60022 77.50.132.85)` | env_var | ❌ | ❌ | Host key для проверки |

### Опциональные переменные:

| KEY | VALUE | Description |
|-----|-------|-------------|
| `LLM_IP` | `10.10.10.50` | Внутренний IP LLM VM |
| `MONITORING_IP` | `10.10.10.60` | Внутренний IP Monitoring VM |
| `NGINX_IP` | `10.10.10.70` | Внутренний IP nginx proxy |

## Быстрый запуск

Скрипт автоматической настройки:
```bash
export PROXMOX_HOST=77.50.132.85
export PROXMOX_USER=root
export SSH_PRIVATE_KEY="$(cat ~/.ssh/ai-off_id_rsa)"

./scripts/configure-gitlab-ci.sh
```

## Проверка настройки

После настройки переменных:

```bash
glab variable list
```

## GitLab CI/CD Workflow

### .gitlab-ci.yml структура:

1. **lint stage:**
   - `lint`: Проверка синтаксиса bash скриптов
   - `syntax_check`: Проверка синтаксиса foreach скрипта
   - `shellcheck`: Статический анализ (опционально)

2. **test stage:**
   - `test`: Запуск конфигурационных тестов

### Автоматические проверки при push:

- Проверка синтаксиса всех `.sh` файлов
- Проверка наличия `shellcheck` (если доступен)
- Проверка конфигурации проекта

### Ручной запуск pipeline:

```bash
glab pipeline trigger --branch=main
```

## Troubleshooting

### Pipeine не запускается:

1. Проверить, что `.gitlab-ci.yml` существует в root репозитория
2. Проверить, что в настройках проекта включен CI/CD
3. Убедиться, что все необходимые переменные настроены

### Доступ к Proxmox невозможен:

1. Проверить, что переменная `SSH_PRIVATE_KEY` содержит правильный ключ
2. Убедиться, что ключ не защищен паролем (или добавить `SSH_PASSPHRASE`)
3. Проверить, что хост `77.50.132.85` доступен из GitLab runners

## Конфигурация из README

После настройки GitLab CI/CD можно использовать для автоматического развертывания:

```bash
# Push to any branch to trigger pipeline
git push origin release

# Проверить статус pipeline
glab pipeline list

# Запустить вручную
glab pipeline trigger --branch=release
```

## Ссылки

- [GitLab CI/CD Documentation](https://docs.gitlab.com/ee/ci/)
- [GitLab Variables](https://docs.gitlab.com/ee/ci/variables/)
- [glab CLI](https://gitlab.com/gitlab-org/cli)
