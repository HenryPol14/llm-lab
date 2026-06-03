#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"   # подключаем общие функции
load_config                                           # загружаем конфигурацию проекта
require_root                                          # проверяем права root
require_cmd qm                                       # требуем утилиту qm
require_cmd sgdisk                                   # требуем утилиту sgdisk для разделов
require_cmd blkid                                    # требуем blkid для идентификации устройств

mark_step "Creating/Updating Monitoring VM (VMID: ${MONITORING_VMID})"  # запись шага для аудита

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
    qm_command clone "$TEMPLATE_VMID" "$MONITORING_VMID" --name "$MONITORING_NAME" --full true --storage "$MONITORING_STORAGE"  # клонируем шаблон в monitoring VM
  fi
}

configure_vm() {
  info "Configuring Monitoring VM hardware..."
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

  info "Ensuring system disk scsi0 on host is ${MONITORING_SYSTEM_DISK_GB}G..."
  qm_command resize "$MONITORING_VMID" scsi0 "${MONITORING_SYSTEM_DISK_GB}G" || warn "Failed to resize system disk to ${MONITORING_SYSTEM_DISK_GB}GB"
  
  # Опционально: здесь можно вызывать создание cloud-init snippet, если вы хотите 
  # автоматизировать growpart через метаданные, как в LLM скрипте.
}

setup_data_disk_storage() {
  if ! qm_command config "$MONITORING_VMID" | grep -q '^scsi1:'; then
    qm_command set "$MONITORING_VMID" --scsi1 "${MONITORING_STORAGE}:${MONITORING_DATA_DISK_GB},discard=on,ssd=1,iothread=1"  # добавляем диск данных для мониторинга
  else
    info "Data disk scsi1 already configured for monitoring VM"
  fi
}

start_and_wait_vm() {
  if ! vm_running "$MONITORING_VMID"; then
    qm_command start "$MONITORING_VMID"
  fi
  info "Waiting for Guest Agent to become ready..."
  guest_is_ready "$MONITORING_VMID" 240 || die "VM ${MONITORING_VMID} not ready"
  info "Waiting for cloud-init to complete..."
  wait_for_cloud_init "$MONITORING_VMID" 300 || die "cloud-init failed on VM ${MONITORING_VMID}"
  check_system_running "$MONITORING_VMID" || die "System check failed for VM ${MONITORING_VMID}"
}

grow_system_disk() {
  info "Expanding system disk inside the guest..."
  qm_command guest exec "$MONITORING_VMID" -- bash -lc '
set -euo pipefail
apt-get clean
sgdisk -e /dev/sda || true
partprobe /dev/sda || true
growpart /dev/sda 1 || true
resize2fs /dev/sda1 || true
'
}

ensure_monitoring_data_disk_ready() {
  info "Ensuring monitoring data disk (/dev/sdb) is mounted at /mnt/data..."

  # qm guest exec имеет жёсткий таймаут Proxmox (~30 с), которого недостаточно
  # для форматирования диска. Используем SSH напрямую.
  ssh-keygen -R "$MONITORING_IP" >/dev/null 2>&1 || true
  mkdir -p "$HOME/.ssh"
  ssh-keyscan -H "$MONITORING_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true

  guest_ssh "$MONITORING_IP" sudo bash -s -- \
    "$GUEST_USER" \
    "${REFORMAT_MONITORING_DISK:-0}" \
    "${CONFIRM_REFORMAT:-no}" \
    <<'REMOTE'
set -Eeuo pipefail
GUEST_USER="$1"
REFORMAT_MONITORING_DISK="$2"
CONFIRM_REFORMAT="$3"

DISK=/dev/sdb
PART=/dev/sdb1
MOUNT=/mnt/data

if [[ ! -b "$DISK" ]]; then
  echo "Monitoring data disk $DISK not present" >&2
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
  if [[ "$REFORMAT_MONITORING_DISK" == "1" ]]; then
    if [[ "$CONFIRM_REFORMAT" != "yes" ]]; then
      echo "REFORMAT_MONITORING_DISK=1 requires CONFIRM_REFORMAT=yes" >&2
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
    mkfs.ext4 -F -L monitoring "$PART"
    udevadm settle || true
  fi
else
  mkfs.ext4 -F -L monitoring "$PART"
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

sed -i -E "\#[[:space:]]${MOUNT}[[:space:]]#d" /etc/fstab
sed -i -E "\#^UUID=${UUID}[[:space:]]#d" /etc/fstab
echo "UUID=$UUID $MOUNT ext4 defaults,noatime,nodiratime,discard 0 2" >> /etc/fstab

mount -a
mountpoint -q "$MOUNT"
findmnt "$MOUNT"
mkdir -p "$MOUNT/prometheus" "$MOUNT/grafana" "$MOUNT/alertmanager"
# Prometheus и alertmanager работают от nobody (65534)
chown -R 65534:65534 "$MOUNT/prometheus"
chown -R 65534:65534 "$MOUNT/alertmanager"
# Grafana работает от uid 472
chown -R 472:472 "$MOUNT/grafana"
df -h "$MOUNT"
REMOTE
}

setup_ssh_access() {
  ssh-keygen -R "$MONITORING_IP" >/dev/null 2>&1 || true  # удаляем старый SSH-хост из known_hosts
  ssh-keyscan -H "$MONITORING_IP" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true  # добавляем текущий ключ
  info "Monitoring VM ready: ssh ${GUEST_USER}@${MONITORING_IP}"
}

# ==========================================
# ОСНОВНОЙ ПОРЯДОК ВЫПОЛНЕНИЯ (ИСПРАВЛЕННЫЙ ПАЙПЛАЙН)
# ==========================================

clone_vm_if_needed
configure_vm
setup_data_disk_storage

# 1. Сначала запускаем машину и ждем гостевой агент
start_and_wait_vm

# 2. Расширяем системный раздел
grow_system_disk

# 3. Готовим диск данных sdb
ensure_monitoring_data_disk_ready

setup_ssh_access
audit_log "Monitoring VM ${MONITORING_VMID} setup completed successfully"