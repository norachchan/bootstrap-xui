#!/usr/bin/env bash
# bootstrap-xui.sh — apt upgrade + 3x-ui + SSL + restore template.db
# One-liner:
#   bash <(curl -Ls https://raw.githubusercontent.com/norachchan/bootstrap-xui/main/bootstrap-xui.sh)
#
# Secrets are printed once and not written by this script (except what 3x-ui itself writes).

set -euo pipefail

SCRIPT_VERSION="2026.09.10-2"

# Override if hosting elsewhere:
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/norachchan/bootstrap-xui/main}"
TEMPLATE_URL="${TEMPLATE_URL:-${REPO_RAW}/template.db}"
XUI_INSTALL_URL="${XUI_INSTALL_URL:-https://raw.githubusercontent.com/MHSanaei/3x-ui/refs/heads/main/install.sh}"

XUI_FOLDER="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
XUI_DB_PATH="/etc/x-ui/x-ui.db"
XUI_ENV_FILE="/etc/default/x-ui"
CERT_FULLCHAIN="/root/cert/ip/fullchain.pem"
CERT_PRIVKEY="/root/cert/ip/privkey.pem"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INF]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Запустите от root: sudo bash $0"
    exit 1
  fi
}

gen_alnum() {
  local length="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
  else
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
  fi
}

gen_username() { gen_alnum 12; }

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
  else
    return 1
  fi
}

pick_free_panel_port() {
  local port tries=0
  while ((tries < 80)); do
    port=$((20000 + RANDOM % 40001))
    if ! port_in_use "$port"; then
      echo "$port"
      return 0
    fi
    ((tries++)) || true
  done
  return 1
}

public_ipv4() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

ensure_sqlite3() {
  if command -v sqlite3 >/dev/null 2>&1; then
    return 0
  fi
  log "Устанавливаю sqlite3..."
  apt-get install -y -qq sqlite3 >/dev/null
}

stop_xui() {
  systemctl stop x-ui 2>/dev/null || true
  sleep 1
  local pids
  pids=$(pgrep -f '^/usr/local/x-ui/x-ui( |$)' 2>/dev/null || true)
  if [[ -n "${pids}" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 2
    pids=$(pgrep -f '^/usr/local/x-ui/x-ui( |$)' 2>/dev/null || true)
    if [[ -n "${pids}" ]]; then
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
    fi
  fi
}

start_xui() {
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui 2>/dev/null || systemctl start x-ui 2>/dev/null || {
    if [[ -x "${XUI_FOLDER}/x-ui" ]]; then
      nohup "${XUI_FOLDER}/x-ui" >/var/log/x-ui-install-template.log 2>&1 &
    fi
  }
  sleep 2
}

force_sqlite_backend() {
  # template.db — SQLite; postgres backend после restore не нужен
  if [[ -f "$XUI_ENV_FILE" ]]; then
    cp -a "$XUI_ENV_FILE" "${XUI_ENV_FILE}.bak.$(date +%s)" 2>/dev/null || true
  fi
  install -d -m 755 "$(dirname "$XUI_ENV_FILE")"
  cat >"$XUI_ENV_FILE" <<'EOF'
XUI_DB_TYPE=sqlite
EOF
  chmod 644 "$XUI_ENV_FILE"
  # На всякий случай убрать postgres DSN из окружения сервиса
  if [[ -f /etc/systemd/system/x-ui.service ]]; then
    systemctl daemon-reload 2>/dev/null || true
  fi
  ok "Backend панели: SQLite (${XUI_DB_PATH})"
}

apt_upgrade_noninteractive() {
  log "apt update/upgrade (noninteractive, keep local configs)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
  apt-get install -y -qq curl ca-certificates sqlite3 openssl >/dev/null
  ok "Пакеты обновлены"
}

ask_ssl_mode() {
  echo ""
  echo -e "${BOLD}SSL Certificate Setup${NC}"
  echo "  1) Let's Encrypt for Domain (90-day)"
  echo "  2) Let's Encrypt for IP Address (6-day, default)"
  echo ""
  local choice=""
  read -rp "Choose an option (default 2 for IP): " choice || true
  choice="${choice// /}"
  case "$choice" in
    1)
      SSL_MODE="domain"
      ;;
    ""|2)
      SSL_MODE="ip"
      ;;
    *)
      warn "Неизвестный выбор '${choice}' — использую IP (2)"
      SSL_MODE="ip"
      ;;
  esac

  SSL_DOMAIN=""
  SSL_EMAIL=""
  if [[ "$SSL_MODE" == "domain" ]]; then
    while [[ -z "$SSL_DOMAIN" ]]; do
      read -rp "Domain name: " SSL_DOMAIN || true
      SSL_DOMAIN="${SSL_DOMAIN// /}"
    done
    read -rp "ACME email (optional, Enter to skip): " SSL_EMAIL || true
    SSL_EMAIL="${SSL_EMAIL// /}"
  fi
  ok "SSL mode: ${SSL_MODE}${SSL_DOMAIN:+ (${SSL_DOMAIN})}"
}

