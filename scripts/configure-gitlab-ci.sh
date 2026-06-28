#!/bin/bash
# Script to configure GitLab CI/CD variables for llm-lab project

echo "Configuring GitLab CI/CD variables..."

# Check if PROXMOX_HOST is set
if [[ -z "$PROXMOX_HOST" ]]; then
    echo "ERROR: PROXMOX_HOST environment variable is not set"
    echo "Please run: export PROXMOX_HOST=77.50.132.85"
    exit 1
fi

# Check if PROXMOX_USER is set
if [[ -z "$PROXMOX_USER" ]]; then
    echo "ERROR: PROXMOX_USER environment variable is not set"
    echo "Please run: export PROXMOX_USER=root"
    exit 1
fi

# Check if SSH_PRIVATE_KEY is set
if [[ -z "$SSH_PRIVATE_KEY" ]]; then
    echo "ERROR: SSH_PRIVATE_KEY environment variable is not set"
    echo "Please run: export SSH_PRIVATE_KEY='$(cat ~/.ssh/ai-off_id_rsa)'"
    exit 1
fi

# Set GitLab variables
glab variable set PROXMOX_HOST "$PROXMOX_HOST" --description "Proxmox host IP"
glab variable set PROXMOX_USER "$PROXMOX_USER" --description "Proxmox user (usually root)"
glab variable set SSH_PRIVATE_KEY "$SSH_PRIVATE_KEY" --masked --protected --description "SSH private key for Proxmox access"
glab variable set SSH_HOST_KEY "$(ssh-keyscan -p 60022 $PROXMOX_HOST 2>/dev/null)" --description "SSH host key for Proxmox"
glab variable set LLM_IP "10.10.10.50" --description "LLM VM internal IP"
glab variable set MONITORING_IP "10.10.10.60" --description "Monitoring VM internal IP"
glab variable set NGINX_IP "10.10.10.70" --description "Nginx proxy internal IP"

echo "GitLab CI/CD variables configured successfully!"
echo ""
echo "You can view them with: glab variable list"
