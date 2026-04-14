#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/homepage"
APP_USER="homepage"
APP_GROUP="homepage"
APP_PORT="3000"
APP_HOST="127.0.0.1"
SERVICE_NAME="homepage"
NGINX_SITE_NAME="homepage"
DEFAULT_REPO="https://github.com/gethomepage/homepage.git"
ENV_FILE="/etc/default/homepage"
SELF_INSTALL_PATH="/bin/update"

log() {
  echo
  echo "[*] $1"
}

warn() {
  echo
  echo "[!] $1"
}

fail() {
  echo
  echo "[x] $1" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Запустите скрипт от root"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_self_to_bin() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  if [ ! -f "$src" ]; then
    warn "Не удалось определить путь к текущему скрипту, пропускаю установку в ${SELF_INSTALL_PATH}"
    return
  fi

  if [ "$src" != "$SELF_INSTALL_PATH" ]; then
    log "Копирую скрипт в ${SELF_INSTALL_PATH}"
    cp -f "$src" "$SELF_INSTALL_PATH"
    chmod 755 "$SELF_INSTALL_PATH"
  fi
}

read_current_hosts() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi
  echo "${HOMEPAGE_ALLOWED_HOSTS:-}"
}

ask_hosts_install() {
  echo
  echo "Введите HOMEPAGE_ALLOWED_HOSTS"
  echo "Примеры:"
  echo "  jexum.ru"
  echo "  jexum.ru,localhost:3000,127.0.0.1:3000"
  read -r -p "HOMEPAGE_ALLOWED_HOSTS: " HOMEPAGE_ALLOWED_HOSTS
  [ -n "${HOMEPAGE_ALLOWED_HOSTS:-}" ] || fail "HOMEPAGE_ALLOWED_HOSTS не задан"
}

ask_hosts_update() {
  local current_hosts
  current_hosts="$(read_current_hosts)"

  echo
  echo "Текущий HOMEPAGE_ALLOWED_HOSTS: ${current_hosts:-<не задан>}"
  echo "1) Оставить текущий"
  echo "2) Ввести новый"
  read -r -p "Выберите вариант [1-2]: " host_choice

  case "$host_choice" in
    1)
      HOMEPAGE_ALLOWED_HOSTS="$current_hosts"
      [ -n "${HOMEPAGE_ALLOWED_HOSTS:-}" ] || fail "Текущий HOMEPAGE_ALLOWED_HOSTS пуст"
      ;;
    2)
      ask_hosts_install
      ;;
    *)
      fail "Неверный выбор"
      ;;
  esac
}

get_primary_host() {
  echo "$1" | cut -d',' -f1
}

ensure_packages() {
  log "Устанавливаю системные пакеты"
  apt update
  apt install -y \
    git \
    curl \
    ca-certificates \
    build-essential \
    nodejs \
    npm \
    nginx \
    sudo
}

ensure_pnpm() {
  if ! command_exists pnpm; then
    log "Устанавливаю pnpm"
    npm install -g pnpm
  else
    log "pnpm уже установлен: $(pnpm -v)"
  fi
}

ensure_user() {
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    log "Создаю пользователя ${APP_USER}"
    useradd -r -m -d "$APP_DIR" -s /bin/bash "$APP_USER"
  else
    log "Пользователь ${APP_USER} уже существует"
  fi
}

clone_repo() {
  log "Клонирую Homepage"
  rm -rf "$APP_DIR"
  git clone "$DEFAULT_REPO" "$APP_DIR"
  chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR"
}

prepare_pnpm_build_approvals() {
  log "Готовлю разрешения build scripts для pnpm"
  cd "$APP_DIR"

  if sudo -u "$APP_USER" pnpm approve-builds --all >/dev/null 2>&1; then
    return
  fi

  if [ ! -f "$APP_DIR/pnpm-workspace.yaml" ]; then
    cat > "$APP_DIR/pnpm-workspace.yaml" <<'EOF'
onlyBuiltDependencies:
  - core-js
  - cpu-features
  - esbuild
  - protobufjs
  - ssh2
EOF
    chown "$APP_USER:$APP_GROUP" "$APP_DIR/pnpm-workspace.yaml"
    return
  fi

  if ! grep -q '^onlyBuiltDependencies:' "$APP_DIR/pnpm-workspace.yaml"; then
    cat >> "$APP_DIR/pnpm-workspace.yaml" <<'EOF'

onlyBuiltDependencies:
  - core-js
  - cpu-features
  - esbuild
  - protobufjs
  - ssh2
EOF
    chown "$APP_USER:$APP_GROUP" "$APP_DIR/pnpm-workspace.yaml"
  fi
}

install_dependencies() {
  log "Устанавливаю зависимости проекта"
  cd "$APP_DIR"
  sudo -u "$APP_USER" pnpm install
}

create_initial_config() {
  log "Создаю стартовый config"
  cd "$APP_DIR"
  if [ ! -d "$APP_DIR/config" ]; then
    sudo -u "$APP_USER" cp -r "$APP_DIR/src/skeleton" "$APP_DIR/config"
  fi
}

