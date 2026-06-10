1. Зайти на Proxmox

ssh ai-off
2. Забрать проект на сервер
На Proxmox:

cd /root
git clone https://github.com/HenryPol14/llm-lab.git llm-lab
cd /root/llm-lab
cp config/lab.env.example config/lab.env
nano config/lab.env
Проверьте там STORAGE, WAN_BRIDGE, INTERNAL_BRIDGE, IP VM и SSH_PUBLIC_KEY.

3. Проверить базовую совместимость

chmod +x scripts/*.sh scripts/lib/*.sh
bash -n scripts/*.sh scripts/lib/*.sh
Если вдруг будут ошибки вида $'\r': command not found, значит попали CRLF-переносы. Тогда:

apt-get update && apt-get install -y dos2unix
find scripts -name '*.sh' -exec dos2unix {} \;
4. Запускать по одному шагу

DEBUG=1 bash -x scripts/infra-install-proxmox-tools.sh
DEBUG=1 bash -x scripts/infra-enable-iommu.sh
DEBUG=1 bash -x scripts/infra-configure-network.sh
DEBUG=1 bash -x scripts/vm-download-cloud-image.sh
DEBUG=1 bash -x scripts/vm-create-cloudinit-template.sh
После infra-enable-iommu.sh, если IOMMU включался впервые, лучше перезагрузить Proxmox:

reboot
Потом снова зайти и продолжить.

5. Проверить Proxmox перед созданием VM

pvesm status
ip -br addr
ip route
nft list ruleset
qm list
Особенно важно, чтобы storage из config/lab.env реально существовал.

6. Создать VM и смотреть логи

DEBUG=1 bash -x scripts/vm-create-llm-vm.sh
DEBUG=1 bash -x scripts/vm-create-monitoring-vm.sh
qm list
qm config 110
qm config 120
7. Деплой внутри VM

DEBUG=1 bash -x scripts/deployment-install-guest-runtime-llm.sh 10.10.10.50
DEBUG=1 bash -x scripts/deployment-install-nvidia-toolkit-llm.sh 10.10.10.50
DEBUG=1 bash -x scripts/deployment-install-guest-runtime-monitoring.sh 10.10.10.60
DEBUG=1 bash -x scripts/deployment-deploy-monitoring-stack.sh 10.10.10.50
8. Финальная проверка

bash scripts/vm-verify-monitoring-vm.sh
bash scripts/infra-audit-network.sh
curl http://10.10.10.50:11434/api/tags
curl http://10.10.10.60:9090/-/ready
curl http://10.10.10.60:3000/api/health

Главная идея: сначала довести до зелёного состояния host/network/template, потом VM, потом Docker stack. run-all.sh лучше запускать только после того, как отдельные шаги уже один раз прошли.