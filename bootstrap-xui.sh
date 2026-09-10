#!/usr/bin/env bash
# bootstrap-xui.sh — quick 3x-ui install + template inbounds
#   bash <(curl -Ls https://raw.githubusercontent.com/norachchan/bootstrap-xui/main/bootstrap-xui.sh)

set -euo pipefail

SCRIPT_VERSION="2026.09.10-6"
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
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "  ${CYAN}›${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

banner() {
  echo ""
  echo -e "${BLUE}┌──────────────────────────────────────────────────────┐${NC}"
  printf "${BLUE}│${NC}  ${BOLD}%-50s${NC}${BLUE}│${NC}\n" "$1"
  echo -e "${BLUE}└──────────────────────────────────────────────────────┘${NC}"
}

step() {
  echo ""
  echo -e "${BOLD}$1${NC}  ${DIM}$2${NC}"
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "нужен root: sudo bash $0"
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

port_in_use() {
  local port="$1"
  # Не парсить колонки ss — на Ubuntu 24 есть Netid, Local Address уже не $4
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0
  fi
  return 1
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
  local ip url
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}

ensure_sqlite3() {
  command -v sqlite3 >/dev/null 2>&1 && return 0
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
}

xui_bin() {
  if [[ -x "${XUI_FOLDER}/x-ui" ]]; then
    echo "${XUI_FOLDER}/x-ui"
  elif command -v x-ui >/dev/null 2>&1; then
    command -v x-ui
  else
    return 1
  fi
}

# CLI setting/cert читает XUI_DB_* из shell — после postgres-install обязательно sqlite
force_sqlite_backend() {
  [[ -f "$XUI_ENV_FILE" ]] && cp -a "$XUI_ENV_FILE" "${XUI_ENV_FILE}.bak.$(date +%s)" 2>/dev/null || true
  install -d -m 755 "$(dirname "$XUI_ENV_FILE")"
  printf 'XUI_DB_TYPE=sqlite\n' >"$XUI_ENV_FILE"
  chmod 644 "$XUI_ENV_FILE"
  export XUI_DB_TYPE=sqlite
  unset XUI_DB_DSN PG_USER PG_PASS PG_HOST PG_PORT PG_DB 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

xui_cli() {
  local bin
  bin=$(xui_bin) || return 1
  XUI_DB_TYPE=sqlite env -u XUI_DB_DSN "$bin" "$@"
}

stop_xui() {
  systemctl stop x-ui 2>/dev/null || true
  sleep 1
  local pids
  pids=$(pgrep -f '^/usr/local/x-ui/x-ui( |$)' 2>/dev/null || true)
  if [[ -n "${pids}" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 1
    pids=$(pgrep -f '^/usr/local/x-ui/x-ui( |$)' 2>/dev/null || true)
    # shellcheck disable=SC2086
    [[ -n "${pids}" ]] && kill -KILL $pids 2>/dev/null || true
  fi
}

start_xui() {
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui 2>/dev/null || systemctl start x-ui 2>/dev/null || true
  sleep 2
}

open_firewall_port() {
  local port="$1"
  [[ -n "$port" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
  fi
}

verify_panel_up() {
  local port="$1" i
  for i in $(seq 1 15); do
    if port_in_use "$port"; then
      return 0
    fi
    # HTTPS/HTTP на localhost — надёжнее, чем только ss
    if curl -kfsS --connect-timeout 1 --max-time 2 "https://127.0.0.1:${port}/" -o /dev/null 2>/dev/null \
      || curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:${port}/" -o /dev/null 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  err "панель не слушает порт ${port}"
  systemctl status x-ui --no-pager -l 2>&1 | tail -15 || true
  journalctl -u x-ui -n 20 --no-pager 2>&1 || true
  return 1
}

# ── steps ──────────────────────────────────────────────────────────────────

apt_upgrade_noninteractive() {
  step "1/5" "обновление пакетов"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade >/dev/null
  apt-get install -y -qq curl ca-certificates sqlite3 openssl >/dev/null
  ok "готово"
}

ask_ssl_mode() {
  step "2/5" "SSL"
  echo ""
  echo -e "  ${BOLD}1${NC}  Domain  ${DIM}(Let's Encrypt, 90 дней)${NC}"
  echo -e "  ${BOLD}2${NC}  IP      ${DIM}(Let's Encrypt, ~6 дней, по умолчанию)${NC}"
  echo ""
  local choice=""
  read -rp "  Выбор [2]: " choice || true
  choice="${choice// /}"
  case "$choice" in
    1) SSL_MODE="domain" ;;
    ""|2) SSL_MODE="ip" ;;
    *)
      warn "неизвестно — IP"
      SSL_MODE="ip"
      ;;
  esac

  SSL_DOMAIN=""
  SSL_EMAIL=""
  if [[ "$SSL_MODE" == "domain" ]]; then
    while [[ -z "$SSL_DOMAIN" ]]; do
      read -rp "  Domain: " SSL_DOMAIN || true
      SSL_DOMAIN="${SSL_DOMAIN// /}"
    done
    read -rp "  Email (Enter — пропуск): " SSL_EMAIL || true
    SSL_EMAIL="${SSL_EMAIL// /}"
  fi
  ok "SSL: ${SSL_MODE}${SSL_DOMAIN:+ → ${SSL_DOMAIN}}"
}

ask_inbound_tag() {
  local default_tag="$1" tag=""
  echo ""
  echo -e "  Template tag: ${DIM}${default_tag}${NC}"
  while true; do
    read -rp "  Новый inbound tag: " tag || true
    tag="${tag// /}"
    if [[ -z "$tag" ]]; then
      err "пустой tag"
      continue
    fi
    if [[ ! "$tag" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      err "только A-Za-z0-9 . _ : -"
      continue
    fi
    INBOUND_TAG="$tag"
    break
  done
}

run_xui_install() {
  local tmp
  tmp=$(mktemp /tmp/xui-install.XXXXXX.sh)
  curl -fsSL "$XUI_INSTALL_URL" -o "$tmp"
  chmod +x "$tmp"

  export DEBIAN_FRONTEND=noninteractive
  export XUI_NONINTERACTIVE=1
  # Всегда sqlite: template.db — sqlite, postgres без DSN ломает reinstall
  export XUI_DB_TYPE=sqlite
  export XUI_SSL_MODE="$SSL_MODE"
  unset XUI_DB_DSN XUI_USERNAME XUI_PASSWORD XUI_PANEL_PORT XUI_WEB_BASE_PATH || true

  if [[ "$SSL_MODE" == "domain" ]]; then
    export XUI_DOMAIN="$SSL_DOMAIN"
    [[ -n "$SSL_EMAIL" ]] && export XUI_ACME_EMAIL="$SSL_EMAIL"
  else
    unset XUI_DOMAIN XUI_ACME_EMAIL || true
  fi

  # Приглушить шум apt/curl progress, оставить суть SSL/ошибок
  local logf rc
  logf=$(mktemp /tmp/xui-install-log.XXXXXX)
  set +e
  bash "$tmp" >"$logf" 2>&1
  rc=$?
  set -e
  grep -Euv \
    '^(Hit:|Get:|Ign:|Reading package|Building dependency|Suggested packages|The following|Use '\''apt|0 upgraded|[[:space:]]*% Total|[[:space:]]*[0-9]+[[:space:]]+[0-9]|x-ui/|100[[:space:]]|No checksum|Got x-ui latest|Beginning|Arch:|The OS release|Running\.\.\.|ca-certificates is already|curl is already|tar is already|tzdata is already|socat is already|cron is already|openssl is already|libfwupd|libgusb|Created symlink|Synchronizing state|Executing:|Fail2ban is already|Ip Limit jail|IP Limit installed|Fail2ban setup complete|Setting up Fail2ban|Configuring IP Limit|Found x-ui\.service|Setting up systemd|x-ui control menu|│|└─|┌─)' \
    "$logf" || true
  rm -f "$tmp" "$logf"
  return "$rc"
}

install_3xui() {
  step "3/5" "установка 3x-ui"
  force_sqlite_backend
  if run_xui_install; then
    ok "установлено"
    return 0
  fi
  err "установка 3x-ui провалилась"
  exit 1
}

download_template() {
  local dest="$1" self_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [[ -n "$self_dir" && -f "${self_dir}/template.db" ]]; then
    cp -f "${self_dir}/template.db" "$dest"
  elif [[ -f "./template.db" ]]; then
    cp -f ./template.db "$dest"
  else
    curl -fsSL "$TEMPLATE_URL" -o "$dest"
  fi
}

restore_template_db() {
  step "4/5" "template + inbound"
  ensure_sqlite3
  stop_xui
  force_sqlite_backend

  install -d -m 700 /etc/x-ui
  [[ -f "$XUI_DB_PATH" ]] && cp -a "$XUI_DB_PATH" "${XUI_DB_PATH}.bak.$(date +%s)"
  rm -f "${XUI_DB_PATH}-wal" "${XUI_DB_PATH}-shm" 2>/dev/null || true

  local tmp_db old_tag
  tmp_db=$(mktemp /tmp/template.XXXXXX.db)
  download_template "$tmp_db"

  if ! sqlite3 "$tmp_db" "SELECT tag FROM inbounds LIMIT 1;" >/dev/null 2>&1; then
    err "template.db битый"
    rm -f "$tmp_db"
    exit 1
  fi

  old_tag=$(sqlite3 "$tmp_db" "SELECT tag FROM inbounds ORDER BY id LIMIT 1;")
  [[ -n "$old_tag" ]] || { err "в template нет inbound"; rm -f "$tmp_db"; exit 1; }

  ask_inbound_tag "$old_tag"

  if [[ "$INBOUND_TAG" != "$old_tag" ]]; then
    sqlite3 "$tmp_db" "UPDATE inbounds SET tag='${INBOUND_TAG//\'/\'\'}' WHERE tag='${old_tag//\'/\'\'}';"
  fi
  sqlite3 "$tmp_db" "DELETE FROM api_tokens;"

  install -m 600 "$tmp_db" "$XUI_DB_PATH"
  rm -f "$tmp_db"
  chown root:root "$XUI_DB_PATH" 2>/dev/null || true
  ok "tag: ${INBOUND_TAG}"
}

create_api_token() {
  API_TOKEN=""
  local out
  out=$(xui_cli setting -getApiToken -tokenName bootstrap 2>&1) || true
  API_TOKEN=$(printf '%s\n' "$out" | grep -Eo 'apiToken: .+' | head -1 | awk '{print $2}' | tr -d '[:space:]' || true)
  if [[ -z "$API_TOKEN" ]]; then
    out=$(xui_cli setting -getApiToken 2>&1) || true
    API_TOKEN=$(printf '%s\n' "$out" | grep -Eo 'apiToken: .+' | head -1 | awk '{print $2}' | tr -d '[:space:]' || true)
  fi
}

apply_panel_credentials() {
  step "5/5" "credentials + API token"
  xui_bin >/dev/null || { err "x-ui не найден"; exit 1; }

  force_sqlite_backend
  PANEL_USER=$(gen_alnum 12)
  PANEL_PASS=$(gen_alnum 60)
  PANEL_PATH=$(gen_alnum 18)
  PANEL_PORT=$(pick_free_panel_port) || PANEL_PORT=$(shuf -i 20000-60000 -n 1)

  stop_xui

  if ! xui_cli setting \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS" \
    -port "$PANEL_PORT" \
    -webBasePath "$PANEL_PATH" \
    -resetTwoFactor=true >/dev/null 2>&1
  then
    xui_cli setting \
      -username "$PANEL_USER" \
      -password "$PANEL_PASS" \
      -port "$PANEL_PORT" \
      -webBasePath "$PANEL_PATH" >/dev/null 2>&1 \
      || { err "не удалось применить setting"; exit 1; }
  fi

  sqlite3 "$XUI_DB_PATH" "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';"
  sqlite3 "$XUI_DB_PATH" "UPDATE settings SET value='/${PANEL_PATH}/' WHERE key='webBasePath';"
  local got_port
  got_port=$(sqlite3 "$XUI_DB_PATH" "SELECT value FROM settings WHERE key='webPort';")
  [[ "$got_port" == "$PANEL_PORT" ]] || { err "webPort=${got_port}, ждали ${PANEL_PORT}"; exit 1; }

  if [[ -f "$CERT_FULLCHAIN" && -f "$CERT_PRIVKEY" ]]; then
    xui_cli cert -webCert "$CERT_FULLCHAIN" -webCertKey "$CERT_PRIVKEY" >/dev/null 2>&1 || true
    sqlite3 "$XUI_DB_PATH" "UPDATE settings SET value='${CERT_FULLCHAIN}' WHERE key IN ('webCertFile','subCertFile');"
    sqlite3 "$XUI_DB_PATH" "UPDATE settings SET value='${CERT_PRIVKEY}' WHERE key IN ('webKeyFile','subKeyFile');"
  elif [[ -n "${SSL_DOMAIN:-}" && -f "/root/cert/${SSL_DOMAIN}/fullchain.pem" ]]; then
    xui_cli cert -webCert "/root/cert/${SSL_DOMAIN}/fullchain.pem" \
      -webCertKey "/root/cert/${SSL_DOMAIN}/privkey.pem" >/dev/null 2>&1 || true
  fi

  create_api_token
  [[ -n "$API_TOKEN" ]] && ok "API token создан" || warn "API token не создан"

  local host scheme="https"
  host=$(public_ipv4 || true)
  [[ -n "$host" ]] || host="<SERVER_IP>"
  if [[ "${SSL_MODE:-}" == "domain" && -n "${SSL_DOMAIN:-}" ]]; then
    host="$SSL_DOMAIN"
  fi
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
XUI_API_TOKEN=$(printf '%q' "${API_TOKEN:-}")
XUI_DB_TYPE=sqlite
XUI_INBOUND_TAG=$(printf '%q' "$INBOUND_TAG")
EOF
  chmod 600 /etc/x-ui/install-result.env
  umask 022

  open_firewall_port "$PANEL_PORT"
  start_xui
  verify_panel_up "$PANEL_PORT" || exit 1
  ok "панель на порту ${PANEL_PORT}"
}

print_summary() {
  local line
  line() { printf "  ${DIM}%-12s${NC} %s\n" "$1" "$2"; }

  echo ""
  echo -e "${GREEN}┌──────────────────────────────────────────────────────┐${NC}"
  echo -e "${GREEN}│${NC}  ${BOLD}Готово — скопируйте сейчас${NC}                          ${GREEN}│${NC}"
  echo -e "${GREEN}└──────────────────────────────────────────────────────┘${NC}"
  echo ""
  line "URL"      "${GREEN}${ACCESS_URL}${NC}"
  line "Username" "${GREEN}${PANEL_USER}${NC}"
  line "Password" "${GREEN}${PANEL_PASS}${NC}"
  if [[ -n "${API_TOKEN:-}" ]]; then
    line "API Token" "${GREEN}${API_TOKEN}${NC}"
  fi
  line "Inbound"  "${GREEN}${INBOUND_TAG}${NC}"
  echo ""
  echo -e "  ${DIM}Bearer: Authorization: Bearer <API Token>${NC}"
  echo -e "  ${YELLOW}Пароль и token больше не покажутся.${NC}"
  echo ""
}

main() {
  need_root
  clear 2>/dev/null || true
  banner "bootstrap-xui  ${SCRIPT_VERSION}"
  echo -e "  ${DIM}3x-ui + SSL + template inbounds${NC}"

  SSL_MODE="" SSL_DOMAIN="" SSL_EMAIL=""
  INBOUND_TAG=""
  PANEL_USER="" PANEL_PASS="" PANEL_PATH="" PANEL_PORT=""
  ACCESS_URL="" API_TOKEN=""

  apt_upgrade_noninteractive
  ask_ssl_mode
  install_3xui
  restore_template_db
  apply_panel_credentials
  print_summary
}

main "$@"
