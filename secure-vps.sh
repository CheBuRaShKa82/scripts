#!/usr/bin/env bash
# Для нового Ubuntu/Debian VPS с systemd. Запуск: sudo bash secure-vps.sh
set -Eeuo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Запустите от root или через sudo.'
[[ -t 0 ]] || die 'Нужен интерактивный терминал.'
[[ -f /etc/os-release ]] || die 'Неизвестная ОС.'
. /etc/os-release
[[ $ID == ubuntu || $ID == debian ]] || die 'Поддерживаются только Ubuntu и Debian.'
[[ -d /run/systemd/system ]] || die 'Требуется systemd.'

echo '================================================================'
echo '  Настройка базовой безопасности VPS (Ubuntu / Debian)          '
echo '================================================================'
echo 'ВАЖНО: заранее откройте выбранный SSH-порт в firewall панели'
echo 'хостинга (если он есть), иначе проверка входа не пройдёт и'
echo 'скрипт откатит изменения.'
echo

# 0. Базовые пакеты ставим сразу: они нужны для проверок ниже
#    (ssh-keygen, ss, ufw, curl, python3). Пакеты ставятся до подтверждения и
#    при последующем отказе НЕ удаляются; пакеты могут создать свои конфиги
#    по умолчанию, но настройки этого скрипта ещё не применяются.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
echo 'Установка необходимых пакетов...'
apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" install -y sudo ufw fail2ban curl ca-certificates openssh-server \
  openssh-client libpam-modules python3 python3-systemd iproute2

# 1. Проверка окружения
VIRT=$(systemd-detect-virt 2>/dev/null || true)
if [[ $VIRT == lxc || $VIRT == openvz ]]; then
  echo "Внимание: контейнерная виртуализация ($VIRT)."
  echo "UFW и часть параметров sysctl в таком окружении могут не работать."
  read -r -p 'Продолжить? [y/N]: ' CONT
  [[ ${CONT,,} == y* ]] || exit 0
fi

for u in ubuntu debian admin ec2-user; do
  if getent passwd "$u" >/dev/null 2>&1; then
    echo "Инфо: в системе есть пользователь '$u'. По SSH ему доступ будет закрыт (AllowUsers),"
    echo "      но через консоль хостинга он может остаться доступен (проверьте NOPASSWD в sudoers)."
  fi
done
echo

