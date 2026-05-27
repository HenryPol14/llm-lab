На этой стадии работа с развернутыми моделями предполагается через SSH tunnel

Схема
VSCode, browser
   ↓
localhost:11434
   ↓ SSH tunnel
Proxmox
   ↓
10.10.10.50:11434
   ↓
Ollama

Как использовать:
Обычный SSH
ssh ai-off

Поднять LLM tunnel
В отдельном окне
ssh ai-llm
Окно оставить открытым

После этого локально доступны
Ollama API
http://localhost:11434

Open WebUI
http://localhost:3000

Проверка
curl http://localhost:11434/api/tags

Для VSCode / Continue / Cline
Base URL:
http://localhost:11434

или OpenAI-compatible:
http://localhost:11434/v1

Потом можно настроить мршрутизируемую подсеть, reverse proxy или ВПН.
WireGuard VPN
Tailscale
routed subnet
reverse proxy
Cloudflare Tunnel