#!/usr/bin/env bash
# Диагностика GPU в LLM VM — запускать с Proxmox хоста
# Использование: bash debug-gpu-vm.sh [IP]
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-10.10.10.50}}"

echo "============================================================"
echo " GPU DIAGNOSTICS ON ${TARGET}"
echo "============================================================"

run() { echo -e "\n--- $1 ---"; guest_ssh "$TARGET" "$2" 2>&1 || echo "FAILED: $2"; }

run "NVIDIA devices in /dev" \
    "ls -la /dev/nvidia* 2>/dev/null || echo 'NO /dev/nvidia* devices!'"

run "Kernel modules" \
    "lsmod | grep -E 'nvidia|nouveau' || echo 'No nvidia/nouveau modules loaded'"

run "nvidia-smi" \
    "sudo nvidia-smi 2>&1 | head -20"

run "nvidia-smi driver version" \
    "sudo nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo 'nvidia-smi failed'"

run "cgroup version" \
    "mount | grep cgroup | head -5"

run "cgroup v2 unified?" \
    "cat /proc/mounts | grep -c cgroup2 && echo 'cgroup v2 active' || echo 'cgroup v1 or mixed'"

run "systemd cgroup setting" \
    "cat /proc/cmdline | tr ' ' '\n' | grep -i cgroup || echo 'no cgroup cmdline override'"

run "Docker info: runtime + cgroup" \
    "docker info 2>/dev/null | grep -E 'Runtime|Cgroup|Default Runtime' || echo 'docker info failed'"

run "Docker daemon.json" \
    "cat /etc/docker/daemon.json 2>/dev/null || echo 'no daemon.json'"

run "nvidia-container-cli version" \
    "nvidia-container-cli --version 2>/dev/null || echo 'not found'"

run "nvidia-container-cli info (raw)" \
    "sudo nvidia-container-cli --load-kmods info 2>&1 | head -20"

run "nvidia-ctk version" \
    "nvidia-ctk --version 2>/dev/null || echo 'not found'"

run "nvidia runtime config" \
    "cat /etc/docker/daemon.json 2>/dev/null | grep -A5 nvidia || echo 'no nvidia in daemon.json'"

run "docker run test (no GPU — sanity check)" \
    "docker run --rm alpine echo 'plain docker works'"

run "docker run --gpus all (verbose error)" \
    "docker run --rm --gpus all ubuntu:22.04 echo 'gpu ok' 2>&1 || true"

run "nvidia-container-cli standalone test" \
    "sudo nvidia-container-cli --load-kmods --debug configure --ldconfig=@/sbin/ldconfig.real --no-cgroups --device=all --require=cuda /tmp 2>&1 | head -10 || true"

echo ""
echo "============================================================"
echo " KEY THINGS TO CHECK:"
echo "  1. /dev/nvidia* exists?"
echo "  2. cgroup v2 active? (cgroup2 in mounts)"
echo "  3. Driver version matches cuda:11.6.2 requirement (>=510)?"
echo "  4. nvidia-container-cli --load-kmods info: any errors?"
echo "============================================================"