# 2. Telegram
read -r -s -p 'Telegram Bot Token: ' TOKEN; echo
[[ $TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die 'Неверный формат токена.'
read -r -p 'TG_CHAT_ID (ID чата, группы или канала): ' TG_CHAT_ID
[[ $TG_CHAT_ID =~ ^-?[0-9]+$ ]] || die 'TG_CHAT_ID должен быть числом.'

# 3. Пользователь
read -r -p 'Имя нового администратора [admin]: ' USERNAME
USERNAME=${USERNAME:-admin}
[[ $USERNAME =~ ^[a-z][a-z0-9_-]{0,30}$ && $USERNAME != root ]] || die 'Недопустимое имя пользователя.'
! getent passwd "$USERNAME" >/dev/null || die 'Пользователь уже существует.'
! getent group "$USERNAME" >/dev/null || die 'Группа с таким именем уже существует. Выберите другое имя.'

# 4. Аутентификация SSH
echo
echo 'Выберите способ аутентификации по SSH:'
echo '  1) SSH-ключ (Рекомендуется, вход по паролю отключается)'
echo '  2) Пароль (Подвержен брутфорсу)'
read -r -p 'Ваш выбор [1]: ' AUTH_CHOICE
AUTH_CHOICE=${AUTH_CHOICE:-1}
[[ $AUTH_CHOICE =~ ^[12]$ ]] || die 'Неверный выбор. Введите 1 или 2.'

validate_ssh_pubkey() {
  local key="$1" tmp ktype
  tmp=$(mktemp)
  printf '%s\n' "$key" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  ktype=$(awk '{print $1}' "$tmp")
  rm -f "$tmp"
  [[ $ktype =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$ ]]
}

SSH_PUBKEY=""
if [[ $AUTH_CHOICE == 1 ]]; then
  if [[ -s /root/.ssh/authorized_keys ]]; then
    echo 'Найденные ключи в /root/.ssh/authorized_keys:'
    ssh-keygen -lf /root/.ssh/authorized_keys || true
    read -r -p 'Скопировать чистые ключи (без опций провайдера) новому пользователю? [Y/n]: ' USE_ROOT_KEYS
    if [[ ${USE_ROOT_KEYS^^} != N* ]]; then
      while IFS= read -r line; do
        if [[ -n $line ]] && validate_ssh_pubkey "$line"; then
          SSH_PUBKEY+="$line"$'\n'
        fi
      done < <(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
      [[ -n $SSH_PUBKEY ]] || echo 'Подходящих ключей без опций не найдено.'
    fi
  fi

  if [[ -z $SSH_PUBKEY ]]; then
    echo 'Вставьте ваш публичный SSH-ключ одной строкой:'
    read -r SSH_PUBKEY
    validate_ssh_pubkey "$SSH_PUBKEY" || die 'Недопустимый формат SSH-ключа (DSA запрещён).'
  fi
fi

# 5. Пароль для sudo
echo
while true; do
  read -r -s -p "Пароль для $USERNAME (необходим для sudo, от 12 символов): " PASSWORD; echo
  read -r -s -p 'Повторите пароль: ' PASSWORD2; echo
  if [[ ${#PASSWORD} -ge 12 && $PASSWORD == "$PASSWORD2" ]]; then
    break
  fi
  echo 'Пароли не совпадают или длина менее 12 символов.'
done

# 6. Порт SSH
read -r -p 'SSH-порт [22222]: ' PORT
PORT=${PORT:-22222}
[[ $PORT =~ ^[0-9]{1,5}$ ]] || die 'Неверный порт.'
PORT=$((10#$PORT))
(( PORT >= 1024 && PORT <= 65535 )) || die 'Порт должен быть в диапазоне 1024-65535.'
[[ -z $(ss -H -ltn "sport = :$PORT") ]] || die "Порт $PORT уже занят. Выберите другой порт."

# 7. Белый список fail2ban
DEFAULT_IP=${SSH_CONNECTION:-}
DEFAULT_IP=${DEFAULT_IP%% *}
if [[ -z $DEFAULT_IP ]]; then
  # sudo сбрасывает окружение; пробуем определить адрес по текущему tty
  DEFAULT_IP=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true)
fi
if [[ -n $DEFAULT_IP ]] && ! python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$DEFAULT_IP" 2>/dev/null; then
  DEFAULT_IP=""
fi
WHITELIST=""
read -r -p "Ваш IP/подсеть для белого списка fail2ban [${DEFAULT_IP:-пропустить}]: " WHITELIST
WHITELIST=${WHITELIST:-$DEFAULT_IP}
if [[ -n $WHITELIST ]]; then
  WL_RC=0
  python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1], strict=False); sys.exit(2 if n.prefixlen==0 else 0)' \
    "$WHITELIST" 2>/dev/null || WL_RC=$?
  case $WL_RC in
    0) ;;
    2) die 'Нельзя добавлять весь Интернет (0.0.0.0/0 или ::/0) в белый список Fail2Ban.' ;;
    *) die 'Некорректный IP/подсеть для белого списка.' ;;
  esac
fi

# 8. Автообновления
read -r -p 'Включить автоматические обновления безопасности? [Y/n]: ' AUTO_UPGRADES
AUTO_UPGRADES=${AUTO_UPGRADES:-Y}

# 9. Состояние UFW
UFW_STATUS=$(LC_ALL=C ufw status 2>/dev/null || true)
UFW_WAS_ACTIVE=0
[[ $UFW_STATUS == *"Status: active"* ]] && UFW_WAS_ACTIVE=1
UFW_RESET=1
if (( UFW_WAS_ACTIVE )); then
  echo
  echo 'UFW уже активен. Текущие правила:'
  ufw status numbered || true
  read -r -p 'Сбросить ВСЕ правила и оставить только SSH? [y/N]: ' RESET_ANS
  [[ ${RESET_ANS,,} == y* ]] || UFW_RESET=0
fi

echo
printf 'Пользователь: %s\n' "$USERNAME"
printf 'Вход по SSH: %s\n' "$([[ $AUTH_CHOICE == 1 ]] && echo 'Только ключ' || echo 'Пароль')"
printf 'Порт: %s\n' "$PORT"
printf 'TG_CHAT_ID: %s\n' "$TG_CHAT_ID"
printf 'Белый список fail2ban: %s\n' "${WHITELIST:-нет}"
printf 'Сброс правил UFW: %s\n' "$([[ $UFW_RESET == 1 ]] && echo 'Да' || echo 'Нет')"
printf 'Автообновления безопасности: %s\n' "$([[ ${AUTO_UPGRADES^^} != N* ]] && echo 'Да' || echo 'Нет')"
read -r -p 'Применить настройки? Введите YES: ' CONFIRM
[[ ${CONFIRM^^} == YES ]] || exit 0

# Проверка Telegram до критических изменений
send_test() {
  local result
  result=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN" |
    curl --config - --silent --show-error --fail --connect-timeout 4 --max-time 10 \
      --data-urlencode "chat_id=$1" --data-urlencode 'text=✅ [VPS] Тест уведомлений пройден.' 2>/dev/null) || return 1
  printf '%s' "$result" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)'
}
if ! send_test "$TG_CHAT_ID"; then
  echo 'Предупреждение: Telegram недоступен или сообщение не доставлено.' >&2
  echo 'Настройка VPS будет продолжена; Telegram-уведомления могут не работать, пока доступ к api.telegram.org не восстановится.' >&2