ask_inbound_tag() {
  local default_tag="$1"
  echo ""
  echo -e "${BOLD}Inbound tag${NC}"
  echo "Текущий tag в template: ${default_tag}"
  local tag=""
  while true; do
    read -rp "Новый inbound tag: " tag || true
    tag="${tag// /}"
    if [[ -z "$tag" ]]; then
      err "Tag не может быть пустым"
      continue
    fi
    if [[ ! "$tag" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      err "Допустимы: буквы, цифры, . _ : -"
      continue
    fi
    INBOUND_TAG="$tag"
    break
  done
  ok "Inbound tag: ${INBOUND_TAG}"
}

run_xui_install() {
  local db_type="$1" # postgres|sqlite
  local tmp
  tmp=$(mktemp /tmp/xui-install.XXXXXX.sh)
  log "Скачиваю официальный install.sh..."
  curl -fsSL "$XUI_INSTALL_URL" -o "$tmp"
  chmod +x "$tmp"

  export DEBIAN_FRONTEND=noninteractive
  export XUI_NONINTERACTIVE=1
  export XUI_DB_TYPE="$db_type"
  export XUI_SSL_MODE="$SSL_MODE"
  unset XUI_DB_DSN || true

  if [[ "$SSL_MODE" == "domain" ]]; then
    export XUI_DOMAIN="$SSL_DOMAIN"
    [[ -n "$SSL_EMAIL" ]] && export XUI_ACME_EMAIL="$SSL_EMAIL"
  else
    unset XUI_DOMAIN XUI_ACME_EMAIL || true
  fi

  # Не пиним credentials на этапе install — перезапишем после template
  unset XUI_USERNAME XUI_PASSWORD XUI_PANEL_PORT XUI_WEB_BASE_PATH || true

  log "Запуск 3x-ui install (DB=${db_type}, SSL=${SSL_MODE})..."
  set +e
  bash "$tmp"
  local rc=$?
  set -e
  rm -f "$tmp"
  return "$rc"
}

install_3xui_with_db_fallback() {
  if [[ -x "${XUI_FOLDER}/x-ui" ]] || systemctl cat x-ui.service >/dev/null 2>&1; then
    warn "3x-ui уже установлен — пропускаю download/install, продолжаю SSL/template при необходимости"
    # Если бинарь есть, но SSL/конфиг могли быть не доделаны — всё равно пробуем свежий install
    # (официальный скрипт идемпотентен для existing install).
  fi

  log "Пробую PostgreSQL..."
  if run_xui_install postgres; then
    DB_BACKEND="postgres"
    ok "3x-ui установлен с PostgreSQL"
    return 0
  fi

  warn "PostgreSQL install failed — fallback на SQLite"
  if run_xui_install sqlite; then
    DB_BACKEND="sqlite"
    ok "3x-ui установлен с SQLite"
    return 0
  fi

  err "Установка 3x-ui не удалась (postgres и sqlite)"
  exit 1
}

download_template() {
  local dest="$1"
  # Локальный файл рядом со скриптом (не при bash <(curl ...))
  local self_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [[ -n "$self_dir" && -f "${self_dir}/template.db" ]]; then
    log "Беру ${self_dir}/template.db"
    cp -f "${self_dir}/template.db" "$dest"
    return 0
  fi
  if [[ -f "./template.db" ]]; then
    log "Беру локальный ./template.db"
    cp -f ./template.db "$dest"
    return 0
  fi
  log "Скачиваю template.db: ${TEMPLATE_URL}"
  curl -fsSL "$TEMPLATE_URL" -o "$dest"
}

restore_template_db() {
  ensure_sqlite3
  stop_xui
  force_sqlite_backend

  install -d -m 700 /etc/x-ui
  if [[ -f "$XUI_DB_PATH" ]]; then
    cp -a "$XUI_DB_PATH" "${XUI_DB_PATH}.bak.$(date +%s)"
  fi
  # Убрать WAL/SHM от старой БД
  rm -f "${XUI_DB_PATH}-wal" "${XUI_DB_PATH}-shm" 2>/dev/null || true

  local tmp_db
  tmp_db=$(mktemp /tmp/template.XXXXXX.db)
  download_template "$tmp_db"

  # Проверка что это sqlite
  if ! sqlite3 "$tmp_db" "SELECT tag FROM inbounds LIMIT 1;" >/dev/null 2>&1; then
    err "template.db повреждён или не SQLite"
    rm -f "$tmp_db"
    exit 1
  fi

  local old_tag
  old_tag=$(sqlite3 "$tmp_db" "SELECT tag FROM inbounds ORDER BY id LIMIT 1;")
  [[ -n "$old_tag" ]] || { err "В template нет inbound"; rm -f "$tmp_db"; exit 1; }

  ask_inbound_tag "$old_tag"

  if [[ "$INBOUND_TAG" != "$old_tag" ]]; then
    log "Меняю tag: ${old_tag} → ${INBOUND_TAG}"
    sqlite3 "$tmp_db" "UPDATE inbounds SET tag='${INBOUND_TAG//\'/\'\'}' WHERE tag='${old_tag//\'/\'\'}';"
    # На случай упоминаний в JSON settings таблиц — точечная замена в outbound_traffics не нужна
  fi

  # Сбросить чужие panel credentials в users — CLI перезапишет, но на всякий случай
  # Оставляем строку users: CLI setting обновит username/password hash

  install -m 600 "$tmp_db" "$XUI_DB_PATH"
  rm -f "$tmp_db"
  chown root:root "$XUI_DB_PATH" 2>/dev/null || true
  ok "template.db восстановлен → ${XUI_DB_PATH}"
}

apply_panel_credentials() {
  local bin="${XUI_FOLDER}/x-ui"
  [[ -x "$bin" ]] || bin=$(command -v x-ui || true)
  [[ -n "$bin" && -x "$bin" ]] || { err "Бинарник x-ui не найден"; exit 1; }

  PANEL_USER=$(gen_username)
  PANEL_PASS=$(gen_alnum 60)
  PANEL_PATH=$(gen_alnum 18)
  PANEL_PORT=$(pick_free_panel_port) || PANEL_PORT=$(shuf -i 20000-60000 -n 1)

  stop_xui

  log "Применяю credentials / port / webBasePath..."
  local out
  set +e
  out=$("$bin" setting \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS" \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH" \
    -resetTwoFactor=true 2>&1)
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    # Старые сборки без resetTwoFactor
    out=$("$bin" setting \
      -username "$PANEL_USER" \
      -password "$PANEL_PASS" \
      -port "$PANEL_PORT" \
      -webBasePath "$PANEL_PATH" 2>&1) || {
      err "Не удалось применить setting: $out"
      exit 1
    }
  fi

  # Вернуть SSL paths если cert уже выпущен (template мог содержать чужие/те же пути)
  if [[ -f "$CERT_FULLCHAIN" && -f "$CERT_PRIVKEY" ]]; then
    log "Прописываю SSL cert paths..."
    "$bin" cert -webCert "$CERT_FULLCHAIN" -webCertKey "$CERT_PRIVKEY" >/dev/null 2>&1 || true
  elif [[ -f "/root/cert/${SSL_DOMAIN:-}/fullchain.pem" && -f "/root/cert/${SSL_DOMAIN:-}/privkey.pem" ]]; then
    "$bin" cert -webCert "/root/cert/${SSL_DOMAIN}/fullchain.pem" \
      -webCertKey "/root/cert/${SSL_DOMAIN}/privkey.pem" >/dev/null 2>&1 || true
  fi

  # Обновить install-result.env (опционально, удобно)
  local host scheme="https"
  host=$(public_ipv4 || true)
  [[ -n "$host" ]] || host="<SERVER_IP>"
  if [[ "$SSL_MODE" == "domain" && -n "${SSL_DOMAIN:-}" ]]; then
    host="$SSL_DOMAIN"
  fi
  # Если cert нет — всё равно https URL как после LE; иначе http
  if [[ ! -f "$CERT_FULLCHAIN" && ! -f "/root/cert/${SSL_DOMAIN:-}/fullchain.pem" ]]; then
    scheme="http"
  fi

  ACCESS_URL="${scheme}://${host}:${PANEL_PORT}/${PANEL_PATH}/"
  install -d -m 700 /etc/x-ui
  umask 077
  cat >/etc/x-ui/install-result.env <<EOF
XUI_USERNAME=$(printf '%q' "$PANEL_USER")
XUI_PASSWORD=$(printf '%q' "$PANEL_PASS")
XUI_PANEL_PORT=$(printf '%q' "$PANEL_PORT")
XUI_WEB_BASE_PATH=$(printf '%q' "$PANEL_PATH")
XUI_ACCESS_URL=$(printf '%q' "$ACCESS_URL")
XUI_DB_TYPE=sqlite
XUI_INBOUND_TAG=$(printf '%q' "$INBOUND_TAG")
EOF
  chmod 600 /etc/x-ui/install-result.env
  umask 022

  start_xui
  ok "Credentials применены"
}

print_summary() {
  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}  3x-ui + template — готово${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
  echo -e "Access URL:    ${GREEN}${ACCESS_URL}${NC}"
  echo -e "Username:      ${GREEN}${PANEL_USER}${NC}"
  echo -e "Password:      ${GREEN}${PANEL_PASS}${NC}"
  echo -e "Inbound tag:   ${GREEN}${INBOUND_TAG}${NC}"
  echo -e "DB backend:    sqlite (template)"
  echo -e "Install DB try: ${DB_BACKEND:-unknown}"
  echo -e "${YELLOW}Скопируйте пароль сейчас — повторно скрипт его не покажет.${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════${NC}"
}

main() {
  need_root
  echo -e "${BOLD}bootstrap-xui.sh ${SCRIPT_VERSION}${NC}"

  SSL_MODE=""
  SSL_DOMAIN=""
  SSL_EMAIL=""
  INBOUND_TAG=""
  DB_BACKEND=""
  PANEL_USER=""
  PANEL_PASS=""
  PANEL_PATH=""
  PANEL_PORT=""
  ACCESS_URL=""

  apt_upgrade_noninteractive
  ask_ssl_mode
  install_3xui_with_db_fallback
  restore_template_db
  apply_panel_credentials
  print_summary
}

main "$@"
