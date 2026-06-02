#!/usr/bin/env bash
# shellcheck source=./lib/common.sh
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

normalize_gpu_pci_addr() {
  local pci_addr="$1"

  if [[ "$pci_addr" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$ ]]; then
    pci_addr="0000:${pci_addr}"
  fi

  # For GPUs with a paired audio function, Proxmox should receive the whole slot
  # address (for example 0000:01:00), not only function .0.
  pci_addr="${pci_addr%.0}"
  printf '%s' "$pci_addr"
}

expected_gpu_hostpci_config() {
  [[ -n "$GPU_PCI_ADDR" ]] || return 1
  printf '%s,pcie=1,x-vga=1' "$GPU_PCI_ADDR"
}

gpu_passthrough_config_matches() {
  local expected_hostpci="$1"
  local config

  config="$(qm config "$LLM_VMID")" || return 1

  grep -qxF "machine: q35" <<< "$config" &&
    grep -qxF "vga: none" <<< "$config" &&
    grep -qxF "hostpci0: ${expected_hostpci}" <<< "$config"
}

stop_vm_for_gpu_passthrough_change() {
  if ! vm_running "$LLM_VMID"; then
    return 0
  fi

  if is_dry_run; then
    info "[DRY RUN] Would stop VM ${LLM_VMID} before changing GPU video passthrough settings"
    return 0
  fi

  info "Stopping VM ${LLM_VMID} before changing GPU video passthrough settings..."
  if ! qm_command shutdown "$LLM_VMID" --timeout 120; then
    warn "Graceful shutdown failed for VM ${LLM_VMID}; forcing stop"
  fi

  if vm_running "$LLM_VMID"; then
    qm_command stop "$LLM_VMID"
  fi
}

setup_gpu_passthrough() {
  if [[ "$GPU_PASSTHROUGH" != "true" ]]; then
    info "GPU passthrough disabled in config"
    return 0
  fi  # если passthrough не нужен, пропускаем дальнейшую проверку

  if [[ -z "$GPU_PCI_ADDR" ]]; then
    GPU_PCI_ADDR="$(lspci -D -d 10de: | awk '/VGA compatible controller|3D controller/ {print $1; exit}')"
  fi

  if [[ -z "$GPU_PCI_ADDR" ]]; then
    warn "No NVIDIA GPU found on host"
    return 0
  fi

  GPU_PCI_ADDR="$(normalize_gpu_pci_addr "$GPU_PCI_ADDR")"
  validate_pci_device "$GPU_PCI_ADDR" || die "PCI device validation failed"
  local hostpci_config="${GPU_PCI_ADDR},pcie=1,x-vga=1"

  if gpu_passthrough_config_matches "$hostpci_config"; then
    info "GPU video passthrough already configured: ${hostpci_config}"
    return 0
  fi

  stop_vm_for_gpu_passthrough_change
  info "Configuring GPU video passthrough: ${GPU_PCI_ADDR}"
  qm_command set "$LLM_VMID" \
    --machine q35 \
    --vga none \
    --hostpci0 "$hostpci_config"

  if is_dry_run; then
    return 0
  fi

  gpu_passthrough_config_matches "$hostpci_config" ||
    die "GPU passthrough config was not applied to VM ${LLM_VMID}"
}

verify_gpu_passthrough() {
  if [[ "$GPU_PASSTHROUGH" != "true" ]]; then
    return 0
  fi

  if is_dry_run; then
    return 0
  fi

  local hostpci_config
  hostpci_config="$(expected_gpu_hostpci_config)" ||
    die "GPU passthrough enabled, but GPU_PCI_ADDR is empty"

  gpu_passthrough_config_matches "$hostpci_config" ||
    die "GPU passthrough config missing on VM ${LLM_VMID}; expected hostpci0: ${hostpci_config}"

  info "Verifying NVIDIA GPU is visible inside VM ${LLM_VMID}..."
  local result
  result="$(qm_command guest exec "$LLM_VMID" -- lspci 2>/dev/null)" ||
    die "Failed to run lspci inside VM ${LLM_VMID}"

  local out
  out="$(parse_qm_guest_exec_output "$result")"
  if ! printf '%s' "$out" | grep -qi nvidia; then
    die "NVIDIA GPU is not visible inside VM ${LLM_VMID}; check hostpci0, vfio binding, and cold restart"
  fi

  info "NVIDIA GPU is visible inside VM ${LLM_VMID}"
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

  verify_gpu_passthrough
}

