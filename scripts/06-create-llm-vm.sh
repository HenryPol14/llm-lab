#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

LLM_VMID="${LLM_VMID:-110}"
LLM_NAME="${LLM_NAME:-llm-server}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
LLM_STORAGE="${LLM_STORAGE:-${STORAGE:-SSD-VMs}}"
INTERNAL_BRIDGE="${INTERNAL_BRIDGE:-vmbr1}"
INTERNAL_GATEWAY="${INTERNAL_GATEWAY:-10.10.10.1}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
LLM_IP="${LLM_IP:-10.10.10.50}"
LLM_PREFIX="${LLM_PREFIX:-24}"
LLM_MEMORY_MB="${LLM_MEMORY_MB:-20480}"
LLM_CORES="${LLM_CORES:-6}"
LLM_SYSTEM_DISK_GB="$(normalize_gb "${LLM_SYSTEM_DISK_GB:-64}")"
LLM_DATA_DISK_GB="$(normalize_gb "${LLM_DATA_DISK_GB:-200}")"

require_cmd qm
require_pve_storage "$LLM_STORAGE"
vm_exists "$TEMPLATE_VMID" || die "Template ${TEMPLATE_VMID} not found"

if vm_exists "$LLM_VMID"; then
  info "VM ${LLM_VMID} already exists. Updating configuration."
  WRONG_DISKS="$(qm config "$LLM_VMID" | awk -F'[: ,]+' -v storage="${LLM_STORAGE}" '/^(scsi0|scsi1):/ && $2 !~ "^" storage ":" {print $1 ":" $2}' | paste -sd ' ' -)"
  if [[ -n "$WRONG_DISKS" ]]; then
    warn "VM ${LLM_VMID} already has disks outside ${LLM_STORAGE}: ${WRONG_DISKS}"
    warn "The script will not move existing disks automatically. Recreate the VM or move disks manually with qm move_disk."
  fi
else
  info "Cloning template ${TEMPLATE_VMID} to VM ${LLM_VMID} on ${LLM_STORAGE}"
  qm clone "$TEMPLATE_VMID" "$LLM_VMID" --name "$LLM_NAME" --full true --storage "$LLM_STORAGE"
fi

qm guest exec "$LLM_VMID" -- bash -lc '
  set -Eeuo pipefail

  DISK=/dev/sdb
  PART=/dev/sdb1
  MOUNT=/mnt/ai-data

  if [[ -b "$DISK" ]]; then

    if ! blkid "$PART" >/dev/null 2>&1; then
      echo "[INFO] Partitioning data disk"

      sgdisk -o "$DISK"
      sgdisk -n 1:0:0 -t 1:8300 "$DISK"

      partprobe "$DISK"
      sleep 2

      mkfs.ext4 -F -L ai-data "$PART"
    fi

    UUID=$(blkid -s UUID -o value "$PART")

    mkdir -p "$MOUNT"

    if ! grep -q "$UUID" /etc/fstab; then
      echo "UUID=$UUID $MOUNT ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab
    fi

    mount -a

    mkdir -p \
      $MOUNT/docker \
      $MOUNT/ollama \
      $MOUNT/models

    chown -R ubuntu:ubuntu "$MOUNT"

    echo "[INFO] Data disk mounted to $MOUNT"
  fi

qm set "$LLM_VMID" \
  --name "$LLM_NAME" \
  --memory "$LLM_MEMORY_MB" \
  --cores "$LLM_CORES" \
  --cpu host \
  --balloon 0 \
  --numa 1 \
  --agent enabled=1 \
  --net0 "virtio,bridge=${INTERNAL_BRIDGE},queues=8" \
  --ciuser ubuntu \
  --ipconfig0 "ip=${LLM_IP}/${LLM_PREFIX},gw=${INTERNAL_GATEWAY}" \
  --nameserver "$DNS_SERVER"

if ! qm config "$LLM_VMID" | grep -q '^scsi1:'; then
  qm set "$LLM_VMID" --scsi1 "${LLM_STORAGE}:${LLM_DATA_DISK_GB},discard=on,ssd=1,iothread=1"
fi

GPU_ADDR="${GPU_PCI_ADDR:-}"
if [[ -z "$GPU_ADDR" ]]; then
  GPU_ADDR="$(lspci -D -d 10de: | awk 'NR==1 {print $1}')"
fi
if [[ -n "$GPU_ADDR" ]]; then
  info "Configuring GPU passthrough: ${GPU_ADDR}"
  qm set "$LLM_VMID" --hostpci0 "${GPU_ADDR},pcie=1"
else
  warn "No NVIDIA GPU detected. LLM VM will run without GPU passthrough."
fi

if vm_running "$LLM_VMID"; then
  info "VM ${LLM_VMID} is already running"
else
  qm start "$LLM_VMID"
fi

wait_for_guest_agent "$LLM_VMID" 240

qm guest exec "$LLM_VMID" -- bash -lc '
  set -e
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-guest-utils gdisk parted
  sgdisk -e /dev/sda || true
  partprobe /dev/sda || true
  growpart /dev/sda 1 || true
  resize2fs /dev/sda1 || true
  systemctl stop multipathd || true
  systemctl disable multipathd || true
  apt-get purge -y multipath-tools || true
  update-initramfs -u || true
'

qm guest exec "$LLM_VMID" -- bash -lc '
  set -e
  if [[ -b /dev/sdb ]] && ! findmnt -S /dev/sdb1 >/dev/null 2>&1; then
    if ! blkid /dev/sdb1 >/dev/null 2>&1; then
      sgdisk -o /dev/sdb
      sgdisk -n 1:0:0 -t 1:8300 /dev/sdb
      partprobe /dev/sdb
      mkfs.ext4 -F /dev/sdb1
    fi
    mkdir -p /mnt/llm-data
    grep -q "/mnt/llm-data" /etc/fstab || echo "/dev/sdb1 /mnt/llm-data ext4 defaults 0 0" >> /etc/fstab
    mount /mnt/llm-data || true
  fi
'

ssh-keygen -R "$LLM_IP" >/dev/null 2>&1 || true
ssh-keyscan -H "$LLM_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
info "LLM VM is ready: ssh ubuntu@${LLM_IP}"
