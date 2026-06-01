#!/usr/bin/env bash
# Описание: Устанавливает необходимые инструменты и зависимости для Proxmox.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции и утилиты
load_config                                           # загружаем конфигурацию окружения
require_root                                          # проверяем, что скрипт выполняется от root

install_missing_packages \                             # устанавливаем необходимые пакеты, если отсутствуют
  curl wget ca-certificates gnupg lsb-release jq yq unzip git rsync \   # утилиты для загрузки, работы с JSON/YAML и синхронизации
  qemu-guest-agent cloud-image-utils libguestfs-tools gdisk parted \   # инструменты для виртуализации, работы с образами и дисками
  bridge-utils dnsmasq nftables iptables-persistent                   # сетевые утилиты и брандмауэр

systemctl enable --now nftables || true    # включаем nftables и запускаем сразу, игнорируем ошибку если уже включено
systemctl enable --now fstrim.timer || true # включаем периодическую обрезку SSD, если поддерживается

info "Proxmox host tools are ready"            # уведомляем, что инструменты на хосте готовы

