#!/usr/bin/env bash
# Устанавливаем строгий режим:
# -E: ошибки наследуются функцией ловушки ERR
# -e: немедленный выход при ошибке
# -u: ошибка при использовании неопределенных переменных
# -o pipefail: ошибка в пайплайне, если любая команда завершилась неудачно
set -Eeuo pipefail

# Определяем корневую директорию проекта
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Путь к файлу конфигурации (устаревший .env формат, если не задан)
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/lab.env}"
# Путь к файлу конфигурации (предпочтительный YAML формат, если не задан)
CONFIG_YAML="${CONFIG_YAML:-${PROJECT_ROOT}/config/infra.yaml}"

# Директория для логов аудита (если не задано, используется /var/log/llm-lab)
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/llm-lab}"
# Флаг сухого запуска (если true, команды не выполняются, только логируются)
DRY_RUN="${DRY_RUN:-false}"
# Флаг принудительной пересборки (0 - нет, 1 - да)
FORCE_REBUILD="${FORCE_REBUILD:-0}"

# Функция для логирования сообщений с отметкой времени
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
# Функция для вывода информационных сообщений
info() { log "INFO: $*"; }
# Функция для вывода предупреждений (направляется в stderr)
warn() { log "WARN: $*" >&2; }
# Функция для вывода ошибок и завершения скрипта с кодом 1 (направляется в stderr)
die() { log "ERROR: $*" >&2; exit 1; }

# Функция для записи сообщений в аудит-лог
audit_log() {
  # Проверяем, включено ли логирование аудита (по умолчанию true)
  if [[ "${ENABLE_AUDIT_LOG:-true}" == "true" ]]; then
    # Создаем директорию для логов аудита, если она не существует
    mkdir -p "$AUDIT_LOG_DIR"
    # Определяем имя файла лога аудита (ежедневный лог)
    local log_file
    log_file="$AUDIT_LOG_DIR/$(date +%Y%m%d).log"
    # Записываем сообщение в лог-файл с отметкой времени
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file"
  fi
}

# Функция, вызываемая при ошибке (EXIT, ERR)
on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  local script_name="${BASH_SOURCE[1]:-script}"
  # Логируем ошибку в stderr
  log "ERROR: ${script_name} failed at line ${line_no} with exit code ${exit_code}" >&2
  # Записываем ошибку в аудит-лог
  audit_log "ERROR: ${script_name}:${line_no} exit ${exit_code}"
  # Завершаем скрипт с кодом ошибки
  exit "$exit_code"
}
# Устанавливаем ловушку для перехвата ошибок (ERR) и вызова функции on_error
trap on_error ERR

# Функция, требующая запуска скрипта от имени root
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root."
}

# Функция, проверяющая наличие команды в системе
# Аргументы: $1 - имя команды
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# Функция, проверяющая наличие утилиты yq (для парсинга YAML)
require_yq() {
  require_cmd yq || die "yq is required for YAML config parsing. Install: https://github.com/mikefarah/yq"
}

# Функция для получения значения из YAML-файла по указанному запросу (yq)
# Аргументы: $1 - yq-запрос
yaml_get() {
  local query="$1"
  local value
  # Выполняем yq-запрос к файлу CONFIG_YAML
  value="$(yq -r "$query" "$CONFIG_YAML")"
  # Если yq вернул "null", заменяем его на пустую строку
  if [[ "$value" == "null" ]]; then
    value=""
  fi
  # Выводим полученное значение
  printf '%s' "$value"
}

# Функция для валидации отдельной сетевой переменной
# Аргументы: $1 - имя переменной, $2 - значение переменной
validate_network_variable() {
  local name="$1"
  local value="$2"

  # Проверяем, что значение не пустое
  [[ -n "$value" ]] || die "Network config value $name is required and must not be empty"
  # Проверяем, что значение не содержит кавычек (потенциально небезопасно)
  [[ "$value" != *"\""* ]] || die "Invalid quoted value loaded for $name: $value"
}

