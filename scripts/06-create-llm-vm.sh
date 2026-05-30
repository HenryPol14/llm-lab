#!/usr/bin/env bash
# shellcheck disable=SC1078,SC1079,SC2016,SC2026
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции и утилиты
load_config                                           # загружаем конфигурацию проекта
require_root                                          # проверяем права root
require_cmd qm                                       # требуем утилиту qm для управления Proxmox VM
require_cmd sgdisk                                   # требуем утилиту sgdisk для работы с разделами
require_cmd blkid                                    # требуем blkid для определения UUID блоков

mark_step "Creating/Updating LLM VM (VMID: ${LLM_VMID})"  # логируем шаг создания LLM VM

require_pve_storage "$LLM_STORAGE"                    # проверяем доступность хранилища для LLM VM
vm_exists "$TEMPLATE_VMID" || die "Template ${TEMPLATE_VMID} not found"  # шаблон должен быть создан заранее

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
    qm_command clone "$TEMPLATE_VMID" "$LLM_VMID" --name "$LLM_NAME" --full true --storage "$LLM_STORAGE"  # клон шаблона для LLM VM
  fi
}

configure_vm() {
  info "Configuring hardware and cloud-init network settings..."
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
    --nameserver "$DNS_SERVER"  # базовая сетка и cloud-init

  info "Ensuring system disk scsi0 on host is ${LLM_SYSTEM_DISK_GB}G..."
  qm_command resize "$LLM_VMID" scsi0 "${LLM_SYSTEM_DISK_GB}G" || warn "Failed to resize system disk to ${LLM_SYSTEM_DISK_GB}GB"  # задаем размер системного диска
}

setup_data_disk_storage() {
  if ! qm_command config "$LLM_VMID" | grep -q '^scsi1:'; then
    qm_command set "$LLM_VMID" --scsi1 "${LLM_STORAGE}:${LLM_DATA_DISK_GB},discard=on,ssd=1,iothread=1"  # добавляем диск данных VM
  else
    info "Data disk scsi1 already configured"
  fi
}

setup_gpu_passthrough() {
  if [[ "$GPU_PASSTHROUGH" != "true" ]]; then
    info "GPU passthrough disabled in config"
    return 0
  fi  # если passthrough не нужен, пропускаем дальнейшую проверку

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
    qm_command start "$LLM_VMID"  # запускаем VM, если она еще не запущена
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

confirm_data_disk_reformat() {
  local disk_device="/dev/sdb"
  local disk_part="${disk_device}1"

  if qm_command guest exec "$LLM_VMID" -- test -b "$disk_device" >/dev/null 2>&1; then
    if qm_command guest exec "$LLM_VMID" -- blkid "$disk_part" >/dev/null 2>&1; then
      warn "Data disk $disk_part already has a filesystem"
      
      # Если FORCE не равен 1, то сразу выходим (сохраняем данные)
      if [[ "${REFORMAT_DATA_DISK:-0}" != "1" ]]; then
        info "Skipping reformat. Use REFORMAT_DATA_DISK=1 to force."
        return 1
      fi

      # Если REFORMAT_DATA_DISK=1, проверяем интерактивность или флаг подтверждения
      if [[ "${CONFIRM_REFORMAT:-no}" == "yes" ]]; then
        info "Formatting data disk (forced by CONFIRM_REFORMAT=yes)"
        return 0
      fi

      if [[ ! -t 0 ]]; then
        die "Non-interactive shell: REFORMAT_DATA_DISK=1 set, but CONFIRM_REFORMAT=yes is missing"
      fi

      local confirm
      read -r -p "Confirm reformat data disk? This WILL DESTROY DATA. [yes/no]: " confirm
      [[ "$confirm" == "yes" ]] || die "Aborted by user"
      info "Formatting data disk"
      return 0
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
  
  # Вместо склеивания кавычек, передаем GUEST_USER как переменную окружения внутри вызова bash
  qm_command guest exec "$LLM_VMID" -- env GUEST_USER="$GUEST_USER" bash -lc '
set -Eeuo pipefail
DISK=/dev/sdb
PART=/dev/sdb1
MOUNT=/mnt/llm-data

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

  # Настройка Docker
  if command -v dockerd >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<JSON
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
  ssh-keygen -R "$LLM_IP" >/dev/null 2>&1 || true  # удаляем старый ключ из known_hosts
  mkdir -p "$HOME/.ssh"                            # создаем директорию SSH клиента
  ssh-keyscan -H "$LLM_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true  # добавляем новый ключ хоста
  info "LLM VM ready: ssh ${GUEST_USER}@${LLM_IP}"
}

# ==========================================
# ОСНОВНОЙ ПОРЯДОК ВЫПОЛНЕНИЯ (PIPELINE)
# ==========================================

clone_vm_if_needed
configure_vm
setup_data_disk_storage
setup_gpu_passthrough

# 1. Запуск и ожидание Cloud-Init (он же теперь расширяет root-диск)
start_and_wait_vm

# 2. Работа с диском данных
if confirm_data_disk_reformat; then
  partition_and_mount_data_disk
fi

setup_ssh_access
audit_log "LLM VM ${LLM_VMID} setup completed successfully"
