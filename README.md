# scripts

Набор полезных скриптов для Debian 13, в основном для LXC-контейнеров.

В репозитории собраны простые скрипты для быстрой настройки, обновления и обслуживания системы.

## Что есть

Сейчас в репозитории есть скрипты для:

- установки и обновления Homepage
- настройки зеркал Яндекса для Debian

## Quick Start

### Установка / обновление Homepage

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Kemper51rus/scripts/main/install-update-homepage.sh)
```

### Настройка Yandex зеркал Debian

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Kemper51rus/scripts/main/set-yandex-debian-repos.sh)
```

## Требования

- Debian 13
- bash
- доступ в интернет
- запуск от `root` или через `sudo` при необходимости

## Примечание

Скрипты ориентированы в первую очередь на использование в LXC, но часть из них может подойти и для обычного Debian-сервера.