fi

if [[ ${AUTO_UPGRADES^^} != N* ]]; then
  apt-get "${APT_OPTS[@]}" install -y unattended-upgrades
  echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
fi

# Резервное копирование и трекинг файлов
BACKUP=$(mktemp -d /root/secure-vps-backup-XXXXXXXX)
declare -a NEW_FILES=()
declare -a RESTORE_FILES=()

track_and_backup() {
  local file="$1"
  if [[ -e $file ]]; then
    local rel="${file#/}"
    mkdir -p "$BACKUP/orig/$(dirname "$rel")"
    cp -a "$file" "$BACKUP/orig/$rel"
    RESTORE_FILES+=("$file")
  else
    NEW_FILES+=("$file")
  fi
}

SOCKET_ACTIVE=0
if systemctl is-active --quiet ssh.socket; then
  SOCKET_ACTIVE=1
fi

SOCKET_FILE=/etc/systemd/system/ssh.socket.d/99-secure-vps.conf
SSH_DROPIN=/etc/ssh/sshd_config.d/01-secure-vps.conf
SYSCTL_FILE=/etc/sysctl.d/99-security.conf
F2B_JAIL=/etc/fail2ban/jail.d/99-secure-vps.local
F2B_ACTION=/etc/fail2ban/action.d/telegram.conf
SUDOERS_FILE=/etc/sudoers.d/99-secure-vps-user
TG_CONF=/etc/ssh-login-telegram.conf
PAM_SCRIPT=/usr/local/libexec/ssh-login-telegram.sh
F2B_SCRIPT=/usr/local/libexec/fail2ban-telegram.sh

track_and_backup /etc/ssh/sshd_config
track_and_backup /etc/pam.d/sshd
track_and_backup /etc/ufw
track_and_backup "$SSH_DROPIN"
track_and_backup "$SOCKET_FILE"
track_and_backup "$SYSCTL_FILE"
track_and_backup "$F2B_JAIL"
track_and_backup "$F2B_ACTION"
track_and_backup "$SUDOERS_FILE"
track_and_backup "$TG_CONF"
track_and_backup "$PAM_SCRIPT"
track_and_backup "$F2B_SCRIPT"

