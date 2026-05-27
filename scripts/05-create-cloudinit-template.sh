#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-${STORAGE:-SSD-VMs}}"
UBUNTU_IMAGE_PATH="${UBUNTU_IMAGE_PATH:-/var/lib/vz/template/qcow2/ubuntu-noble.img}"
PREPARED_IMAGE_PATH="${PREPARED_IMAGE_PATH:-/var/lib/vz/template/qcow2/ubuntu-noble-llm-prepared.img}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_rsa.pub}"
INTERNAL_BRIDGE="${INTERNAL_BRIDGE:-vmbr1}"

require_cmd qm
require_cmd virt-customize
require_pve_storage "$TEMPLATE_STORAGE"
[[ -f "$UBUNTU_IMAGE_PATH" ]] || die "Cloud image not found: $UBUNTU_IMAGE_PATH"
[[ -f "$SSH_PUBLIC_KEY" ]] || die "SSH public key not found: $SSH_PUBLIC_KEY"

if vm_exists "$TEMPLATE_VMID"; then
  if [[ "${FORCE_REBUILD:-0}" == "1" ]]; then
    warn "FORCE_REBUILD=1: destroying existing template ${TEMPLATE_VMID}"
    qm destroy "$TEMPLATE_VMID" --purge
  else
    info "Template ${TEMPLATE_VMID} already exists. Updating cloud-init SSH key only."
    qm set "$TEMPLATE_VMID" --ciuser ubuntu --sshkey "$SSH_PUBLIC_KEY"
    exit 0
  fi
fi

if [[ ! -f "$PREPARED_IMAGE_PATH" || "${FORCE_REBUILD:-0}" == "1" ]]; then
  info "Preparing cloud image with guest packages: ${PREPARED_IMAGE_PATH}"
  cp "$UBUNTU_IMAGE_PATH" "$PREPARED_IMAGE_PATH"
  virt-customize -a "$PREPARED_IMAGE_PATH" \
    --install qemu-guest-agent,cloud-init,docker.io,htop,curl,git,jq,nvtop,pciutils,cloud-guest-utils,gdisk,parted,ca-certificates,gnupg,lsb-release \
    --run-command 'systemctl enable qemu-guest-agent' \
    --run-command 'systemctl enable docker' \
    --run-command 'mkdir -p /etc/sysctl.d' \
    --run-command 'printf "vm.swappiness=5\nvm.max_map_count=1048576\nfs.inotify.max_user_watches=1048576\n" >/etc/sysctl.d/99-llm-lab.conf' \
    --run-command 'cloud-init clean' \
    --truncate /etc/machine-id \
    --run-command 'rm -f /var/lib/dbus/machine-id'
else
  info "Prepared image already exists: ${PREPARED_IMAGE_PATH}"
fi

info "Creating VM ${TEMPLATE_VMID} from prepared cloud image"
qm create "$TEMPLATE_VMID" \
  --name ubuntu-llm-template \
  --ostype l26 \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --agent enabled=1 \
  --net0 "virtio,bridge=${INTERNAL_BRIDGE}"

qm set "$TEMPLATE_VMID" --efidisk0 "${TEMPLATE_STORAGE}:0,efitype=4m,pre-enrolled-keys=0"
qm importdisk "$TEMPLATE_VMID" "$PREPARED_IMAGE_PATH" "$TEMPLATE_STORAGE"
DISK_VOL="$(qm config "$TEMPLATE_VMID" | awk '/unused0:/ {print $2}' | cut -d, -f1)"
qm set "$TEMPLATE_VMID" --scsihw virtio-scsi-single --scsi0 "${DISK_VOL},discard=on,ssd=1"
qm set "$TEMPLATE_VMID" --ide2 "${TEMPLATE_STORAGE}:cloudinit"
qm set "$TEMPLATE_VMID" --boot order=scsi0
qm set "$TEMPLATE_VMID" --serial0 socket --vga serial0
qm set "$TEMPLATE_VMID" --ciuser ubuntu --sshkey "$SSH_PUBLIC_KEY" --ipconfig0 ip=dhcp

qm template "$TEMPLATE_VMID"
info "Template ${TEMPLATE_VMID} is ready"
