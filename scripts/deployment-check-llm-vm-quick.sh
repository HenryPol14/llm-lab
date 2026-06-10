#!/usr/bin/env bash
# Быстрый справочник и мониторинг для LLM и Monitoring VM

# ========== ПАРАМЕТРЫ ДЛЯ РЕДАКТИРОВАНИЯ ==========
LLM_VMID="${LLM_VMID:-110}"
MONITORING_VMID="${MONITORING_VMID:-120}"
LLM_IP="${LLM_IP:-10.10.10.50}"
MONITORING_IP="${MONITORING_IP:-10.10.10.60}"
GUEST_USER="${GUEST_USER:-ubuntu}"

# ========== ФУНКЦИИ ==========
check_http() {
  local name="$1"
  local url="$2"
  if curl -fsS --max-time 5 "$url" >/dev/null; then
    echo "  ✓ ${name}: OK (${url})"
  else
    echo "  ✗ ${name}: unavailable (${url})"
  fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "Проверка LLM VM (VMID: ${LLM_VMID})"
echo "═══════════════════════════════════════════════════════════════"

echo -e "\n# Статус VM"
echo "qm status ${LLM_VMID}"

echo -e "\n# Конфигурация VM"
echo "qm config ${LLM_VMID} | grep -E '^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig0):'"

echo -e "\n# Системный диск"
echo "qm config ${LLM_VMID} | grep '^scsi0:'"

echo -e "\n# Диск данных"
echo "qm config ${LLM_VMID} | grep '^scsi1:'"

echo -e "\n# IP внутри VM"
echo "qm guest exec ${LLM_VMID} -- ip -4 addr show"

echo -e "\n# Содержимое /mnt/data"
echo "qm guest exec ${LLM_VMID} -- ls -lah /mnt/data 2>/dev/null || true"

echo -e "\n# Запись fstab"
echo "qm guest exec ${LLM_VMID} -- grep '/mnt/data' /etc/fstab 2>/dev/null || true"

echo -e "\n# Проверка пользователя"
echo "qm guest exec ${LLM_VMID} -- id ${GUEST_USER}"

echo -e "\n# SSH доступ"
echo "ssh -o ConnectTimeout=5 ${GUEST_USER}@${LLM_IP} 'echo SSH OK'"

echo -e "\n═══════════════════════════════════════════════════════════════"
echo "Проверка Monitoring VM (VMID: ${MONITORING_VMID})"
echo "═══════════════════════════════════════════════════════════════"

echo -e "\n# Статус VM"
echo "qm status ${MONITORING_VMID}"

echo -e "\n# Конфигурация VM"
echo "qm config ${MONITORING_VMID} | grep -E '^(name|memory|cores|cpu|balloon|numa|agent|scsi|net|ciuser|ipconfig0):'"

echo -e "\n# Системный диск"
echo "qm config ${MONITORING_VMID} | grep '^scsi0:'"

echo -e "\n# Диск данных"
echo "qm config ${MONITORING_VMID} | grep '^scsi1:'"

echo -e "\n# IP внутри VM"
echo "qm guest exec ${MONITORING_VMID} -- ip -4 addr show"

echo -e "\n# Содержимое /mnt/data"
echo "qm guest exec ${MONITORING_VMID} -- ls -lah /mnt/data"

echo -e "\n# Запись fstab"
echo "qm guest exec ${MONITORING_VMID} -- grep '/mnt/data' /etc/fstab"

echo -e "\n# SSH доступ"
echo "ssh -o ConnectTimeout=5 ${GUEST_USER}@${MONITORING_IP} 'echo SSH OK'"

echo -e "\n═══════════════════════════════════════════════════════════════"
echo "HTTP-сервисы"
echo "═══════════════════════════════════════════════════════════════"

check_http "Ollama API" "http://${LLM_IP}:11434/api/tags"
check_http "Open WebUI" "http://${LLM_IP}:3000"
check_http "Prometheus" "http://${MONITORING_IP}:9090/-/ready"
check_http "Grafana" "http://${MONITORING_IP}:3000/api/health"

echo -e "\n═══════════════════════════════════════════════════════════════"
echo "Справка: Запустите команды ниже для диагностики"
echo "═══════════════════════════════════════════════════════════════"
