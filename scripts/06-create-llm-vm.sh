#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root
require_cmd qm
require_cmd sgdisk
require_cmd blkid

mark_step "Creating/Updating LLM VM (VMID: ${LLM_VMID})"

require_pve_storage "$LLM_STORAGE"
vm_exists "$TEMPLATE_VMID" || die "Template ${TEMPLATE_VMID} not found"

bilg_check_existing_vm() {
  if vm_exists "$LLM_VMID"; then
    info "VM ${LLM_VMID} already exists. Checking configuration..."
    local detected_storage
    detected_storage="$(qm config "$LLM_VMID" | awk -F'[: ,]+' '/^scsi0:/ {print $2}' | cut -d, -f1 | cut -d: -f1)"
    if [[ "$detected_storage" != "$LLM_STORAGE" ]]; then
      warn "VM ${LLM_VMID}: scsi0 on $detected_storage, expected $LLM_STORAGE"
      if [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
        warn "Move disk manually with: qm move_disk ${LLM_VMID} scsi0 ${LLM_STORAGE}"
        die "Storage mismatch. Remove VM or use FORCE_REBUILD=1"
      else
        info "FORCE_REBUILD=1: destroying VM ${LLM_VMID}"
        qm destroy "$LLM_VMID" --purge
        return 1
      fi
    fi
    return 0
  fi
  return 1
}

clone_vm_if_needed() {
  if ! bilg_check_existing_vm; then
    info "Cloning template ${TEMPLATE_VMID} to VM ${LLM_VMID} on ${LLM_STORAGE}"
    qm_command clone "$TEMPLATE_VMID" "$LLM_VMID" --name "$LLM_NAME" --full true --storage "$LLM_STORAGE"
    
    info "Ensuring LLM VM system disk is ${LLM_SYSTEM_DISK_GB}GB"
    qm_command resize "$LLM_VMID" scsi0 "${LLM_SYSTEM_DISK_GB}G" || warn "Failed to resize system disk to ${LLM_SYSTEM_DISK_GB}GB"
  fi
}

configure_vm() {
  qm_command set "$LLM_VMID" \
    --name "$LLM_NAME" \
    --memory "$LLM_MEMORY_MB" \
    --cores "$LLM_CORES" \
    --cpu host \
    --balloon 0 \
    --numa 1 \
    --agent enabled=1 \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${INTERNAL_BRIDGE},queues=8" \
    --ciuser "$GUEST_USER" \
    --ipconfig0 "ip=${LLM_IP}/${LLM_PREFIX},gw=${INTERNAL_GATEWAY}" \
    --nameserver "$DNS_SERVER"

  # [ИСПРАВЛЕНИЕ] Добавляем размер к системному диску на уровне Proxmox, 
  # чтобы внутри ВМ команде growpart было куда расширяться.
  # Например, расширяем scsi0 до 30 ГБ (измените под свои нужды, если нужно больше)
  info "Ensuring system disk scsi0 on host is ${LLM_SYSTEM_DISK_GB}G..."
  qm resize "$LLM_VMID" scsi0 "${LLM_SYSTEM_DISK_GB}G" || true

  # Create cloud-init user-data to auto-grow root on first boot
  create_cloud_init_userdata
}

create_cloud_init_userdata() {
  # write a cloud-init user-data snippet for this VM with system optimization and disk growth
  local snippet_dir="/var/lib/vz/snippets"
  local snippet_name="llm-${LLM_VMID}-user-data.yaml"
  local snippet_path="$snippet_dir/$snippet_name"

  mkdir -p "$snippet_dir"
  cat > "$snippet_path" <<'YAML'
#cloud-config
package_update: true
packages:
  - cloud-guest-utils
  - grub-pc
  - linux-image-generic

# Write DNS configuration via netplan to suppress systemd-resolved warnings
write_files:
  - path: /etc/netplan/99-dns-config.yaml
    content: |
      network:
        version: 2
        ethernets:
          eth0:
            dhcp4: true
            dhcp4-overrides:
              use-dns: false
            nameservers:
              addresses: [1.1.1.1, 1.0.0.1, 8.8.8.8]
              search: []
    owner: root:root
    permissions: '0644'
  - path: /etc/systemd/resolved.conf.d/cloudlab.conf
    content: |
      [Resolve]
      DNS=1.1.1.1 1.0.0.1 8.8.8.8
      FallbackDNS=8.8.4.4 1.1.1.2
      DNSSEC=no
      DNSSECNegativeTrustAnchors=
    owner: root:root
    permissions: '0644'

growpart:
  mode: auto
  devices:
    - /dev/sda
  ignore_growroot_disabled: false

runcmd:
  # 1. Install required packages for system optimization
  - [ apt-get, install, -y, cloud-guest-utils, grub-pc ]
  
  # 2. Configure kernel boot parameters to suppress harmless warnings
  - [ sed, -i, 's/^GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="pci=nomsi pciehp.shpchp_bridges=0 ima_policy=tcb"/', /etc/default/grub ]
  - [ bash, -lc, 'if grep -q "pci=nomsi" /etc/default/grub; then update-grub; fi' ]
  
  # 3. Fix cron environment variable warning
  - [ bash, -lc, 'mkdir -p /etc/systemd/system/cron.service.d' ]
  - [ bash, -lc, 'echo -e "[Service]\nEnvironment=EXTRA_OPTS=" > /etc/systemd/system/cron.service.d/env.conf' ]
  - [ systemctl, daemon-reload ]
  
  # 4. Apply DNS configuration
  - [ netplan, apply ]
  - [ systemctl, restart, systemd-resolved ]
  
  # 5. Suppress device-mapper and multipath warnings
  - [ bash, -lc, 'systemctl stop multipathd || true; systemctl disable multipathd || true; apt-get purge -y multipath-tools >/dev/null 2>&1 || true' ]
  - [ update-initramfs, -u ]
  
  # 6. Grow root filesystem and fix GPT partition table
  - [ bash, -lc, 'sleep 5; growpart /dev/sda 1 || true; partprobe /dev/sda || true; resize2fs $(findmnt -n -o SOURCE /) || true' ]
  - [ bash, -lc, 'sgdisk --move-second-header /dev/sda || true' ]
YAML

  # Attach the snippet to VM (use local snippets storage)
  qm set "$LLM_VMID" --cicustom "user=local:snippets/$snippet_name" || warn "Failed to set cicustom for $LLM_VMID"
}

setup_data_disk_storage() {
  if ! qm_command config "$LLM_VMID" | grep -q '^scsi1:'; then
    qm_command set "$LLM_VMID" --scsi1 "${LLM_STORAGE}:${LLM_DATA_DISK_GB},discard=on,ssd=1,iothread=1"
  else
    info "Data disk scsi1 already configured"
  fi
}

setup_gpu_passthrough() {
  if [[ "$GPU_PASSTHROUGH" != "true" ]]; then
    info "GPU passthrough disabled in config"
    return 0
  fi

  if [[ -z "$GPU_PCI_ADDR" ]]; then
    GPU_PCI_ADDR="$(lspci -D -d 10de: | awk 'NR==1 {print $1}')"
  fi

  if [[ -z "$GPU_PCI_ADDR" ]]; then
    warn "No NVIDIA GPU found on host"
    return 0
  fi

  validate_pci_device "$GPU_PCI_ADDR" || die "PCI device validation failed"
  info "Configuring GPU passthrough: ${GPU_PCI_ADDR}"
  qm_command set "$LLM_VMID" --hostpci0 "${GPU_PCI_ADDR},pcie=1"
}

start_and_wait_vm() {
  if ! vm_running "$LLM_VMID"; then
    qm_command start "$LLM_VMID"
  fi
  
  info "Waiting for Guest Agent to become ready..."
  guest_is_ready "$LLM_VMID" 240 || die "VM ${LLM_VMID} not ready (Agent timeout)"
  
  info "Waiting for cloud-init to complete..."
  wait_for_cloud_init "$LLM_VMID" 300 || die "cloud-init failed on VM ${LLM_VMID}"
  
  if ! check_guest_network "$LLM_VMID" "$LLM_IP" 120; then
    die "Guest network not configured on VM ${LLM_VMID} (expected IP: ${LLM_IP})"
  fi

  check_system_running "$LLM_VMID" || die "System check failed for VM ${LLM_VMID}"
}

grow_system_disk() {
  info "Growing system disk inside the guest..."
  qm_command guest exec "$LLM_VMID" -- bash -lc '
set -e
apt-get clean
sgdisk -e /dev/sda || true
partprobe /dev/sda || true
growpart /dev/sda 1 || true
resize2fs /dev/sda1 || true
# Fix GPT partition table warnings by moving secondary header to end of disk
sgdisk --move-second-header /dev/sda || true
systemctl stop multipathd || true
systemctl disable multipathd || true
apt-get purge -y multipath-tools >/dev/null 2>&1 || true
update-initramfs -u >/dev/null 2>&1 || true
'
}

confirm_data_disk_reformat() {
  local disk_device="/dev/sdb"
  local disk_part="${disk_device}1"

  if qm_command guest exec "$LLM_VMID" -- test -b "$disk_device" >/dev/null 2>&1; then
    if qm_command guest exec "$LLM_VMID" -- blkid "$disk_part" >/dev/null 2>&1; then
      warn "Data disk $disk_part already has a filesystem"
      if [[ "${REFORMAT_DATA_DISK:-0}" != "1" ]]; then
        info "Skipping reformat. Use REFORMAT_DATA_DISK=1 to force."
        return 1
      else
        local confirm
        read -p "Confirm reformat data disk? This WILL DESTROY DATA. [yes/no]: " confirm
        [[ "$confirm" == "yes" ]] || die "Aborted by user"
        info "Formatting data disk"
        return 0
      fi
    else
      info "No filesystem on $disk_part, will format"
      return 0
    fi
  else
    warn "Data disk $disk_device not present in VM"
    return 1
  fi
}

partition_and_mount_data_disk() {
  info "Partitioning and mounting data disk (/dev/sdb)..."
  # [ИСПРАВЛЕНИЕ] Прокидываем переменную GUEST_USER внутрь окружения ВМ
  qm_command guest exec "$LLM_VMID" -- bash -lc '
set -Eeuo pipefail
DISK=/dev/sdb
PART=/dev/sdb1
MOUNT=/mnt/llm-data
GUEST_USER="'"$GUEST_USER"'"

if [[ -b "$DISK" ]]; then
  if ! blkid "$PART" >/dev/null 2>&1; then
    sgdisk -o "$DISK"
    sgdisk -n 1:0:0 -t 1:8300 "$DISK"
    partprobe "$DISK"
    sleep 2
    mkfs.ext4 -F -L ai-data "$PART"
  fi
  UUID=$(blkid -s UUID -o value "$PART")
  mkdir -p "$MOUNT"
  if ! grep -q "$UUID" /etc/fstab 2>/dev/null; then
    echo "UUID=$UUID $MOUNT ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab
  fi
  mount -a
  mkdir -p "$MOUNT/ollama" "$MOUNT/models" "$MOUNT/docker"
  chown -R "${GUEST_USER}:${GUEST_USER}" "$MOUNT"

  # Configure Docker to use the external data disk
  if command -v dockerd >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{"data-root":"/mnt/llm-data/docker"}
JSON
    systemctl daemon-reload || true
    systemctl restart docker || true
    systemctl enable docker || true
  fi
fi
'
}

setup_ssh_access() {
  ssh-keygen -R "$LLM_IP" >/dev/null 2>&1 || true
  ssh-keyscan -H "$LLM_IP" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
  info "LLM VM ready: ssh ${GUEST_USER}@${LLM_IP}"
}

# ==========================================
# ОСНОВНОЙ ПОРЯДОК ВЫПОЛНЕНИЯ (PIPELINE)
# ==========================================

clone_vm_if_needed
configure_vm
setup_data_disk_storage
setup_gpu_passthrough

# 1. Сначала запускаем ВМ и ждем, пока она поднимется
start_and_wait_vm

# 2. Сразу расширяем системный диск, чтобы ОС не задохнулась
grow_system_disk

# 3. И только теперь работаем с диском данных (теперь гостевой агент ответит)
if confirm_data_disk_reformat; then
  partition_and_mount_data_disk
fi

setup_ssh_access
audit_log "LLM VM ${LLM_VMID} setup completed successfully"
