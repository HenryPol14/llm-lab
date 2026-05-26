# llm-lab
Proxmox LLM lab
1. Создать snippets storage
В Proxmox:
pvesm set local --content images,rootdir,vztmpl,backup,iso,snippets
2. Положить cloud-init
mkdir -p /var/lib/vz/snippets
cp cloud-init/user-data.yaml \
   /var/lib/vz/snippets/
3. Создать template
./scripts/create-template.sh
4. Создать VM
./scripts/create-llm-vm.sh 110
5. Мониторинг
./scripts/monitor-llm.sh 110
