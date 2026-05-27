#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config

TARGET="${1:-${LLM_IP:-10.10.10.50}}"
REMOTE_STACK=/opt/llm-stack

info "Deploying LLM stack to ${TARGET}"
wait_for_ssh "$TARGET" 240
guest_ssh "$TARGET" "sudo mkdir -p ${REMOTE_STACK} && sudo chown ${GUEST_USER:-ubuntu}:${GUEST_USER:-ubuntu} ${REMOTE_STACK}"
scp ${SSH_OPTS:-} -r "${PROJECT_ROOT}/docker/llm/." "${GUEST_USER:-ubuntu}@${TARGET}:${REMOTE_STACK}/"
guest_ssh "$TARGET" "sudo mkdir -p /mnt/llm-data/ollama /mnt/llm-data/openwebui && cd ${REMOTE_STACK} && sudo docker compose up -d"
info "LLM stack deployed at http://${TARGET}:3000 and http://${TARGET}:11434"
