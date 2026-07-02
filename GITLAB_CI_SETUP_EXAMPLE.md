# Пример настройки переменных GitLab CI/CD

## Обязательные переменные:

| KEY | VALUE | Type | Protected | Masked |
|-----|-------|------|-----------|--------|
| `PROXMOX_HOST` | `77.50.132.85` | env_var | ❌ | ❌ |
| `PROXMOX_USER` | `root` | env_var | ❌ | ❌ |
| `SSH_PRIVATE_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAACFwAAAAdzc2gtcnNhAAAA...-----END OPENSSH PRIVATE KEY-----` | env_var | ❌ | ✅ |
| `SSH_HOST_KEY` | `[77.50.132.85]:60022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOAKMFQUfPCApGv3wwyfUYWM7LCqwEj7QAVWgBakB/j5` | env_var | ❌ | ❌ |

### Как получить SSH_PRIVATE_KEY:

```bash
# На локальной машине
cat ~/.ssh/ai-off_id_rsa
```

### Как получить SSH_HOST_KEY:

```bash
# На локальной машине (используя известный ключ)
cat ~/.ssh/known_hosts | grep "77.50.132.85]:60022"
```

## Опциональные переменные:

| KEY | VALUE | Description |
|-----|-------|-------------|
| `LLM_IP` | `10.10.10.50` | Внутренний IP LLM VM |
| `MONITORING_IP` | `10.10.10.60` | Внутренний IP Monitoring VM |
| `NGINX_IP` | `10.10.10.70` | Внутренний IP nginx proxy |

## Быстрая настройка через glab:

```bash
# Установить переменные
glab variable set PROXMOX_HOST "77.50.132.85"
glab variable set PROXMOX_USER "root"
glab variable set SSH_PRIVATE_KEY "$(cat ~/.ssh/ai-off_id_rsa)" --masked --protected
glab variable set SSH_HOST_KEY "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOAKMFQUfPCApGv3wwyfUYWM7LCqwEj7QAVWgBakB/j5"

# Проверить
glab variable list
```

## Проверка pipeline после настройки:

```bash
# Запустить pipeline вручную
glab pipeline trigger --branch=release

# Проверить статус
glab pipeline list
```

##Troubleshooting:

### "No pipeline found for branch release"

- Убедитесь, что в репозитории есть `.gitlab-ci.yml` в корне
- Сделайте push изменений: `git push gitlab release`

### "Permission denied (publickey)"

- Проверьте, что SSH_PRIVATE_KEY скопирован без изменений
- Убедитесь, что ключ не защищен паролем
- Проверьте, что Proxmox хост доступен из сетей GitLab runners

## Ссылки:

- [GitLab CI/CD Variables](https://docs.gitlab.com/ee/ci/variables/)
- [glab CLI Documentation](https://gitlab.com/gitlab-org/cli)