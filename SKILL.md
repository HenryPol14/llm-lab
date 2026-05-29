# LLM-LAB ENGINEERING RULES

## Основные правила

* Не выполнять массовый рефакторинг
* Не ломать существующую логику
* Не удалять functionality без причины
* Не заменять bash другими языками
* Не добавлять тяжелые зависимости
* Все изменения делать incremental
* Сначала анализ → потом изменения
* Всегда объяснять изменения

---

## Bash Rules

Использовать:

* set -Eeuo pipefail
* shellcheck-compatible style
* readonly constants
* local variables
* snake_case

Избегать:

* unsafe rm
* curl | bash
* silent failures
* unnecessary abstractions

---

## Infrastructure Rules

Проект использует:

* Proxmox
* cloud-init
* qm
* bash automation
* nftables
* Docker

Особенно внимательно анализировать:

* scripts/
* lib/common.sh
* network automation
* YAML parsing
* VM provisioning

---

## Safety Rules

Никогда:

* не удалять VM автоматически
* не форматировать диски без explicit confirmation
* не выполнять destructive actions без DRY_RUN
* не делать cleanup автоматически

---

## Refactor Strategy

Работать поэтапно:

1. Analyze
2. Small fixes
3. Validation
4. Documentation

Не делать architectural rewrite.