# Запоминаем текущие значения sysctl для отката в рантайме
SYSCTL_KEYS=(
  net.ipv4.tcp_syncookies
  net.ipv4.conf.all.accept_redirects
  net.ipv4.conf.default.accept_redirects
  net.ipv4.conf.all.send_redirects
  net.ipv4.conf.all.accept_source_route
  net.ipv4.conf.default.accept_source_route
  net.ipv6.conf.all.accept_redirects
  net.ipv6.conf.default.accept_redirects
)
declare -A SYSCTL_OLD=()
for k in "${SYSCTL_KEYS[@]}"; do
  if v=$(sysctl -n "$k" 2>/dev/null); then
    SYSCTL_OLD[$k]=$v
  fi
done

CHANGED=1
FIREWALL_PENDING=0
USER_CREATED=0

rollback() {
  local status=$?
  set +eu
  trap - ERR INT TERM HUP
  unset PASSWORD PASSWORD2 TOKEN SSH_PUBKEY
  echo
  echo '!!! Запущен откат изменений... !!!' >&2

  if (( FIREWALL_PENDING )); then
    echo 'Откат настроек UFW (SSH и пользователь сохраняются)...' >&2
    ufw --force disable || true
    if [[ -d "$BACKUP/orig/etc/ufw" ]]; then
      rm -rf /etc/ufw
      cp -a "$BACKUP/orig/etc/ufw" /etc/ufw
    fi
    if (( UFW_WAS_ACTIVE )); then
      ufw allow "$PORT/tcp" || true
      ufw --force enable || true
    fi
    systemctl restart fail2ban 2>/dev/null || true
    echo 'UFW возвращён в безопасное состояние. Проверьте правила: ufw status verbose' >&2
    echo "Резервные копии: $BACKUP" >&2
    exit "$status"
  fi

  if (( CHANGED )); then
    echo 'Восстановление исходных конфигураций...' >&2
    for f in "${NEW_FILES[@]}"; do
      rm -f "$f"
    done
    for f in "${RESTORE_FILES[@]}"; do
      local rel="${f#/}"
      if [[ -e "$BACKUP/orig/$rel" ]]; then
        [[ -d "$BACKUP/orig/$rel" ]] && rm -rf "$f"
        cp -a "$BACKUP/orig/$rel" "$f"
      fi
    done
    if (( UFW_WAS_ACTIVE )); then
      ufw reload >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload || true
    if (( SOCKET_ACTIVE )); then
      systemctl stop ssh.service 2>/dev/null || true
      systemctl restart ssh.socket 2>/dev/null || true
    else
      systemctl restart ssh.service 2>/dev/null || true
    fi

    sysctl --system >/dev/null 2>&1 || true
    for k in "${!SYSCTL_OLD[@]}"; do
      sysctl -qw "$k=${SYSCTL_OLD[$k]}" 2>/dev/null || true
    done
    systemctl restart fail2ban 2>/dev/null || systemctl stop fail2ban 2>/dev/null || true
  fi

  if (( USER_CREATED )); then
    echo "Удаление созданного пользователя $USERNAME..." >&2
    loginctl terminate-user "$USERNAME" 2>/dev/null || true
    pkill -KILL -u "$USERNAME" 2>/dev/null || true
    sleep 1
    userdel -rf "$USERNAME" 2>/dev/null \
      || echo "Не удалось удалить $USERNAME. Выполните вручную: userdel -rf $USERNAME" >&2
  fi

  echo "Откат завершён. Резервные копии сохранены в: $BACKUP" >&2
  exit "$status"
}
trap rollback ERR INT TERM HUP

# 10. Создание пользователя и sudo
useradd -m -s /bin/bash "$USERNAME"
USER_CREATED=1
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
unset PASSWORD PASSWORD2
usermod -aG sudo "$USERNAME"

printf '%s ALL=(ALL:ALL) PASSWD: ALL\n' "$USERNAME" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
visudo -c >/dev/null

# sudo должен требовать пароль: ловим конфликтующие NOPASSWD-правила провайдера/cloud-init
if runuser -u "$USERNAME" -- sudo -n -k true >/dev/null 2>&1; then
  echo "Ошибка: sudo для $USERNAME работает без пароля (NOPASSWD)." >&2
  echo 'Проверьте /etc/sudoers и /etc/sudoers.d/.' >&2
  false
fi