build_project() {
  log "Собираю production bundle"
  cd "$APP_DIR"

  local revision="manual"
  revision="$(sudo -u "$APP_USER" git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo manual)"

  sudo -u "$APP_USER" env \
    NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_BUILDTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    NEXT_PUBLIC_VERSION="manual" \
    NEXT_PUBLIC_REVISION="$revision" \
    pnpm build
}

write_env_file() {
  log "Сохраняю переменные окружения"
  cat > "$ENV_FILE" <<EOF
HOMEPAGE_ALLOWED_HOSTS=${HOMEPAGE_ALLOWED_HOSTS}
EOF
  chmod 600 "$ENV_FILE"
}

write_systemd_service() {
  local pnpm_path
  pnpm_path="$(command -v pnpm)"
  [ -n "$pnpm_path" ] || fail "Не найден pnpm"

  log "Создаю systemd unit"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Homepage Dashboard
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
Environment=HOSTNAME=${APP_HOST}
EnvironmentFile=${ENV_FILE}
ExecStart=${pnpm_path} start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

write_nginx_config() {
  local primary_host
  primary_host="$(get_primary_host "$HOMEPAGE_ALLOWED_HOSTS")"
  [ -n "$primary_host" ] || fail "Не удалось определить основной host"

  log "Настраиваю nginx для ${primary_host}"
  rm -f /etc/nginx/sites-enabled/default

  cat > "/etc/nginx/sites-available/${NGINX_SITE_NAME}" <<EOF
server {
    listen 80;
    server_name ${primary_host};

    client_max_body_size 20m;

    location / {
        proxy_pass http://${APP_HOST}:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/${NGINX_SITE_NAME}" "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  nginx -t
  systemctl enable nginx
}

start_services() {
  log "Запускаю сервисы"
  systemctl restart "$SERVICE_NAME"
  systemctl restart nginx
}

install_homepage() {
  ask_hosts_install
  ensure_packages
  ensure_pnpm
  ensure_user
  clone_repo
  prepare_pnpm_build_approvals
  install_dependencies
  create_initial_config
  build_project
  write_env_file
  write_systemd_service
  write_nginx_config
  start_services

  local primary_host
  primary_host="$(get_primary_host "$HOMEPAGE_ALLOWED_HOSTS")"

  echo
  echo "Готово."
  echo "Сайт:    http://${primary_host}"
  echo "Сервис:  systemctl status ${SERVICE_NAME}"
  echo "Логи:    journalctl -u ${SERVICE_NAME} -f"
  echo "Команда: update"
}

update_homepage() {
  [ -d "${APP_DIR}/.git" ] || fail "Homepage не найден в ${APP_DIR}"
  ask_hosts_update
  ensure_packages
  ensure_pnpm
  ensure_user

  log "Обновляю репозиторий"
  cd "$APP_DIR"
  sudo -u "$APP_USER" git pull

  prepare_pnpm_build_approvals
  install_dependencies
  build_project
  write_env_file
  write_systemd_service
  write_nginx_config
  start_services

  local primary_host
  primary_host="$(get_primary_host "$HOMEPAGE_ALLOWED_HOSTS")"

  echo
  echo "Обновление завершено."
  echo "Сайт: http://${primary_host}"
  echo "Команда: update"
}

remove_homepage() {
  echo
  read -r -p "Точно удалить Homepage, nginx-конфиг и пользователя ${APP_USER}? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Отменено."
      return
      ;;
  esac

  log "Останавливаю и удаляю systemd сервис"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload

  log "Удаляю nginx-конфиг"
  rm -f "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  rm -f "/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  nginx -t 2>/dev/null || true
  systemctl restart nginx 2>/dev/null || true

  log "Удаляю переменные окружения"
  rm -f "$ENV_FILE"

  log "Удаляю каталог приложения"
  rm -rf "$APP_DIR"

  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "Удаляю пользователя ${APP_USER}"
    userdel -r "$APP_USER" 2>/dev/null || userdel "$APP_USER" 2>/dev/null || true
  fi

  if [ -f "$SELF_INSTALL_PATH" ]; then
    log "Удаляю команду ${SELF_INSTALL_PATH}"
    rm -f "$SELF_INSTALL_PATH"
  fi

  echo
  echo "Homepage удалён."
}

show_menu() {
  echo
  echo "Выберите действие:"
  echo "1) Установить"
  echo "2) Обновить"
  echo "3) Удалить"
  echo "4) Выход"
  read -r -p "Введите номер [1-4]: " action

  case "$action" in
    1) install_homepage ;;
    2) update_homepage ;;
    3) remove_homepage ;;
    4)
      echo "Выход."
      exit 0
      ;;
    *)
      fail "Неверный выбор"
      ;;
  esac
}

main() {
  require_root
  install_self_to_bin
  show_menu
}

main "$@"
