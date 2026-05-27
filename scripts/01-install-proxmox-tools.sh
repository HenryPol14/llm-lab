#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

install_missing_packages \
  curl wget ca-certificates gnupg lsb-release jq unzip git rsync \
  qemu-guest-agent cloud-image-utils libguestfs-tools gdisk parted \
  bridge-utils dnsmasq nftables iptables-persistent

systemctl enable --now nftables || true
systemctl enable --now fstrim.timer || true

info "Proxmox host tools are ready"