ensure_data_disk_ready() {
  info "Ensuring data disk (/dev/sdb) is partitioned, mounted, and ready for Docker..."

  # Очищаем устаревший ключ хоста — VM могла пересоздаваться
  ssh-keygen -R "$LLM_IP" >/dev/null 2>&1 || true
  mkdir -p "$HOME/.ssh"
  ssh-keyscan -H "$LLM_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

  # qm guest exec имеет жёсткий таймаут Proxmox (~30 с), которого недостаточно
  # для форматирования диска и перезапуска Docker. Используем SSH напрямую.
  guest_ssh "$LLM_IP" sudo bash -s -- \
    "$GUEST_USER" \
    "${REFORMAT_DATA_DISK:-0}" \
    "${CONFIRM_REFORMAT:-no}" \
    <<'REMOTE'
set -Eeuo pipefail
GUEST_USER="$1"
REFORMAT_DATA_DISK="$2"
CONFIRM_REFORMAT="$3"

DISK=/dev/sdb
PART=/dev/sdb1
MOUNT=/mnt/data
DOCKER_ROOT="$MOUNT/docker"

if [[ ! -b "$DISK" ]]; then
  echo "Data disk $DISK not present in VM" >&2
  exit 1
fi

if [[ ! -b "$PART" ]]; then
  sgdisk -o "$DISK"
  sgdisk -n 1:0:0 -t 1:8300 "$DISK"
  partprobe "$DISK"
  udevadm settle || true
  for _ in $(seq 1 10); do
    [[ -b "$PART" ]] && break
    sleep 1
  done
  [[ -b "$PART" ]]
fi

if blkid -s TYPE "$PART" 2>/dev/null | grep -q TYPE; then
  if [[ "$REFORMAT_DATA_DISK" == "1" ]]; then
    if [[ "$CONFIRM_REFORMAT" != "yes" ]]; then
      echo "REFORMAT_DATA_DISK=1 requires CONFIRM_REFORMAT=yes" >&2
      exit 1
    fi
    umount "$PART" "$MOUNT" 2>/dev/null || true
    sgdisk -o "$DISK"
    sgdisk -n 1:0:0 -t 1:8300 "$DISK"
    partprobe "$DISK"
    udevadm settle || true
    for _ in $(seq 1 10); do
      [[ -b "$PART" ]] && break
      sleep 1
    done
    [[ -b "$PART" ]]
    mkfs.ext4 -F -L ai-data "$PART"
    udevadm settle || true
  fi
else
  mkfs.ext4 -F -L ai-data "$PART"
  udevadm settle || true
fi

# Ждём пока blkid увидит UUID — udev может запаздывать после mkfs
UUID=""
for _ in $(seq 1 15); do
  UUID=$(blkid -s UUID -o value "$PART" 2>/dev/null || true)
  [[ -n "$UUID" ]] && break
  sleep 1
done
if [[ -z "$UUID" ]]; then
  echo "Failed to read UUID from $PART after mkfs" >&2
  exit 1
fi

mkdir -p "$MOUNT"

if grep -qE "[[:space:]]/mnt/(ai-data|llm-data)[[:space:]]" /etc/fstab 2>/dev/null; then
  sed -i -E "s#/mnt/(ai-data|llm-data)#${MOUNT}#g" /etc/fstab
fi

sed -i -E "\#[[:space:]]${MOUNT}[[:space:]]#d" /etc/fstab
sed -i -E "\#^UUID=${UUID}[[:space:]]#d" /etc/fstab
echo "UUID=$UUID $MOUNT ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab

mount -a
mountpoint -q "$MOUNT"
findmnt "$MOUNT"

mkdir -p "$MOUNT/ollama" "$MOUNT/models" "$MOUNT/openwebui" "$DOCKER_ROOT"
chown -R "${GUEST_USER}:${GUEST_USER}" "$MOUNT/ollama" "$MOUNT/models" "$MOUNT/openwebui"
chown root:root "$DOCKER_ROOT"

mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
fi
cat > /etc/docker/daemon.json <<JSON
{
  "data-root": "/mnt/data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
JSON

systemctl daemon-reload || true
if command -v dockerd >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
  systemctl enable docker || true
  systemctl restart docker || true
fi

df -h "$MOUNT"
REMOTE
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
ensure_data_disk_ready

setup_ssh_access
audit_log "LLM VM ${LLM_VMID} setup completed successfully"