# Функция для валидации всех сетевых настроек
validate_network_config() {
  # Валидируем каждую из необходимых сетевых переменных
  validate_network_variable INTERNAL_BRIDGE "$INTERNAL_BRIDGE"
  validate_network_variable WAN_BRIDGE "$WAN_BRIDGE"
  validate_network_variable INTERNAL_CIDR "$INTERNAL_CIDR"
  validate_network_variable INTERNAL_SUBNET "$INTERNAL_SUBNET"
  validate_network_variable INTERNAL_GATEWAY "$INTERNAL_GATEWAY"

  # Проверяем формат имени внутреннего моста
  [[ "$INTERNAL_BRIDGE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid bridge name: $INTERNAL_BRIDGE"
  # Проверяем формат имени WAN моста
  [[ "$WAN_BRIDGE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid bridge name: $WAN_BRIDGE"
  # Проверяем формат внутренней подсети (CIDR)
  [[ "$INTERNAL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid subnet format: $INTERNAL_SUBNET"
  # Проверяем формат внутреннего CIDR
  [[ "$INTERNAL_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid CIDR format: $INTERNAL_CIDR"
  # Проверяем формат внутреннего шлюза
  [[ "$INTERNAL_GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid gateway address: $INTERNAL_GATEWAY"
}

# Функция для генерации конфигурации nftables для белого списка
nftables_whitelist_config() {
  cat <<EOF
# Таблица правил nftables для llm_lab
table inet llm_lab {
  # Цепочка postrouting для NAT (Source NAT)
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    # Разрешить только определенным сервисам доступ в интернет (DNS, HTTPS)
    ip saddr ${LLM_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${LLM_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade

    ip saddr ${MONITORING_IP} ip daddr 8.8.8.8/32 tcp dport { 53, 443 } masquerade
    ip saddr ${MONITORING_IP} ip daddr 1.1.1.1/32 tcp dport { 53, 443 } masquerade

    # Запретить весь остальной исходящий трафик из внутренней подсети в WAN
    ip saddr ${INTERNAL_SUBNET} oifname "${WAN_BRIDGE}" drop
  }

  # Цепочка forward для фильтрации транзитного трафика
  chain forward {
    type filter hook forward priority 0; policy drop;

    # Разрешить входящие соединения к сервисам LLM VM (порты 3000, 11434)
    ip daddr ${LLM_IP} tcp dport { 3000, 11434 } accept

    # Разрешить входящие соединения к сервисам Monitoring VM (порты 3000, 9090)
    ip daddr ${MONITORING_IP} tcp dport { 3000, 9090 } accept

    # Разрешить установленные и связанные соединения
    ct state established,related accept

    # Запретить коммуникацию между VM во внутренней подсети
    ip saddr ${INTERNAL_SUBNET} ip daddr ${INTERNAL_SUBNET} drop
  }

  # Цепочка input для входящего трафика на хост
  chain input {
    type filter hook input priority 0; policy accept;
  }

  # Цепочка output для исходящего трафика с хоста
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF
}

# Функция для отметки начала шага в логах и аудите
mark_step() {
  audit_log "STEP_START: $*"
  info "━━━ $* ━━━"
}

# Функция, требующая наличия указанного хранилища Proxmox VE
# Аргументы: $1 - имя хранилища
# Функция, требующая наличия указанного хранилища Proxmox VE
# Аргументы: $1 - имя хранилища
require_pve_storage() {
  local storage="$1"
  # Проверяем наличие команды pvesm
  require_cmd pvesm
  # Проверяем, существует ли указанное хранилище в Proxmox
  pvesm status | awk 'NR > 1 {print $1}' | grep -qxF "$storage" || die "Proxmox storage not found: $storage"
}

# Функция, утверждающая, что переменная установлена (не пуста)
# Аргументы: $1 - имя переменной (строка)
assert_var_set() {
  [[ -n "${!1}" ]] || die "Variable $1 is not set"
}

# Функция для проверки, выполняется ли скрипт в режиме сухого запуска
is_dry_run() {
  [[ "$DRY_RUN" == "true" ]]
}

# Функция для установки отсутствующих пакетов Debian/Ubuntu
# Аргументы: $@ - список пакетов для установки
install_missing_packages() {
  local missing=()
  local pkg
  # Проверяем каждый пакет на наличие
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  # Если есть отсутствующие пакеты, устанавливаем их
  if ((${#missing[@]})); then
    info "Installing packages: ${missing[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

# Функция для гарантированного наличия строки в файле
# Аргументы: $1 - строка, $2 - путь к файлу
ensure_line() {
  local line="$1"
  local file="$2"
  # Создаем файл, если он не существует
  touch "$file" || true
  # Если строка отсутствует в файле, добавляем ее
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# Функция для проверки существования VM по ее ID
# Аргументы: $1 - ID VM
vm_exists() {
  qm config "$1" >/dev/null 2>&1
}

# Функция для проверки, запущена ли VM по ее ID
# Аргументы: $1 - ID VM
vm_running() {
  qm status "$1" 2>/dev/null | grep -q 'running' || false || true
}

# Функция для ожидания готовности гостевого агента на VM
# Аргументы: $1 - ID VM, $2 - таймаут в секундах (по умолчанию 180)
guest_is_ready() {
  local vmid="$1"
  local timeout="${2:-180}"
  local waited=0
  info "Waiting for guest agent on VM ${vmid}"
  # Цикл ожидания, пока гостевой агент не будет готов
  until qm guest exec "$vmid" -- true >/dev/null 2>&1; do
    sleep 3
    ((waited += 3))
    # Проверяем таймаут
    if ((waited >= timeout)); then
      die "Guest agent not ready on VM ${vmid} after ${timeout}s"
    fi
  done
}

# Функция для ожидания завершения работы cloud-init на VM
# Аргументы: $1 - ID VM, $2 - таймаут в секундах (по умолчанию 300)
wait_for_cloud_init() {
  local vmid="$1"
  local timeout="${2:-300}"
  local waited=0
  info "Waiting for cloud-init completion on VM ${vmid}"
  # Цикл ожидания, пока cloud-init не завершится (по наличию файла /var/lib/cloud/boot-finished)
  until qm guest exec "$vmid" -- test -f /var/lib/cloud/boot-finished >/dev/null 2>&1; do
    sleep 5
    ((waited += 5))
    # Проверяем таймаут
    if ((waited >= timeout)); then
      die "cloud-init did not finish on VM ${vmid} after ${timeout}s"
    fi
  done
}

# Функция для парсинга вывода команды qm guest exec
# Аргументы: $1 - сырой вывод команды
# Возвращает: очищенную строку вывода
parse_qm_guest_exec_output() {
  local raw="$1"
  # Проверяем, содержит ли вывод JSON-подобную структуру с "out-data"
  if [[ "$raw" == *'"out-data"'* ]]; then
    local parsed
    # Извлекаем и очищаем данные из "out-data"
    parsed="$(printf '%s
' "$raw" | grep '"out-data"' | sed -e 's/^.*"out-data"[[:space:]]*:[[:space:]]*"//' -e 's/"[[:space:]]*,[[:space:]]*"[^"]*"[[:space:]]*:.*$//' -e 's/"[[:space:]]*}[[:space:]]*$//' -e 's/"[,]$//' -e 's/"$//')"
    if [[ -n "$parsed" ]]; then
      # Удаляем завершающие символы новой строки и заменяем внутренние на пробелы
      parsed="${parsed%\\n}"
      parsed="${parsed//\\n/ }"
      printf '%s' "$parsed"
      return
    fi
  fi
  # Если "out-data" не найдено или пусто, возвращаем исходный сырой вывод
  printf '%s' "$raw"
}

# Функция для парсинга stderr из вывода команды qm guest exec
# Аргументы: $1 - сырой вывод команды
parse_qm_guest_exec_error() {
  local raw="$1"
  local parsed

  parsed="$(printf '%s\n' "$raw" | grep '"err-data"' | sed -e 's/^.*"err-data"[[:space:]]*:[[:space:]]*"//' -e 's/"[[:space:]]*,[[:space:]]*"[^"]*"[[:space:]]*:.*$//' -e 's/"[[:space:]]*}[[:space:]]*$//' -e 's/"[,]$//' -e 's/"$//')" || true || true
  if [[ -n "$parsed" ]]; then
    parsed="${parsed%\\n}"
    parsed="${parsed//\\n/ }"
    printf '%s' "$parsed"
  fi
}

# Функция для извлечения exitcode из JSON-подобного вывода qm guest exec
# Аргументы: $1 - сырой вывод команды qm guest exec
parse_qm_guest_exec_exitcode() {
  local raw="$1"
  local exitcode

  exitcode="$(printf '%s\n' "$raw" | sed -nE 's/.*"exitcode"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n1)" || true
  printf '%s' "${exitcode:-0}"
}

# Функция для проверки успешности qm guest exec по вложенному exitcode
# Аргументы: $1 - сырой вывод команды, $2 - описание операции
assert_qm_guest_exec_success() {
  local raw="$1"
  local context="${2:-qm guest exec}"
  local exitcode

  exitcode="$(parse_qm_guest_exec_exitcode "$raw")"
  if [[ "$exitcode" != "0" ]]; then
    local err
    err="$(parse_qm_guest_exec_error "$raw")"
    warn "$context failed inside guest with exitcode ${exitcode}"
    warn "Guest output: $(parse_qm_guest_exec_output "$raw")"
    if [[ -n "$err" ]]; then
      warn "Guest error: $err"
    fi
    return 1
  fi
}

# Функция для проверки статуса работы системы внутри VM
# Аргументы: $1 - ID VM
# Возвращает: 0 если система работает или находится в приемлемом состоянии, 1 в противном случае
check_system_running() {
  local vmid="$1"
  local result
  local state
  # Выполняем команду systemctl is-system-running внутри VM
  result="$(qm guest exec "$vmid" -- systemctl is-system-running 2>/dev/null)" || {
    warn "System running check failed on VM ${vmid}"
    return 1
  }
  # Парсим вывод и очищаем от символов переноса строки
  state="$(parse_qm_guest_exec_output "$result")"
  state="${state//$'\r'/}"
  state="${state//$'\n'/}"
  # Анализируем состояние системы
  case "$state" in
    running* )
      info "System is running on VM ${vmid}: ${state}"
      return 0
      ;;
    degraded|starting|starting* )
      warn "System state on VM ${vmid}: ${state} (continuing)"
      return 0
      ;;
    *)
      warn "System state on VM ${vmid}: ${state}"
      return 1
      ;;
  esac
}

# Функция для проверки сетевого IP-адреса гостевой VM
# Аргументы: $1 - ID VM, $2 - ожидаемый IP-адрес, $3 - таймаут в секундах (по умолчанию 120)
# Возвращает: 0 если IP найден, 1 в противном случае
check_guest_network() {
  local vmid="$1"
  local expected_ip="$2"
  local timeout="${3:-120}"
  local waited=0
  info "Verifying guest network IP ${expected_ip} on VM ${vmid}"
  # Бесконечный цикл ожидания
  while :; do
    local result
    # Выполняем команду 'ip -4 addr show' внутри VM
    result="$(qm guest exec "$vmid" -- ip -4 addr show 2>/dev/null)" || {
      sleep 3
      ((waited+=3))
      # Проверяем таймаут, если команда 'ip' не выполняется
      if ((waited>=timeout)); then
        warn "Guest ${vmid} network check failed to run 'ip' inside guest"
        return 1
      fi
      continue
    }
    local out
    # Парсим вывод и проверяем наличие ожидаемого IP
    out="$(parse_qm_guest_exec_output "$result")"
    if printf '%s' "$out" | grep -q -- "$expected_ip"; then
      info "Guest ${vmid} has IP ${expected_ip}"
      return 0
    fi
    sleep 3
    ((waited+=3))
    # Проверяем таймаут, если IP не найден
    if ((waited>=timeout)); then
      warn "Guest ${vmid} missing IP ${expected_ip} after ${timeout}s"
      return 1
    fi
  done
}

# Функция для валидации PCI-устройства (для проброса GPU)
# Аргументы: $1 - адрес PCI-устройства
validate_pci_device() {
  local pci_addr="$1"
  # Требуем наличия команды lspci
  require_cmd lspci
  if [[ -n "$pci_addr" ]]; then
    # Проверяем, существует ли указанное PCI-устройство
    if ! lspci -s "$pci_addr" >/dev/null 2>&1; then
      die "PCI device not found: $pci_addr"
    fi
    # FLR is a reset capability, not an "in use" flag. Warn on host GPU drivers instead.
    local kernel_driver
    kernel_driver="$(lspci -s "$pci_addr" -k 2>/dev/null | awk -F': ' '/Kernel driver in use:/ {print $2; exit}')"
    if [[ -n "$kernel_driver" && "$kernel_driver" != "vfio-pci" ]]; then
      warn "PCI device $pci_addr is currently bound to host driver '$kernel_driver'; passthrough may require vfio-pci binding"
    fi
    info "Validated PCI device: $pci_addr"
  else
    warn "No PCI device address provided"
  fi
}

# Функция для нормализации размера диска в ГБ (удаляет 'G' или 'GB')
# Аргументы: $1 - строка размера диска (например, "100G" или "100GB")
# Возвращает: числовое значение размера диска в ГБ
normalize_gb() {
  local value="$1"
  value="${value%G}"
  value="${value%GB}"
  # Проверяем, что оставшееся значение является числом
  [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid disk size: $1"
  echo "$value"
}

# Функция для загрузки конфигурации из YAML-файла
load_yaml_config() {
  # Проверяем наличие утилиты yq
  require_yq
  # Если файл конфигурации существует
  if [[ -f "$CONFIG_YAML" ]]; then
    info "Loading YAML config from $CONFIG_YAML"
 # Экспортируем переменные из YAML-файла, используя yaml_get
 # 1. Объявляем переменные для экспорта
export LLM_NAME LLM_IP LLM_PREFIX LLM_MEMORY_MB LLM_CORES LLM_SYSTEM_DISK_GB LLM_DATA_DISK_GB
export MONITORING_VMID MONITORING_NAME MONITORING_IP MONITORING_PREFIX MONITORING_MEMORY_MB MONITORING_CORES MONITORING_SYSTEM_DISK_GB MONITORING_DATA_DISK_GB
export INTERNAL_BRIDGE INTERNAL_GATEWAY DNS_SERVER INTERNAL_CIDR INTERNAL_SUBNET WAN_BRIDGE
export TEMPLATE_VMID TEMPLATE_STORAGE LLM_STORAGE MONITORING_STORAGE GUEST_USER SSH_OPTS
export GPU_PCI_ADDR GPU_PASSTHROUGH FIREWALL_ENABLED LOGGING_ENABLED AUDIT_ENABLED
export PROXMOX_HOST PROXMOX_USER
export NGINX_CTID NGINX_HOSTNAME NGINX_STORAGE NGINX_DISK_GB NGINX_MEMORY_MB NGINX_CORES NGINX_WAN_IP NGINX_WAN_GW LXC_TEMPLATE

# 2. Спокойно присваиваем значения без замечаний от ShellCheck
LLM_NAME="$(yaml_get '.llm_vm.name')"
LLM_IP="$(yaml_get '.llm_vm.ip')"
LLM_PREFIX="$(yaml_get '.llm_vm.prefix')"
LLM_MEMORY_MB="$(yaml_get '.llm_vm.memory_mb')"
LLM_CORES="$(yaml_get '.llm_vm.cores')"
LLM_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.system_disk_gb')")"
LLM_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.llm_vm.data_disk_gb')")"
MONITORING_VMID="$(yaml_get '.monitoring_vm.vmid')"
MONITORING_NAME="$(yaml_get '.monitoring_vm.name')"
MONITORING_IP="$(yaml_get '.monitoring_vm.ip')"
MONITORING_PREFIX="$(yaml_get '.monitoring_vm.prefix')"
MONITORING_MEMORY_MB="$(yaml_get '.monitoring_vm.memory_mb')"
MONITORING_CORES="$(yaml_get '.monitoring_vm.cores')"
MONITORING_SYSTEM_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.system_disk_gb')")"
MONITORING_DATA_DISK_GB="$(normalize_gb "$(yaml_get '.monitoring_vm.data_disk_gb')")"
INTERNAL_BRIDGE="$(yaml_get '.network.internal_bridge')"
INTERNAL_GATEWAY="$(yaml_get '.network.internal_gateway')"
DNS_SERVER="$(yaml_get '.network.dns_server')"
INTERNAL_CIDR="$(yaml_get '.network.internal_cidr')"
INTERNAL_SUBNET="$(yaml_get '.network.internal_subnet')"
WAN_BRIDGE="$(yaml_get '.network.wan_bridge')"
TEMPLATE_VMID="$(yaml_get '.template.vmid')"
TEMPLATE_STORAGE="$(yaml_get '.template.storage')"
LLM_STORAGE="$(yaml_get '.storage.llm')"
MONITORING_STORAGE="$(yaml_get '.storage.monitoring')"
GUEST_USER="$(yaml_get '.guest.user')"
SSH_OPTS="$(yaml_get '.guest.ssh_opts')"
GPU_PCI_ADDR="$(yaml_get '.llm_vm.gpu_pci_addr')"
GPU_PASSTHROUGH="$(yaml_get '.features.gpu_passthrough')"
FIREWALL_ENABLED="$(yaml_get '.features.firewall_enabled')"
LOGGING_ENABLED="$(yaml_get '.features.logging_enabled')"
AUDIT_ENABLED="$(yaml_get '.features.audit_enabled')"
PROXMOX_HOST="$(yaml_get '.proxmox.host')"
PROXMOX_USER="$(yaml_get '.proxmox.user')"
NGINX_CTID="$(yaml_get '.nginx_proxy.ctid')"
NGINX_HOSTNAME="$(yaml_get '.nginx_proxy.hostname')"
NGINX_STORAGE="$(yaml_get '.nginx_proxy.storage')"
NGINX_DISK_GB="$(yaml_get '.nginx_proxy.disk_gb')"
NGINX_MEMORY_MB="$(yaml_get '.nginx_proxy.memory_mb')"
NGINX_CORES="$(yaml_get '.nginx_proxy.cores')"
NGINX_WAN_IP="$(yaml_get '.nginx_proxy.wan_ip')"
NGINX_WAN_GW="$(yaml_get '.nginx_proxy.wan_gw')"
LXC_TEMPLATE="$(yaml_get '.nginx_proxy.lxc_template')"
    # Валидируем сетевые настройки
    validate_network_config
    audit_log "Loaded YAML config"
  else
    warn "YAML config not found: $CONFIG_YAML. Falling back to environment variables."
  fi
}

# Функция для загрузки устаревшей конфигурации из .env файла (устаревший метод)
load_legacy_config() {
  # Если файл конфигурации существует
  if [[ -f "$CONFIG_FILE" ]]; then
    set -a # Экспортировать все переменные, определенные или модифицированные
    warn "Loading legacy config from $CONFIG_FILE (deprecated, use YAML)"
    source "$CONFIG_FILE"
    set +a # Отключить автоматический экспорт
    audit_log "Loaded legacy config"
  fi
}

# Главная функция для загрузки конфигурации (предпочитает YAML, затем .env)
load_config() {
  if [[ -f "$CONFIG_YAML" ]]; then
    load_yaml_config
  elif [[ -f "$CONFIG_FILE" ]]; then
    load_legacy_config
  else
    die "No config file found. Create $CONFIG_YAML or $CONFIG_FILE"
  fi
}

# Функция-обертка для выполнения команд qm (Proxmox)
# Аргументы: $@ - аргументы для команды qm
qm_command() {
  local cmd=("qm" "$@")
  # Если включен режим сухого запуска, логируем команду вместо выполнения
  if is_dry_run; then
    info "[DRY RUN] Would run: ${cmd[*]}"
    return 0
  else
    audit_log "Executing: ${cmd[*]}"
    "${cmd[@]}"
  fi
}

# Функция для выполнения SSH-команд на гостевой VM
# Аргументы: $1 - IP-адрес/хост гостевой VM, $@ - команды для выполнения на VM
guest_ssh() {
  local host="$1"
  shift
  # Опции SSH (по умолчанию: не проверять ключи хоста)
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"
  local cmd=("ssh" "$opts" "${GUEST_USER:-ubuntu}@${host}" "$@")
  # Если включен режим сухого запуска, логируем команду вместо выполнения
  if is_dry_run; then
    info "[DRY RUN] Would run: ${cmd[*]}"
    return 0
  else
    audit_log "SSH to ${host}: $*"
    ssh "$opts" "${GUEST_USER:-ubuntu}@${host}" "$@"
  fi
}

# Функция для ожидания готовности SSH на гостевой VM
# Аргументы: $1 - IP-адрес/хост гостевой VM, $2 - таймаут в секундах (по умолчанию 180)
wait_for_ssh() {
  local host="$1"
  local timeout="${2:-180}"
  local waited=0
  local opts="${SSH_OPTS:--o StrictHostKeyChecking=accept-new}"

  info "Waiting for SSH on ${GUEST_USER:-ubuntu}@${host}"
  while :; do
    if ssh ${opts} -o ConnectTimeout=5 -o BatchMode=yes "${GUEST_USER:-ubuntu}@${host}" true >/dev/null 2>&1; then
      info "SSH is ready on ${host}"
      return 0
    fi

    sleep 3
    ((waited += 3))
    if ((waited >= timeout)); then
      die "SSH not ready on ${host} after ${timeout}s"
    fi
  done
}