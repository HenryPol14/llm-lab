#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
# Описание: Включает IOMMU и необходимые настройки для passthrough GPU.
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции и утилиты
load_config                                           # загружаем конфигурацию проекта и переменные
require_root                                          # проверяем, что скрипт запущен от root

require_cmd update-grub                               # убеждаемся, что доступна команда для обновления загрузчика

CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2}')"  # определяем вендора CPU
case "$CPU_VENDOR" in
  GenuineIntel) IOMMU_ARG="intel_iommu=on" ;;
  AuthenticAMD) IOMMU_ARG="amd_iommu=on" ;;
  *) die "Unsupported or unknown CPU vendor: ${CPU_VENDOR:-unknown}" ;;
esac

GRUB_FILE=/etc/default/grub
CURRENT="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)"
ARGS=""
if [[ "$CURRENT" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"$ ]]; then
  ARGS="${BASH_REMATCH[1]}"
fi

ARGS="$(echo "$ARGS" | sed -E 's/(intel_iommu=on|amd_iommu=on)//g; s/(^| )iommu=pt( |$)/ /g' | xargs)"  # очищаем старые параметры IOMMU
ARGS="$(echo "${ARGS} ${IOMMU_ARG} iommu=pt" | xargs)"  # добавляем нужный параметр и режим passthrough

  if [[ "$CURRENT" != "GRUB_CMDLINE_LINUX_DEFAULT=\"${ARGS}\"" ]]; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
      sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*$|GRUB_CMDLINE_LINUX_DEFAULT=\"${ARGS}\"|" "$GRUB_FILE"
    else
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${ARGS}\"" >> "$GRUB_FILE"
    fi
    update-initramfs -u -k all || true
    update-grub || true
    warn "IOMMU settings changed. Reboot Proxmox before GPU passthrough if this is the first run."
  else
  info "IOMMU kernel args are already configured"
fi

for module in vfio vfio_iommu_type1 vfio_pci; do
  ensure_line "$module" /etc/modules
done

info "IOMMU/VFIO configuration is present"
