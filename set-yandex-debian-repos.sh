#!/usr/bin/env bash
set -euo pipefail

FILE="/etc/apt/sources.list.d/debian.sources"
BACKUP="/etc/apt/sources.list.d/debian.sources.bak.$(date +%Y%m%d-%H%M%S)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root."
  exit 1
fi

if [ -f "$FILE" ]; then
  cp -a "$FILE" "$BACKUP"
  echo "Резервная копия создана: $BACKUP"
else
  echo "Файл $FILE не найден, будет создан заново."
fi

cat > "$FILE" <<'EOF'
Types: deb
URIs: https://mirror.yandex.ru/debian
Suites: trixie trixie-updates trixie-backports
Components: contrib main non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: contrib main non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

echo
echo "Новый файл $FILE:"
echo "----------------------------------------"
cat "$FILE"
echo "----------------------------------------"
echo

apt update
