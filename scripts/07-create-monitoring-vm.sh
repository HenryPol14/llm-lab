#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd qm
require_cmd sgdisk
require_cmd blkid

mark_step "Creating/Updating Monitoring VM (VMID: ${MONITORING_VMID})"

require_pve_storage "$MONITORING_STORAGE"
vm_exists "$TEMPLATE_VMID" || die "Template ${TEMPLATE_VMID} not found"

bilg_check_existing_vm() {
  if vm_exists "$MONITORING_VMID"; then
    info "VM ${MONITORING_VMID} already exists. Checking configuration..."
    local detected_storage
    detected_storage="$(qm config "$MONITORING_VMID" | awk -F'[: ,]+' '/^scsi0:/ {print $2}' | cut -d, -f1 | cut -d: -f1)"
    if [[ "$detected_storage" != "$MONITORING_STORAGE" ]]; then
      warn "VM ${MONITORING_VMID}: scsi0 on $detected_storage, expected $MONITORING_STORAGE"
      if [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
        warn "Move disk manually with: qm move_disk ${MONITORING_VMID} scsi0 ${MONITORING_STORAGE}"
        die "Storage mismatch. Remove VM or use FORCE_REBUILD=1"
      else
        info "FORCE_REBUILD=1: destroying VM ${MONITORING_VMID}"
        qm_command destroy "$MONITORING_VMID" --purge
        return 1
      fi
    fi
    return 0
  fi
  return 1
}

clone_vm_if_needed() {
  if ! bilg_check_existing_vm; then
    info "Cloning template ${TEMPLATE_VMID} to VM ${MONITORING_VMID} on ${MONITORING_STORAGE}"
    qm_command clone "$TEMPLATE_VMID" "$MONITORING_VMID" --name "$MONITORING_NAME" --full true --storage "$MONITORING_STORAGE"
    
    info "Ensuring Monitoring VM system disk is ${MONITORING_SYSTEM_DISK_GB}GB"
    qm_command resize "$MONITORING_VMID" scsi0 "${MONITORING_SYSTEM_DISK_GB}G" || warn "Failed to resize system disk to ${MONITORING_SYSTEM_DISK_GB}GB"
  fi
}

configure_vm() {
  qm_command set "$MONITORING_VMID" \
    --name "$MONITORING_NAME" \
    --memory "$MONITORING_MEMORY_MB" \
    --cores "$MONITORING_CORES" \
    --cpu host \
    --balloon 0 \
    --agent enabled=1 \
    --net0 "virtio,bridge=${INTERNAL_BRIDGE}" \
    --ciuser "$GUEST_USER" \
    --ipconfig0 "ip=${MONITORING_IP}/${MONITORING_PREFIX},gw=${INTERNAL_GATEWAY}" \
    --nameserver "$DNS_SERVER"
}

setup_data_disk_storage() {
  if ! qm_command config "$MONITORING_VMID" | grep -q '^scsi1:'; then
    qm_command set "$MONITORING_VMID" --scsi1 "${MONITORING_STORAGE}:${MONITORING_DATA_DISK_GB},discard=on,ssd=1,iothread=1"
  else
    info "Data disk scsi1 already configured for monitoring VM"
  fi
}

confirm_data_reformat() {
  local disk_device="/dev/sdb"
  if qm_command guest exec "$MONITORING_VMID" -- test -b "$disk_device" >/dev/null 2>&1; then
    if qm_command guest exec "$MONITORING_VMID" -- blkid "${disk_device}1" >/dev/null 2>&1; then
      warn "Monitoring data disk already has filesystem"
      if [[ "${REFORMAT_MONITORING_DISK:-0}" != "1" ]]; then
        info "Skip reformat. Use REFORMAT_MONITORING_DISK=1 to force."
        return 1
      else
        local confirm
        read -p "Confirm reformat of monitoring data disk? This WILL DESTROY DATA. [yes/no]: " confirm
        [[ "$confirm" == "yes" ]] || die "Aborted by user"
        info "Formatting monitoring data disk"
        return 0
      fi
    else
      info "No filesystem on monitoring data disk, will format"
      return 0
    fi
  else
    warn "Monitoring data disk $disk_device not present"
    return 1
  fi
}

partition_monitoring_disk() {
  qm_command guest exec "$MONITORING_VMID" -- bash -lc '
set -Eeuo pipefail
DISK=/dev/sdb
PART=/dev/sdb1
MOUNT=/mnt/monitoring-data
if [[ -b "$DISK" ]]; then
  if ! blkid "$PART" >/dev/null 2>&1; then
    sgdisk -o "$DISK"
    sgdisk -n 1:0:0 -t 1:8300 "$DISK"
    partprobe "$DISK"
    mkfs.ext4 -F -L monitoring "$PART"
  fi
  mkdir -p "$MOUNT"
  UUID=$(blkid -s UUID -o value "$PART")
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab
  fi
  mount -a
fi
'
}

start_and_wait_vm() {
  if ! vm_running "$MONITORING_VMID"; then
    qm_command start "$MONITORING_VMID"
  fi
  guest_is_ready "$MONITORING_VMID" 240 || die "VM ${MONITORING_VMID} not ready"
  wait_for_cloud_init "$MONITORING_VMID" 300 || die "cloud-init failed on VM ${MONITORING_VMID}"
  check_system_running "$MONITORING_VMID" || die "System check failed for VM ${MONITORING_VMID}"
}

grow_system_disk() {
  qm_command guest exec "$MONITORING_VMID" -- bash -lc '
set -e
apt-get clean
sgdisk -e /dev/sda || true
partprobe /dev/sda || true
growpart /dev/sda 1 || true
resize2fs /dev/sda1 || true
'
}

setup_ssh_access() {
  ssh-keygen -R "$MONITORING_IP" >/dev/null 2>&1 || true
  ssh-keyscan -H "$MONITORING_IP" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
  info "Monitoring VM ready: ssh ${GUEST_USER}@${MONITORING_IP}"
}

clone_vm_if_needed
configure_vm
setup_data_disk_storage

if confirm_data_reformat; then
  partition_monitoring_disk
fi

start_and_wait_vm
grow_system_disk

if confirm_data_reformat; then
  partition_monitoring_disk
fi

setup_ssh_access
audit_log "Monitoring VM ${MONITORING_VMID} setup completed successfully"
