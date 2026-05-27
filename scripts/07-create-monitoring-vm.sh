#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

MONITORING_VMID="${MONITORING_VMID:-120}"
MONITORING_NAME="${MONITORING_NAME:-monitoring-vm}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
MONITORING_STORAGE="${MONITORING_STORAGE:-local-lvm}"
INTERNAL_BRIDGE="${INTERNAL_BRIDGE:-vmbr1}"
INTERNAL_GATEWAY="${INTERNAL_GATEWAY:-10.10.10.1}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
MONITORING_PREFIX="${MONITORING_PREFIX:-24}"
MONITORING_MEMORY_MB="${MONITORING_MEMORY_MB:-8192}"
MONITORING_CORES="${MONITORING_CORES:-4}"
MONITORING_SYSTEM_DISK_GB="$(normalize_gb "${MONITORING_SYSTEM_DISK_GB:-40}")"
MONITORING_DATA_DISK_GB="$(normalize_gb "${MONITORING_DATA_DISK_GB:-100}")"

require_cmd qm
require_pve_storage "$MONITORING_STORAGE"
vm_exists "$TEMPLATE_VMID" || die "Template ${TEMPLATE_VMID} not found"

if vm_exists "$MONITORING_VMID"; then
  info "VM ${MONITORING_VMID} already exists. Updating configuration."
  WRONG_DISKS="$(qm config "$MONITORING_VMID" | awk -F'[: ,]+' -v storage="${MONITORING_STORAGE}" '/^(scsi0|scsi1):/ && $2 !~ "^" storage ":" {print $1 ":" $2}' | paste -sd ' ' -)"
  if [[ -n "$WRONG_DISKS" ]]; then
    warn "VM ${MONITORING_VMID} already has disks outside ${MONITORING_STORAGE}: ${WRONG_DISKS}"
    warn "The script will not move existing disks automatically. Recreate the VM or move disks manually with qm move_disk."
  fi
else
  info "Cloning template ${TEMPLATE_VMID} to VM ${MONITORING_VMID} on ${MONITORING_STORAGE}"
  qm clone "$TEMPLATE_VMID" "$MONITORING_VMID" --name "$MONITORING_NAME" --full true --storage "$MONITORING_STORAGE"
fi

qm resize "$MONITORING_VMID" scsi0 "${MONITORING_SYSTEM_DISK_GB}G" || true

qm set "$MONITORING_VMID" \
  --name "$MONITORING_NAME" \
  --memory "$MONITORING_MEMORY_MB" \
  --cores "$MONITORING_CORES" \
  --cpu host \
  --balloon 0 \
  --agent enabled=1 \
  --net0 "virtio,bridge=${INTERNAL_BRIDGE}" \
  --ciuser ubuntu \
  --ipconfig0 "ip=${MONITORING_IP}/${MONITORING_PREFIX},gw=${INTERNAL_GATEWAY}" \
  --nameserver "$DNS_SERVER"

if ! qm config "$MONITORING_VMID" | grep -q '^scsi1:'; then
  qm set "$MONITORING_VMID" --scsi1 "${MONITORING_STORAGE}:${MONITORING_DATA_DISK_GB},discard=on,ssd=1,iothread=1"
fi

if vm_running "$MONITORING_VMID"; then
  info "VM ${MONITORING_VMID} is already running"
else
  qm start "$MONITORING_VMID"
fi

wait_for_guest_agent "$MONITORING_VMID" 240

qm guest exec "$MONITORING_VMID" -- bash -lc '
  set -e
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-guest-utils gdisk parted
  sgdisk -e /dev/sda || true
  partprobe /dev/sda || true
  growpart /dev/sda 1 || true
  resize2fs /dev/sda1 || true
  if [[ -b /dev/sdb ]] && ! findmnt -S /dev/sdb1 >/dev/null 2>&1; then
    if ! blkid /dev/sdb1 >/dev/null 2>&1; then
      sgdisk -o /dev/sdb
      sgdisk -n 1:0:0 -t 1:8300 /dev/sdb
      partprobe /dev/sdb
      mkfs.ext4 -F /dev/sdb1
    fi
    mkdir -p /mnt/monitoring-data
    grep -q "/mnt/monitoring-data" /etc/fstab || echo "/dev/sdb1 /mnt/monitoring-data ext4 defaults 0 0" >> /etc/fstab
    mount /mnt/monitoring-data || true
  fi
'

ssh-keygen -R "$MONITORING_IP" >/dev/null 2>&1 || true
ssh-keyscan -H "$MONITORING_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
info "Monitoring VM is ready: ssh ubuntu@${MONITORING_IP}"
