#!/usr/bin/env bash
set -Eeuo pipefail

# n8n VPS installer v5.5 (Ubuntu 24.x/26.x, Debian 12/13)
IFS=$'\n\t'
umask 022
APP_DIR="/opt/n8n"
ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/compose.yaml"
CADDY_FILE="$APP_DIR/Caddyfile"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-n8n-vps-port.conf"
LOG_FILE="/var/log/n8n-installer.log"
HARDEN_DROPIN="/etc/ssh/sshd_config.d/00-n8n-hardening.conf"
CRED_FILE="/root/n8n-credentials.txt"
ADMIN_USER=""; ADMIN_PUBKEY=""; ADMIN_PASS=""; ADMIN_PASS_INPUT=""; ADMIN_AUTH=""; HARDENED=0

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
ok(){ log "OK: $*"; }
warn(){ log "WARN: $*" >&2; }
die(){ log "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; log "ERROR: строка ${BASH_LINENO[0]:-?}, код $rc" >&2; exit $rc' ERR

is_interactive(){ [[ -t 0 && -t 1 ]]; }

ask_yes_no(){
  local prompt="$1" default="${2:-n}" ans
  is_interactive || return 1
  while true; do
    if [[ "$default" == y ]]; then
      read -r -p "$prompt [Y/n]: " ans || return 1; ans="${ans:-y}"
    else
      read -r -p "$prompt [y/N]: " ans || return 1; ans="${ans:-n}"
    fi
    case "${ans,,}" in y|yes|д|да) return 0;; n|no|н|нет) return 1;; *) echo "Введите y/yes или n/no.";; esac
  done
}

