#!/usr/bin/env bash
# Описание: Скачивает образ cloud-образа Ubuntu и подготавливает его для Proxmox.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
UBUNTU_IMAGE_PATH="${UBUNTU_IMAGE_PATH:-/var/lib/vz/template/qcow2/ubuntu-noble.img}"

mkdir -p "$(dirname "$UBUNTU_IMAGE_PATH")"
if [[ -f "$UBUNTU_IMAGE_PATH" ]]; then
  info "Cloud image already exists: ${UBUNTU_IMAGE_PATH}"
  exit 0
fi

info "Downloading ${UBUNTU_IMAGE_URL}"
curl -fL "$UBUNTU_IMAGE_URL" -o "${UBUNTU_IMAGE_PATH}.tmp"
mv "${UBUNTU_IMAGE_PATH}.tmp" "$UBUNTU_IMAGE_PATH"
info "Cloud image saved to ${UBUNTU_IMAGE_PATH}"