if [[ $AUTH_CHOICE == 1 ]]; then
  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"
  printf '%s\n' "$SSH_PUBKEY" | sed '/^$/d' > "/home/$USERNAME/.ssh/authorized_keys"
  chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/authorized_keys"
  unset SSH_PUBKEY
fi

# 11. Скрипты Telegram
install -d -m 755 /usr/local/libexec
printf '%s\n%s\n' "$TOKEN" "$TG_CHAT_ID" > "$TG_CONF"
chmod 600 "$TG_CONF"
unset TOKEN

cat > "$PAM_SCRIPT" <<'NOTIFY'
#!/usr/bin/env bash
set -u
[[ ${PAM_TYPE:-} == open_session ]] || exit 0
[[ -r /etc/ssh-login-telegram.conf ]] || exit 0
mapfile -t cfg < /etc/ssh-login-telegram.conf
[[ ${#cfg[@]} == 2 ]] || exit 0
token=${cfg[0]}; chat=${cfg[1]}
server_ips=$(hostname -I 2>/dev/null || true)
msg=$(printf '✅ SSH Login\nHost: %s\nIP: %s\nUser: %s\nFrom: %s\nTime: %s' \
  "$(hostname)" "${server_ips:-unknown}" "${PAM_USER:-unknown}" "${PAM_RHOST:-local}" "$(date -Is)")
(
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
    curl --config - --silent --fail --connect-timeout 3 --max-time 8 \
      --data-urlencode "chat_id=$chat" --data-urlencode "text=$msg" >/dev/null 2>&1 || true
) </dev/null >/dev/null 2>&1 &
exit 0
NOTIFY
chmod 700 "$PAM_SCRIPT"
bash -n "$PAM_SCRIPT"

cat > "$F2B_SCRIPT" <<'F2BNOTIFY'
#!/usr/bin/env bash
set -u
name="${1:-sshd}"
ip="${2:-unknown}"
failures="${3:-unknown}"
[[ -r /etc/ssh-login-telegram.conf ]] || exit 0
mapfile -t cfg < /etc/ssh-login-telegram.conf
[[ ${#cfg[@]} == 2 ]] || exit 0
token=${cfg[0]}; chat=${cfg[1]}
msg=$(printf '🚨 [Fail2Ban] Бан IP\nHost: %s\nJail: %s\nIP: %s\nПопыток: %s\nВремя: %s' \
  "$(hostname)" "$name" "$ip" "$failures" "$(date -Is)")
(
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
    curl --config - --silent --fail --connect-timeout 3 --max-time 8 \
      --data-urlencode "chat_id=$chat" --data-urlencode "text=$msg" >/dev/null 2>&1 || true
) </dev/null >/dev/null 2>&1 &
exit 0
F2BNOTIFY
chmod 700 "$F2B_SCRIPT"
bash -n "$F2B_SCRIPT"

sed -i '\|^[[:space:]]*session[[:space:]].*/usr/local/libexec/ssh-login-telegram\.sh[[:space:]]*$|d' /etc/pam.d/sshd
printf '\nsession optional pam_exec.so quiet seteuid /usr/local/libexec/ssh-login-telegram.sh\n' >> /etc/pam.d/sshd

# 12. Параметры sysctl
cat > "$SYSCTL_FILE" <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
chmod 644 "$SYSCTL_FILE"
sysctl --system >/dev/null 2>&1 || echo 'Предупреждение: не все параметры sysctl применились.' >&2

# 13. Настройка SSH
install -d -m 755 /etc/ssh/sshd_config.d
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
sed -i -E 's/^[[:space:]]*(Port[[:space:]]+[0-9]+)/# \1 # disabled by secure-vps/' /etc/ssh/sshd_config

if [[ $AUTH_CHOICE == 1 ]]; then
  AUTH_SETTINGS=$(cat <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
EOF
)
else
  AUTH_SETTINGS=$(cat <<EOF
PubkeyAuthentication no
PasswordAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
AuthenticationMethods password
EOF
)
fi

cat > "$SSH_DROPIN" <<EOF
Port $PORT
PermitRootLogin no
$AUTH_SETTINGS
UsePAM yes
AllowUsers $USERNAME
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxStartups 10:30:60
PermitUserEnvironment no
LogLevel VERBOSE
EOF
chmod 644 "$SSH_DROPIN"

install -d -m 755 /run/sshd
# Старые OpenSSH (< 8.7) не знают KbdInteractiveAuthentication: пробуем запасное имя
if ! /usr/sbin/sshd -t 2>/dev/null; then
  if grep -q '^KbdInteractiveAuthentication' "$SSH_DROPIN"; then
    sed -i 's/^KbdInteractiveAuthentication/ChallengeResponseAuthentication/' "$SSH_DROPIN"
  fi
fi
/usr/sbin/sshd -t

# Проверка ЭФФЕКТИВНОЙ конфигурации: OpenSSH берёт первое найденное значение,
# поэтому более ранний drop-in (например 00-provider.conf) мог бы перебить наш.
# -C нужен, чтобы учитывались подходящие Match-блоки.
SSHD_TEST_ADDR=${WHITELIST%%/*}
SSHD_TEST_ADDR=${SSHD_TEST_ADDR:-127.0.0.1}
SSHD_EFFECTIVE=$(/usr/sbin/sshd -T -C "user=$USERNAME,host=localhost,addr=$SSHD_TEST_ADDR")

require_sshd() {
  local expected="$1"
  if ! grep -qxF "$expected" <<< "$SSHD_EFFECTIVE"; then
    echo "Ошибка: sshd не применил ожидаемый параметр: $expected" >&2
    echo 'Фактические значения:' >&2
    grep -Ei '^(port|passwordauthentication|pubkeyauthentication|permitrootlogin|allowusers|authenticationmethods) ' \
      <<< "$SSHD_EFFECTIVE" >&2 || true
    echo 'Проверьте другие файлы в /etc/ssh/sshd_config.d/ и Match-блоки.' >&2
    false
  fi
}

mapfile -t SSHD_PORTS < <(awk '$1 == "port" {print $2}' <<< "$SSHD_EFFECTIVE")
if (( ${#SSHD_PORTS[@]} != 1 )) || [[ ${SSHD_PORTS[0]} != "$PORT" ]]; then
  echo "Ошибка: sshd должен использовать только порт $PORT." >&2
  printf 'Фактические Port: %s\n' "${SSHD_PORTS[*]:-нет}" >&2
  echo 'Проверьте другие Port в /etc/ssh/sshd_config и /etc/ssh/sshd_config.d/.' >&2
  false
fi
require_sshd "permitrootlogin no"
require_sshd "allowusers $USERNAME"
if [[ $AUTH_CHOICE == 1 ]]; then
  require_sshd "pubkeyauthentication yes"
  require_sshd "passwordauthentication no"
  require_sshd "authenticationmethods publickey"
else
  require_sshd "pubkeyauthentication no"
  require_sshd "passwordauthentication yes"
  require_sshd "authenticationmethods password"
fi

# 14. Применение порта
ufw allow "$PORT/tcp"

if (( SOCKET_ACTIVE )); then
  install -d -m 755 /etc/systemd/system/ssh.socket.d
  printf '[Socket]\nListenStream=\nListenStream=%s\n' "$PORT" > "$SOCKET_FILE"
  chmod 644 "$SOCKET_FILE"
  systemctl daemon-reload
  systemctl stop ssh.service || true
  systemctl restart ssh.socket
else
  systemctl enable ssh.service
  systemctl restart ssh.service
fi

wait_ssh_port() {
  for _ in {1..10}; do
    if [[ -n $(ss -H -ltn "sport = :$PORT") ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Порт $PORT не начал прослушиваться за 5 секунд." >&2
  return 1
}
wait_ssh_port

echo 'Проверенные эффективные параметры OpenSSH:'
grep -Ei '^(port|passwordauthentication|pubkeyauthentication|permitrootlogin|allowusers|authenticationmethods) ' \
  <<< "$SSHD_EFFECTIVE" || true

# 15. Fail2Ban
cat > "$F2B_ACTION" <<EOF
[Definition]
actionban = /usr/local/libexec/fail2ban-telegram.sh "<name>" "<ip>" "<failures>"
actionunban =
EOF
chmod 644 "$F2B_ACTION"

cat > "$F2B_JAIL" <<EOF
[sshd]
enabled = true
port = $PORT
backend = systemd
banaction = ufw
action = %(banaction)s[port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
         telegram
ignoreip = 127.0.0.1/8 ::1 $WHITELIST
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
EOF
chmod 644 "$F2B_JAIL"

fail2ban-client -t
systemctl enable fail2ban
systemctl restart fail2ban

wait_fail2ban() {
  for _ in {1..15}; do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo 'Fail2Ban не поднял jail sshd; проверьте: journalctl -u fail2ban' >&2
  return 1
}
wait_fail2ban

echo
echo '================================================================'
echo '  ПРОВЕРКА 1: Проверьте новый SSH-доступ!                       '
echo '  НЕ ЗАКРЫВАЙТЕ ЭТОТ ТЕРМИНАЛ! (Таймаут ожидания: 5 минут)      '
echo '================================================================'
printf 'Убедитесь, что порт %s/tcp открыт в firewall панели хостинга.\n' "$PORT"
printf 'В новом терминале выполните:\n'
printf '  ssh -p %s %s@IP_СЕРВЕРА\n\n' "$PORT" "$USERNAME"
printf 'Затем проверьте: sudo -v\n'
printf 'И убедитесь, что в Telegram пришло сообщение о входе.\n\n'

ANSWER=""
read -t 300 -r -p 'Вход, sudo и уведомление сработали? Введите YES: ' ANSWER || false
if [[ ${ANSWER^^} != YES ]]; then
  false
fi

# 16. Изоляция UFW (пользователь и SSH проверены, откат их больше не трогает)
CHANGED=0
USER_CREATED=0
FIREWALL_PENDING=1

echo
if (( UFW_RESET )); then
  echo '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
  printf '  ВНИМАНИЕ: СЕЙЧАС БУДУТ УДАЛЕНЫ ВСЕ ПРАВИЛА UFW!\n'
  printf '  Останется разрешён только порт %s/tcp.\n' "$PORT"
  echo '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
  sleep 2
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
else
  echo 'Существующие правила UFW сохраняются; добавляется только порт SSH.'
fi
ufw allow "$PORT/tcp"
ufw --force enable

systemctl restart fail2ban
wait_fail2ban

echo
echo '================================================================'
echo '  ПРОВЕРКА 2: Финальный тест после включения UFW                '
echo '  НЕ ЗАКРЫВАЙТЕ ЭТОТ ТЕРМИНАЛ! (Таймаут ожидания: 5 минут)      '
echo '================================================================'
printf 'Повторно подключитесь в новом окне терминала:\n'
printf '  ssh -p %s %s@IP_СЕРВЕРА\n\n' "$PORT" "$USERNAME"

ANSWER2=""
read -t 300 -r -p 'Повторный вход после UFW работает? Введите YES: ' ANSWER2 || false
if [[ ${ANSWER2^^} != YES ]]; then
  false
fi

FIREWALL_PENDING=0
trap - ERR INT TERM HUP

echo
echo '================================================================'
echo '  Базовая защита VPS успешно настроена!                         '
echo '================================================================'
printf 'Пользователь: %s | SSH-порт: %s\n' "$USERNAME" "$PORT"
printf 'Авторизация: %s\n' "$([[ $AUTH_CHOICE == 1 ]] && echo 'SSH-ключ' || echo 'Пароль')"
printf 'Резервная копия оригинальных конфигов: %s\n' "$BACKUP"
echo
echo 'Важное примечание по Docker:'
echo '  Docker управляет iptables напрямую и игнорирует ufw default deny.'
echo '  Публикуйте порты только на локальный адрес: -p 127.0.0.1:8080:8080'
echo '  или настраивайте фильтрацию внутри цепочки DOCKER-USER.'
echo
echo 'Для веб-сервера выполните позже: sudo ufw allow 80/tcp && sudo ufw allow 443/tcp'
