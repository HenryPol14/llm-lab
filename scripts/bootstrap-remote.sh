#!/usr/bin/env bash
# Описание: Скрипт для первоначальной настройки репозитория и окружения на удалённом хосте.
# Комментарий добавлен автоматически — дополните при необходимости.
set -Eeuo pipefail                                       # безопасный режим исполнения bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  echo "Copy config/lab.env.example to config/lab.env and adjust it first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

PROXMOX_HOST="${PROXMOX_HOST:-77.50.132.85}"
PROXMOX_USER="${PROXMOX_USER:-root}"
REMOTE_DIR="${REMOTE_DIR:-/root/llm-lab}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"

command -v ssh >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "scp not found" >&2; exit 1; }

echo "Preparing ${PROXMOX_USER}@${PROXMOX_HOST}:${REMOTE_DIR}"
# shellcheck disable=SC2086,SC2029
ssh ${SSH_OPTS} "${PROXMOX_USER}@${PROXMOX_HOST}" "mkdir -p '${REMOTE_DIR}'"  # создаем директорию на удалённом хосте

echo "Uploading project files"
# shellcheck disable=SC2086
scp ${SSH_OPTS} -r \
  "${PROJECT_ROOT}/config" \
  "${PROJECT_ROOT}/docker" \
  "${PROJECT_ROOT}/monitoring" \
  "${PROJECT_ROOT}/scripts" \
  "${PROJECT_ROOT}/README.md" \
  "${PROXMOX_USER}@${PROXMOX_HOST}:${REMOTE_DIR}/"  # копируем файлы проекта на удалённый Proxmox

echo "Running deployment on Proxmox"
# shellcheck disable=SC2086,SC2029
ssh ${SSH_OPTS} "${PROXMOX_USER}@${PROXMOX_HOST}" "cd '${REMOTE_DIR}' && chmod +x scripts/*.sh scripts/lib/*.sh && ./scripts/run-all.sh"

