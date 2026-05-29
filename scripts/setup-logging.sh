#!/usr/bin/env bash
# Описание: Настраивает аудит и логирование для проекта (logrotate и т.д.).
# Комментарий добавлен автоматически — дополните при необходимости.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_root

mark_step "Configuring audit logging system"

setup_audit_log_directory() {
  info "Creating audit log directory: $AUDIT_LOG_DIR"
  mkdir -p "$AUDIT_LOG_DIR"
  chmod 750 "$AUDIT_LOG_DIR"
}

install_logrotate() {
  info "Installing logrotate"
  if ! dpkg -s logrotate >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate >/dev/null 2>&1
  fi
}

configure_logrotate() {
  info "Configuring logrotate for audit logs"
  mkdir -p /etc/logrotate.d
  if [[ -f "${PROJECT_ROOT}/config/logrotate/llm-lab" ]]; then
    cp "${PROJECT_ROOT}/config/logrotate/llm-lab" /etc/logrotate.d/llm-lab
    chmod 644 /etc/logrotate.d/llm-lab
    info "Logrotate configuration installed"
  else
    warn "Logrotate config file not found at ${PROJECT_ROOT}/config/logrotate/llm-lab"
  fi
}

setup_syslog_integration() {
  info "Configuring syslog integration (optional)"
  if [[ "${ENABLE_SYSLOG:-false}" == "true" ]]; then
    cat >>/etc/rsyslog.d/50-llm-lab.conf <<'EOF'
# Audit logs from llm-lab
:msg, contains, "llm-lab" -/var/log/llm-lab/audit.log
& stop
EOF
    systemctl restart rsyslog
    info "Syslog integration enabled"
  fi
}

enable_audit_logging() {
  info "Settings audit logging environment variables"
  cat >>"${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}" <<'EOF'

# Audit logging
AUDIT_LOG_DIR=/var/log/llm-lab
ENABLE_AUDIT_LOG=true
ENABLE_SYSLOG=false
EOF
  info "Environment variables configured"
}

create_initial_log_file() {
  local log_file="$AUDIT_LOG_DIR/$(date +%Y%m%d).log"
  touch "$log_file"
  chmod 640 "$log_file"
  info "Created initial log file: $log_file"
}

display_audit_status() {
  info "Audit logging status:"
  info "  - Log directory: $AUDIT_LOG_DIR"
  info "  - Audit enabled: ${ENABLE_AUDIT_LOG:-true}"
  if [[ -d "$AUDIT_LOG_DIR" ]]; then
    info "  - Log files: $(ls -1 "$AUDIT_LOG_DIR" | wc -l)"
  fi
}

setup_audit_log_directory
install_logrotate
configure_logrotate
setup_syslog_integration
enable_audit_logging
create_initial_log_file
display_audit_status

audit_log "Audit logging system initialized"