validate_ascii_domain(){
  local d="${1,,}" label last
  [[ -n "$d" && ${#d} -le 253 && "$d" == *.* && "$d" != *..* ]] || return 1
  [[ "$d" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ ! "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra labels <<<"$d"
  ((${#labels[@]} >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  last="${labels[${#labels[@]}-1]}"
  [[ "$last" =~ ^[a-z]{2,63}$ || "$last" =~ ^xn--[a-z0-9-]{2,59}$ ]] || return 1
}

to_ascii_domain(){
  local input out
  input="$(trim "$1")"
  if [[ "$input" == *.. ]]; then return 1; fi
  input="${input%.}"
  [[ "$input" != *'\'* && "$input" != *'/'* && "$input" != *:* && "$input" != *[[:space:]]* ]] || return 1
  if LC_ALL=C grep -q '[^ -~]' <<<"$input"; then
    command -v idn2 >/dev/null || return 2
    out="$(idn2 --allow-unassigned --quiet "$input" 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1
  else
    out="${input,,}"
  fi
  validate_ascii_domain "$out" || return 1
  printf '%s\n' "$out"
}

validate_email(){ [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
validate_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1024 && 10#$1<=65535)) && [[ "$1" != 5432 && "$1" != 5678 ]]; }
trim(){ local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
random_hex(){ openssl rand -hex "$1"; }
port_in_use(){ ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$1$"; }

wait_for_port(){
  local port="$1" timeout="${2:-30}" i
  for i in $(seq 1 "$timeout"); do
    port_in_use "$port" && return 0
    sleep 1
  done
  return 1
}

public_ipv4(){ curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true; }
current_ssh_ports(){ sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -nu; }
aptx(){ apt-get -o DPkg::Lock::Timeout=300 "$@"; }

preflight(){
  [[ $EUID -eq 0 ]] || die "Запустите: sudo bash $0"
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:24.*|ubuntu:26.*|debian:12|debian:13) ;;
    *) die "Поддерживаются Ubuntu 24.xx/26.xx и Debian 12/13. Обнаружено: ${PRETTY_NAME:-unknown}." ;;
  esac
  mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /run/sshd; chmod 755 /run/sshd
}

install_base(){
  aptx update
  aptx install -y ca-certificates curl gnupg openssl ufw dnsutils idn2 sudo cron fail2ban openssh-client
}

install_docker(){
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then ok "Docker + Compose уже установлены"; return; fi
  install -m0755 -d /etc/apt/keyrings
  local docker_dist docker_suite
  . /etc/os-release
  docker_dist="$ID"
  if [[ "$docker_dist" == ubuntu ]]; then
    docker_suite="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  else
    docker_suite="$VERSION_CODENAME"
  fi
  if curl -fsSL --retry 3 --connect-timeout 10 "https://download.docker.com/linux/$docker_dist/gpg" -o /etc/apt/keyrings/docker.asc; then
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$docker_dist" "$docker_suite" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.sources
    aptx update
    aptx install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    warn "download.docker.com недоступен; использую системный docker.io + docker-compose-v2."
    rm -f /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/docker.sources
    aptx update
    aptx install -y docker.io docker-compose-v2
  fi
  systemctl enable --now docker
  docker compose version >/dev/null || die "Docker Compose недоступен."
}

collect_admin(){
  ADMIN_USER=""; ADMIN_PUBKEY=""; ADMIN_AUTH=""; ADMIN_PASS_INPUT=""
  if sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'; then
    warn "Вход под root в SSH уже отключён (вероятно, запускался secure-vps.sh)."
    warn "Создание нового пользователя пропущено: он не сможет войти из-за AllowUsers. Используйте существующего администратора."
    return 0
  fi
  ask_yes_no "Создать отдельного sudo-пользователя вместо работы под root (рекомендуется)?" y || return 0
  local u k p1 p2
  while true; do
    read -r -p "Имя пользователя [deploy]: " u; u="$(trim "$u")"; u="${u:-deploy}"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$u" != root ]] && break
    echo "Некорректное имя (a-z, 0-9, _ и -; не root)."
  done
  ADMIN_USER="$u"
  ADMIN_AUTH=password
  local m
  echo "Способ входа по SSH для $u:"
  echo "  1) пароль"
  echo "  2) SSH-ключ (рекомендуется, безопаснее)"
  while true; do
    read -r -p "Выбор [2]: " m; m="$(trim "$m")"; m="${m:-2}"
    [[ "$m" == 1 || "$m" == 2 ]] && break
    echo "Введите 1 или 2."
  done
  if [[ "$m" == 2 ]]; then
    ADMIN_AUTH=key
    if [[ -s /root/.ssh/authorized_keys ]] && ask_yes_no "Использовать SSH-ключи из /root/.ssh/authorized_keys для $u?" y; then
      ADMIN_PUBKEY="$(cat /root/.ssh/authorized_keys)"
    else
      while true; do
        read -r -p "Вставьте публичный SSH-ключ (ssh-ed25519 ...), пусто = вход по паролю: " k; k="$(trim "$k")"
        if [[ -z "$k" ]]; then warn "Ключ не указан — использую вход по паролю."; ADMIN_AUTH=password; break; fi
        if ssh-keygen -l -f /dev/stdin <<<"$k" >/dev/null 2>&1; then ADMIN_PUBKEY="$k"; break; fi
        echo "Ключ не распознан."
      done
    fi
  fi
  if [[ "$ADMIN_AUTH" == password ]]; then
    echo "Пароль для $u:"
    echo "  1) сгенерировать автоматически (по умолчанию; будет записан в файл доступов)"
    echo "  2) ввести свой"
    while true; do
      read -r -p "Выбор [1]: " m; m="$(trim "$m")"; m="${m:-1}"
      [[ "$m" == 1 || "$m" == 2 ]] && break
      echo "Введите 1 или 2."
    done
    if [[ "$m" == 2 ]]; then
      while true; do
        read -r -s -p "Введите пароль (минимум 12 символов): " p1; echo
        (( ${#p1} >= 12 )) || { echo "Слишком короткий пароль."; continue; }
        read -r -s -p "Повторите пароль: " p2; echo
        if [[ "$p1" == "$p2" ]]; then ADMIN_PASS_INPUT="$p1"; break; fi
        echo "Пароли не совпадают."
      done
    fi
  fi
}

setup_admin(){
  [[ -n "$ADMIN_USER" ]] || return 0
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    warn "Пользователь $ADMIN_USER уже существует; пароль не меняется."
    ADMIN_PASS=""
  else
    adduser --disabled-password --gecos "" "$ADMIN_USER" >/dev/null
    ADMIN_PASS="${ADMIN_PASS_INPUT:-$(random_hex 12)}"
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd
    if [[ -z "$ADMIN_PASS_INPUT" ]]; then
      printf '\n==================== СОХРАНИТЕ ПАРОЛЬ ====================\nПользователь: %s\nПароль:       %s\n(в конце установки он также будет записан в %s)\n==========================================================\n' "$ADMIN_USER" "$ADMIN_PASS" "$CRED_FILE"
      read -r -p "Нажмите Enter, когда сохранили пароль... " _ || true
    fi
  fi
  usermod -aG sudo "$ADMIN_USER"
  if [[ "$ADMIN_AUTH" == key ]]; then
    local home line
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != \#* ]] || continue
      grep -qxF "$line" "$home/.ssh/authorized_keys" || printf '%s\n' "$line" >>"$home/.ssh/authorized_keys"
    done <<<"$ADMIN_PUBKEY"
    chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
  fi
  ok "Пользователь $ADMIN_USER готов (sudo, вход: $ADMIN_AUTH)."
}

collect_inputs(){
  is_interactive || die "Обычный запуск требует интерактивного терминала. Для тестов: --self-test."
  local raw converted
  while true; do
    read -r -p "Домен n8n (поддерживается .рф): " raw; raw="$(trim "$raw")"
    if converted="$(to_ascii_domain "$raw")"; then DOMAIN="$converted"; DISPLAY_DOMAIN="${raw,,}"; break; fi
    echo "Некорректный домен."
  done
  while true; do read -r -p "E-mail Let's Encrypt: " ACME_EMAIL; ACME_EMAIL="$(trim "$ACME_EMAIL")"; validate_email "$ACME_EMAIL" && break; echo "Некорректный e-mail."; done
  
  mapfile -t CURRENT_SSH_PORTS < <(current_ssh_ports)
  ((${#CURRENT_SSH_PORTS[@]})) || CURRENT_SSH_PORTS=(22)
  DEFAULT_SSH_PORT=5040
  if ((${#CURRENT_SSH_PORTS[@]} == 1)) && [[ "${CURRENT_SSH_PORTS[0]}" != 22 ]]; then
    DEFAULT_SSH_PORT="${CURRENT_SSH_PORTS[0]}"
    ok "SSH уже работает на нестандартном порту ${CURRENT_SSH_PORTS[0]} — он предложен по умолчанию."
  fi
  
  while true; do
    read -r -p "Новый SSH-порт [$DEFAULT_SSH_PORT]: " SSH_PORT; SSH_PORT="$(trim "$SSH_PORT")"; SSH_PORT="${SSH_PORT:-$DEFAULT_SSH_PORT}"
    validate_port "$SSH_PORT" || { echo "Порт: 1024-65535, кроме 5432/5678."; continue; }
    [[ "$SSH_PORT" != 22 ]] || { echo "Порт 22 должен быть изменён."; continue; }
    if ! printf '%s\n' "${CURRENT_SSH_PORTS[@]}" | grep -Fxq "$SSH_PORT" && port_in_use "$SSH_PORT"; then echo "TCP/$SSH_PORT занят."; continue; fi
    break
  done
  
  while true; do
    read -r -p "Часовой пояс [Europe/Berlin]: " GENERIC_TIMEZONE
    GENERIC_TIMEZONE="$(trim "$GENERIC_TIMEZONE")"; GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-Europe/Berlin}"
    if { command -v timedatectl >/dev/null 2>&1 && timedatectl list-timezones 2>/dev/null | awk -v z="$GENERIC_TIMEZONE" '$0==z{found=1} END{exit !found}'; } \
    || [[ -f "/usr/share/zoneinfo/$GENERIC_TIMEZONE" ]]; then
      break
    fi
    echo "Неизвестный timezone. Попробуйте снова."
  done
  
  read -r -p "Версия n8n [latest]: " N8N_VERSION; N8N_VERSION="$(trim "$N8N_VERSION")"; N8N_VERSION="${N8N_VERSION:-latest}"
  [[ "$N8N_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "Некорректный тег n8n."
  if [[ "$N8N_VERSION" == "latest" ]]; then
    warn "latest — плавающий тег. Для production рекомендуется зафиксировать версию (например, 1.72)."
  fi
  
  collect_admin
  printf '\nДомен: %s -> %s\nSSH: %s -> %s\n' "$DISPLAY_DOMAIN" "$DOMAIN" "${CURRENT_SSH_PORTS[*]}" "$SSH_PORT"
  ask_yes_no "Начать установку?" y || exit 0
}

check_web_ports(){
  local p owner own_stack=0
  if [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] && command -v docker >/dev/null 2>&1; then
    if (cd "$APP_DIR" && docker compose --env-file "$ENV_FILE" ps --services --status running 2>/dev/null | grep -Fxq caddy); then
      own_stack=1
    fi
  fi
  for p in 80 443; do
    if port_in_use "$p"; then
      if (( own_stack )); then
        ok "TCP/$p занят существующим Caddy этого n8n-стека — допустимо при обновлении."
      else
        owner="$(ss -ltnp "sport = :$p" 2>/dev/null | tail -n +2 | tr '\n' ' ')"
        die "TCP/$p занят посторонним процессом: $owner"
      fi
    fi
  done
}

check_dns(){
  local dns_ips server_ip aaaa
  dns_ips="$(dig +short A "$DOMAIN" | grep -E '^[0-9.]+$' || true)"
  server_ip="$(public_ipv4)"
  if [[ -z "$dns_ips" ]]; then
    warn "A-запись $DOMAIN отсутствует."
    ask_yes_no "Продолжить?" n || exit 1
  elif [[ -z "$server_ip" ]]; then
    warn "Не удалось определить публичный IPv4 VPS. A-запись домена: $(paste -sd, <<<"$dns_ips"). Совпадение автоматически НЕ подтверждено."
    ask_yes_no "Вы вручную проверили, что эта A-запись ведёт на данный VPS. Продолжить?" n || exit 1
  elif ! grep -Fxq "$server_ip" <<<"$dns_ips"; then
    warn "DNS -> $(paste -sd, <<<"$dns_ips"); публичный IPv4 VPS -> $server_ip. Не совпадают."
    ask_yes_no "Продолжить несмотря на несовпадение?" n || exit 1
  else
    ok "DNS соответствует публичному IPv4 VPS: $server_ip"
  fi
  aaaa="$(dig +short AAAA "$DOMAIN" | grep ':' || true)"
  [[ -z "$aaaa" ]] || warn "Есть AAAA: $(paste -sd, <<<"$aaaa"). Проверьте IPv6."
}

load_secret(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$ENV_FILE" 2>/dev/null || true; }

write_stack(){
  local old_pg="" old_key="" has_existing_volume=0
  if command -v docker >/dev/null 2>&1; then
    while IFS= read -r vol; do
      case "$vol" in n8n_n8n_data|n8n_postgres_data) has_existing_volume=1; break ;; esac
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
  fi
  
  if [[ ! -f "$ENV_FILE" && $has_existing_volume -eq 1 ]]; then
    die "Обнаружены существующие n8n/PostgreSQL volumes, но $ENV_FILE отсутствует. Новые секреты генерировать опасно. Восстановите .env из резервной копии."
  fi
  
  if [[ -f "$ENV_FILE" ]]; then
    old_pg="$(load_secret POSTGRES_PASSWORD)"; old_key="$(load_secret N8N_ENCRYPTION_KEY)"
    [[ -n "$old_pg" && -n "$old_key" ]] || die "Существующий .env неполон; секреты автоматически менять нельзя."
    warn "Повторный запуск: POSTGRES_PASSWORD и N8N_ENCRYPTION_KEY сохраняются."
    local backup="${APP_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "$APP_DIR" "$backup"
    mapfile -t old_backups < <(find "$(dirname "$APP_DIR")" -maxdepth 1 -type d -name "$(basename "$APP_DIR").backup-[0-9]*" -printf '%p\n' 2>/dev/null | sort -r | tail -n +6)
    ((${#old_backups[@]}==0)) || rm -rf -- "${old_backups[@]}"
  fi
  
  mkdir -p "$APP_DIR"
  POSTGRES_PASSWORD="${old_pg:-$(random_hex 32)}"; N8N_ENCRYPTION_KEY="${old_key:-$(random_hex 32)}"
  umask 077
  printf '%s\n' \
    "DOMAIN=$DOMAIN" "ACME_EMAIL=$ACME_EMAIL" "GENERIC_TIMEZONE=$GENERIC_TIMEZONE" "N8N_VERSION=$N8N_VERSION" \
    "POSTGRES_DB=n8n" "POSTGRES_USER=n8n" "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" "N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY" \
    "EXECUTIONS_DATA_MAX_AGE=48" >"$ENV_FILE"
  umask 022
  chmod 600 "$ENV_FILE"
  
  cat >"$COMPOSE_FILE" <<'COMPOSE'
name: n8n
services:
  postgres:
    image: postgres:18
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/18/docker
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 30s
    logging: &logging
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [backend]
  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${DOMAIN}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${DOMAIN}
      WEBHOOK_URL: https://${DOMAIN}/
      N8N_PROXY_HOPS: "1"
      N8N_SECURE_COOKIE: "true"
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${GENERIC_TIMEZONE}
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: ${EXECUTIONS_DATA_MAX_AGE}
      N8N_RUNNERS_ENABLED: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:5678/healthz || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s
    logging: *logging
    networks: [backend, frontend]
  caddy:
    image: caddy:2
    restart: unless-stopped
    environment:
      DOMAIN: ${DOMAIN}
      ACME_EMAIL: ${ACME_EMAIL}
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      n8n:
        condition: service_healthy
    logging: *logging
    networks: [frontend]
networks:
  backend:
    internal: true
  frontend: {}
volumes:
  postgres_data: {}
  n8n_data: {}
  caddy_data: {}
  caddy_config: {}
COMPOSE

  cat >"$CADDY_FILE" <<'CADDY'
{
  email {$ACME_EMAIL}
  acme_ca https://acme-v02.api.letsencrypt.org/directory
}
{$DOMAIN} {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
  }
  reverse_proxy n8n:5678
}
CADDY

  chmod 600 "$COMPOSE_FILE"; chmod 644 "$CADDY_FILE"
  
  cat >"$APP_DIR/backup.sh" <<'BACKUP'
#!/usr/bin/env bash
set -euo pipefail
umask 077
cd /opt/n8n
TS="$(date +%Y%m%d-%H%M%S)"
DEST="/var/backups/n8n-$TS"
mkdir -p "$DEST"
echo "Backing up PostgreSQL..."
docker compose exec -T postgres pg_dump -U n8n --no-sync n8n | gzip >"$DEST/db.sql.gz"
echo "Backing up n8n data volume..."
docker run --rm -v n8n_n8n_data:/data -v "$DEST:/backup" alpine \
  tar -czf /backup/n8n-data.tar.gz -C /data .
echo "Backing up .env..."
cp .env "$DEST/"
find /var/backups -maxdepth 1 -name 'n8n-*' -type d | sort -r | tail -n +8 | xargs -r rm -rf --
echo "Backup saved to $DEST"
BACKUP
  chmod +x "$APP_DIR/backup.sh"
}

validate_stack(){
  (cd "$APP_DIR" && docker compose --env-file "$ENV_FILE" config -q)
  local r max_age rendered_age
  r="$(cd "$APP_DIR" && docker compose --env-file "$ENV_FILE" config)"
  max_age="$(load_secret EXECUTIONS_DATA_MAX_AGE)"
  [[ "$max_age" =~ ^[0-9]+$ ]] && ((10#$max_age > 0)) || die "Некорректный EXECUTIONS_DATA_MAX_AGE в $ENV_FILE."
  rendered_age="$(awk '$1=="EXECUTIONS_DATA_MAX_AGE:" {gsub(/["'\'' ]/,"",$2); print $2; exit}' <<<"$r")"
  [[ "$rendered_age" == "$max_age" ]] || die "EXECUTIONS_DATA_MAX_AGE из $ENV_FILE не применён в Compose."
  grep -q 'DB_TYPE: postgresdb' <<<"$r" || die "PostgreSQL не настроен."
  grep -q 'EXECUTIONS_DATA_PRUNE: "true"' <<<"$r" || die "Pruning выключен."
  grep -q 'N8N_DIAGNOSTICS_ENABLED: "false"' <<<"$r" || die "Diagnostics включены."
  ok "Compose валиден."
}

configure_firewall_phase1(){
  local p
  for p in "${CURRENT_SSH_PORTS[@]}"; do
    if [[ "$p" != "$SSH_PORT" ]]; then ufw allow "$p/tcp" comment "SSH old temporary"; fi
  done
  ufw limit "$SSH_PORT/tcp" comment "SSH"
  ufw allow 80/tcp comment HTTP; ufw allow 443/tcp comment HTTPS; ufw allow 443/udp comment HTTP3
  ufw default deny incoming; ufw default allow outgoing; ufw --force enable
}

ssh_port_files(){
  local f
  if [[ -f /etc/ssh/sshd_config ]]; then printf '%s\n' /etc/ssh/sshd_config; fi
  for f in /etc/ssh/sshd_config.d/*.conf; do
    if [[ -f "$f" && "$f" != "$SSH_DROPIN" ]]; then printf '%s\n' "$f"; fi
  done
  return 0
}

backup_ssh_configs(){
  SSH_BACKUP_DIR="$(mktemp -d /tmp/n8n-ssh-backup.XXXXXX)"
  local f rel
  while IFS= read -r f; do
    rel="${f#/}"
    mkdir -p "$SSH_BACKUP_DIR/$(dirname "$rel")"
    cp -a "$f" "$SSH_BACKUP_DIR/$rel"
  done < <(ssh_port_files)
}

restore_ssh_configs(){
  local f rel
  [[ -n "${SSH_BACKUP_DIR:-}" && -d "$SSH_BACKUP_DIR" ]] || return 0
  while IFS= read -r f; do
    rel="${f#"$SSH_BACKUP_DIR/"}"
    install -D -m 0644 "$f" "/$rel"
  done < <(find "$SSH_BACKUP_DIR" -type f)
  rm -f "$SSH_DROPIN"
  
  reload_ssh || true
}

disable_explicit_ports(){
  local f tmp
  while IFS= read -r f; do
    tmp="$(mktemp)"
    awk '
BEGIN{inmatch=0}
/^[[:space:]]*Match[[:space:]]/{inmatch=1}
!inmatch && tolower($0) ~ /^[[:space:]]*port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$/ {
  print "# n8n-installer disabled: " $0; next
}
{print}
' "$f" >"$tmp"
    cat "$tmp" >"$f"; rm -f "$tmp"
  done < <(ssh_port_files)
}

ensure_ssh_include(){
  if ! grep -q '^[[:space:]]*Include[[:space:]]/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    echo 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config
  fi
}

# Применение SSH-конфигурации. На Ubuntu 24.04 sshd запускается через ssh.socket,
# который сам держит порт 22 и игнорирует Port из sshd_config. Поэтому socket-активацию
# отключаем, и sshd слушает порты, заданные в конфиге.
reload_ssh(){
  mkdir -p /run/sshd; chmod 755 /run/sshd
  sshd -t || return 1
  systemctl daemon-reload
  if systemctl cat ssh.socket >/dev/null 2>&1; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  fi
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh || systemctl restart sshd || return 1
}

configure_ssh(){
  mkdir -p /run/sshd
  chmod 755 /run/sshd
  mkdir -p "$(dirname "$SSH_DROPIN")"

  if printf '%s\n' "${CURRENT_SSH_PORTS[@]}" | grep -Fxq "$SSH_PORT"; then
    ok "SSH уже слушает $SSH_PORT"
    return
  fi
  
  ensure_ssh_include
  backup_ssh_configs
  disable_explicit_ports
  
  local p
  {
    echo '# Managed by n8n installer - temporary migration window'
    for p in "${CURRENT_SSH_PORTS[@]}"; do printf 'Port %s\n' "$p"; done
    printf 'Port %s\n' "$SSH_PORT"
  } >"$SSH_DROPIN"
  
  log "Содержимое $SSH_DROPIN:"
  cat "$SSH_DROPIN" | sed 's/^/  /'
  
  if ! reload_ssh; then
    log "Ошибка reload_ssh. Выполняю откат."
    restore_ssh_configs
    die "Не удалось применить временную SSH-конфигурацию. Исходные файлы восстановлены."
  fi
  
  log "Эффективная конфигурация sshd (порты):"
  sshd -T 2>/dev/null | grep -i '^port ' | sed 's/^/  /' || log "  (не удалось получить)"
  
  if ! wait_for_port "$SSH_PORT" 30; then
    log "Диагностика перед откатом:"
    log "  Слушаемые TCP-порты:"
    ss -H -ltn 2>/dev/null | sed 's/^/    /' || true
    log "  Логи sshd (последние 15 строк):"
    journalctl -u ssh.service -u ssh.socket --no-pager -n 15 2>/dev/null | sed 's/^/    /' || true
    restore_ssh_configs
    die "Новый SSH-порт $SSH_PORT не поднялся за 30 секунд. Выполнен откат."
  fi
  
  for p in "${CURRENT_SSH_PORTS[@]}"; do
    if ! port_in_use "$p"; then
      restore_ssh_configs
      die "Старый SSH-порт $p пропал до подтверждения нового входа. Выполнен откат."
    fi
  done
  
  local ip; ip="$(public_ipv4)"; ip="${ip:-IP_СЕРВЕРА}"
  warn "Если в панели провайдера есть внешний файрвол — откройте в нём TCP/$SSH_PORT, TCP 80, TCP+UDP 443."
  warn "Проверьте ВО ВТОРОМ окне: ssh -p $SSH_PORT ${ADMIN_USER:-${SUDO_USER:-root}}@$ip"
  
  if ask_yes_no "Удалось успешно войти по новому SSH-порту?" n; then
    printf '# Managed by n8n installer\nPort %s\n' "$SSH_PORT" >"$SSH_DROPIN"
    reload_ssh || { restore_ssh_configs; die "Финальная SSH-конфигурация не применилась; выполнен откат."; }
    
    if ! wait_for_port "$SSH_PORT" 30; then
      restore_ssh_configs
      die "Новый SSH-порт исчез после финализации; выполнен откат."
    fi
    
    for p in "${CURRENT_SSH_PORTS[@]}"; do
      if [[ "$p" != "$SSH_PORT" ]] && port_in_use "$p"; then
        restore_ssh_configs
        die "Старый SSH-порт $p всё ещё слушается после финализации. Выполнен откат; UFW старого порта не закрывался."
      fi
    done
    
    for p in "${CURRENT_SSH_PORTS[@]}"; do
      [[ "$p" == "$SSH_PORT" ]] || ufw --force delete allow "$p/tcp" >/dev/null 2>&1 || true
    done
    
    rm -rf -- "${SSH_BACKUP_DIR:-}"
    ok "SSH миграция подтверждена: слушается только новый TCP/$SSH_PORT."
  else
    warn "Новый SSH-вход не подтверждён — выполняю полный откат SSH."
    restore_ssh_configs
    ufw --force delete allow "$SSH_PORT/tcp" >/dev/null 2>&1 || true
    warn "Исходные SSH-конфиги восстановлены, старые UFW-порты сохранены."
    exit 1
  fi
}

harden_ssh(){
  if [[ -z "$ADMIN_USER" ]]; then
    if sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'; then
      ok "Вход под root в SSH уже отключён — дополнительных действий не требуется."
    else
      warn "Отдельный пользователь не создан — вход под root в SSH НЕ отключён."
    fi
    return 0
  fi
  local ip eff conf q; ip="$(public_ipv4)"; ip="${ip:-IP_СЕРВЕРА}"
  echo
  if [[ "$ADMIN_AUTH" == key ]]; then
    warn "Проверьте вход под $ADMIN_USER по ключу: ssh -p $SSH_PORT $ADMIN_USER@$ip  (затем: sudo -v)."
    q="Вход по ключу под $ADMIN_USER работает. Отключить вход по паролю и вход под root?"
    conf='# Managed by n8n installer\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n'
  else
    warn "Проверьте вход под $ADMIN_USER по паролю: ssh -p $SSH_PORT $ADMIN_USER@$ip  (затем: sudo -v)."
    q="Вход под $ADMIN_USER по паролю работает. Отключить вход под root?"
    conf='# Managed by n8n installer\nPermitRootLogin no\n'
  fi
  if ! ask_yes_no "$q" n; then
    warn "Hardening пропущен: вход под root остаётся включённым."
    return 0
  fi
  printf "$conf" >"$HARDEN_DROPIN"
  if ! reload_ssh; then
    rm -f "$HARDEN_DROPIN"; reload_ssh || true
    warn "Не удалось применить hardening SSH; изменения отменены."
    return 0
  fi
  eff="$(sshd -T 2>/dev/null || true)"
  if grep -qx 'permitrootlogin no' <<<"$eff" && { [[ "$ADMIN_AUTH" != key ]] || grep -qx 'passwordauthentication no' <<<"$eff"; }; then
    if [[ "$ADMIN_AUTH" == key ]]; then HARDENED=1; else HARDENED=2; fi
    ok "SSH hardening применён."
  else
    rm -f "$HARDEN_DROPIN"; reload_ssh || true
    warn "Hardening не вступил в силу (его перебивает другой конфиг sshd); изменения отменены."
  fi
}

setup_fail2ban(){
  mkdir -p /etc/fail2ban/jail.d
  printf '[sshd]\nenabled = true\nport = %s\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n' "$SSH_PORT" >/etc/fail2ban/jail.d/n8n-sshd.local
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl restart fail2ban; then ok "fail2ban включён для SSH (порт $SSH_PORT)."; else warn "fail2ban не запустился — проверьте: journalctl -u fail2ban"; fi
}

install_backup_cron(){
  systemctl enable --now cron >/dev/null 2>&1 || true
  printf '15 3 * * * root %s/backup.sh >>/var/log/n8n-backup.log 2>&1\n' "$APP_DIR" >/etc/cron.d/n8n-backup
  chmod 644 /etc/cron.d/n8n-backup
  ok "Ежедневный бэкап (03:15) -> /var/backups, хранится 7 копий."
}

write_credentials(){
  local ip login sudo_line ssh_note
  ip="$(public_ipv4)"; ip="${ip:-IP_СЕРВЕРА}"; login="${ADMIN_USER:-${SUDO_USER:-root}}"
  if [[ -z "$ADMIN_USER" && "$login" == root ]]; then sudo_line="(отдельный пользователь не создавался, вход под root)"
  elif [[ -z "$ADMIN_USER" ]]; then sudo_line="(используется существующий пользователь $login; пароль не менялся)"
  elif [[ -n "$ADMIN_PASS" && "$ADMIN_AUTH" == key ]]; then sudo_line="$ADMIN_PASS   (нужен только для sudo; вход по SSH — по ключу)"
  elif [[ -n "$ADMIN_PASS" ]]; then sudo_line="$ADMIN_PASS   (для входа по SSH и для sudo)"
  else sudo_line="(пользователь существовал ранее — пароль не менялся)"; fi
  case "$HARDENED" in
    1) ssh_note="отключены вход по паролю и вход под root" ;;
    2) ssh_note="вход под root отключён; вход по паролю разрешён (защита: fail2ban)" ;;
    *) if sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'; then ssh_note="вход под root отключён (настроено ранее, например secure-vps.sh)"
       else ssh_note="НЕ применён (вход под root разрешён)"; fi ;;
  esac
  [[ ! -f "$CRED_FILE" ]] || { cp -a "$CRED_FILE" "$CRED_FILE.prev"; chmod 600 "$CRED_FILE.prev"; }
  ( umask 077; cat >"$CRED_FILE" <<EOF
=== ДОСТУПЫ n8n (перенесите в менеджер паролей, затем удалите файл с сервера) ===
Создан: $(date '+%F %T')

[SSH]
Команда:        ssh -p $SSH_PORT $login@$ip
Пользователь:   $login
Пароль:         $sudo_line
SSH-hardening:  $ssh_note

[n8n]
URL:            https://$DOMAIN/
Owner-аккаунт:  создаётся вами при первом открытии URL (e-mail и пароль задаёте сами)
Версия образа:  $N8N_VERSION
N8N_ENCRYPTION_KEY: $(load_secret N8N_ENCRYPTION_KEY)
  (потеряете ключ — все сохранённые credentials в n8n станут нечитаемыми)

[PostgreSQL] (только во внутренней docker-сети, снаружи недоступен)
host=postgres  port=5432  db=$(load_secret POSTGRES_DB)  user=$(load_secret POSTGRES_USER)
password=$(load_secret POSTGRES_PASSWORD)

[Файлы на сервере]
Каталог стека:  $APP_DIR  (.env, compose.yaml, Caddyfile, backup.sh)
Бэкапы:         /var/backups/n8n-*  (ежедневно 03:15, 7 копий; копируйте за пределы VPS)

[Команды]
Перезапуск:     cd $APP_DIR && docker compose restart
Обновление:     cd $APP_DIR && docker compose pull && docker compose up -d
Чистка образов: docker image prune -f
Логи:           cd $APP_DIR && docker compose logs -f --tail=100
EOF
  )
  chmod 600 "$CRED_FILE"
  ok "Файл доступов: $CRED_FILE"
}

start_stack(){
  cd "$APP_DIR"
  docker compose --env-file "$ENV_FILE" pull
  docker compose --env-file "$ENV_FILE" up -d
  local i status=""
  for i in {1..60}; do
    status="$(docker compose ps --format json n8n 2>/dev/null | grep -o '"Health":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [[ "$status" == healthy ]] && break
    [[ "$status" == unhealthy ]] && { docker compose logs --tail=100 n8n; die "n8n unhealthy."; }
    sleep 2
  done
  [[ "$status" == healthy ]] || { docker compose logs --tail=100 n8n; die "n8n не стал healthy за 120 секунд."; }
  docker compose ps
}

post_checks(){
  cd "$APP_DIR"
  docker compose exec -T postgres pg_isready -h 127.0.0.1 -U n8n -d n8n >/dev/null || die "PostgreSQL не готов."
  local i https_ok=0
  for i in $(seq 1 12); do
    if curl -fsS --max-time 10 "https://$DOMAIN/healthz" >/dev/null 2>&1; then https_ok=1; break; fi
    sleep 5
  done
  if (( https_ok )); then ok "HTTPS работает: https://$DOMAIN/"; else warn "HTTPS пока не подтверждён; проверьте DNS и: docker compose logs caddy"; fi
  printf '\nГОТОВО\nURL:        https://%s/\nSSH:        ssh -p %s %s@<IP>\nДоступы:    %s  (читать: sudo cat)\nExecutions: хранятся %s ч (EXECUTIONS_DATA_MAX_AGE в %s)\n\nПерезапуск: cd %s && docker compose restart\nОбновление: cd %s && docker compose pull && docker compose up -d\n' \
    "$DOMAIN" "$SSH_PORT" "${ADMIN_USER:-${SUDO_USER:-root}}" "$CRED_FILE" "$(grep '^EXECUTIONS_DATA_MAX_AGE=' "$ENV_FILE" | cut -d= -f2)" "$ENV_FILE" "$APP_DIR" "$APP_DIR"
  echo
  warn "СРАЗУ откройте https://$DOMAIN/ и создайте первый Owner-аккаунт n8n (User Management)."
  warn "Скопируйте $CRED_FILE в менеджер паролей и удалите файл с сервера. Бэкапы /var/backups храните также вне VPS."
}

self_test(){
  local fails=0 t
  for t in n8n.example.ru xn--80arbjktj.xn--p1ai n8n.xn--p1ai; do validate_ascii_domain "$t" || { echo "FAIL domain $t"; fails=$((fails+1)); }; done
  for t in 1.2.3.4 a.b 'evil\name.ru' evil/name.ru; do validate_ascii_domain "$t" && { echo "FAIL invalid domain accepted: $t"; fails=$((fails+1)); }; done
  [[ "$(to_ascii_domain ' n8n.example.ru. ')" == "n8n.example.ru" ]] || { echo "FAIL trailing dot/trim"; fails=$((fails+1)); }
  to_ascii_domain 'n8n.example.ru..' >/dev/null 2>&1 && { echo "FAIL double trailing dot"; fails=$((fails+1)); }
  validate_port 5040 || { echo "FAIL 5040"; fails=$((fails+1)); }
  validate_port 504 && { echo "FAIL: 504 accepted"; fails=$((fails+1)); }
  validate_port 5432 && { echo "FAIL: 5432 accepted"; fails=$((fails+1)); }
  validate_email admin@example.ru || { echo "FAIL email"; fails=$((fails+1)); }
  if command -v idn2 >/dev/null; then
    [[ "$(to_ascii_domain 'пример.рф')" == "xn--e1afmkfd.xn--p1ai" ]] || { echo "FAIL IDN"; fails=$((fails+1)); }
  else
    warn "idn2 не установлен — IDN-тест пропущен (установится через install_base)"
  fi
  ((fails==0)) && echo "SELF-TEST: PASS" || { echo "SELF-TEST: FAIL ($fails)"; return 1; }
}

main(){
  [[ "${1:-}" == --self-test ]] && { self_test; return; }
  preflight; collect_inputs
  install_base; setup_admin; install_docker
  check_web_ports; check_dns; write_stack; validate_stack
  configure_firewall_phase1; configure_ssh; harden_ssh; setup_fail2ban
  install_backup_cron; start_stack; write_credentials; post_checks
}

main "$@"