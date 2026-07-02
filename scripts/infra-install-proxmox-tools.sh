#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Устанавливает необходимые инструменты и зависимости для Proxmox.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции и утилиты
load_config                                           # загружаем конфигурацию окружения
require_root                                          # проверяем, что скрипт выполняется от root

install_missing_packages \
  curl \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  jq \
  yq \
  unzip \
  git \
  rsync \
  qemu-guest-agent \
  cloud-image-utils \
  libguestfs-tools \
  gdisk \
  parted \
  bridge-utils \
  dnsmasq \
  nftables \
  iptables-persistent

systemctl enable --now nftables || true    # включаем nftables и запускаем сразу, игнорируем ошибку если уже включено
systemctl enable --now fstrim.timer || true # включаем периодическую обрезку SSD, если поддерживается

info "Proxmox host tools are ready"            # уведомляем, что инструменты на хосте готовы

