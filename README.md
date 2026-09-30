# 🛡️ VPS Setup Scripts

Набор Bash-скриптов для быстрой первоначальной настройки **Ubuntu / Debian VPS**:

- 🔐 базовое усиление безопасности сервера;
- 👤 создание отдельного администратора;
- 🔑 настройка SSH по ключу или паролю;
- 🔥 настройка UFW;
- 🚫 защита SSH через Fail2Ban;
- 📲 Telegram-уведомления о входах и блокировках;
- 🐳 установка Docker Engine и Docker Compose из официального репозитория Docker.

> Скрипты предназначены для свежих VPS на Ubuntu или Debian с `systemd`.

---

## 📦 Что входит в репозиторий

| Скрипт | Назначение |
|---|---|
| `secure-vps-telegram-optional.sh` | Интерактивная базовая защита VPS: пользователь, SSH, UFW, Fail2Ban, sysctl, Telegram и резервное копирование конфигов |
| `install-docker.sh` | Автоматическая установка Docker Engine, Buildx и Docker Compose Plugin для Ubuntu / Debian |

---

# 🔐 secure-vps-telegram-optional.sh

Скрипт выполняет первоначальную настройку безопасности нового VPS и старается снизить риск потери SSH-доступа во время изменений.

## Возможности

- автоматическое определение Ubuntu / Debian;
- проверка наличия `systemd`;
- установка необходимых системных пакетов;
- создание отдельного пользователя-администратора;
- добавление пользователя в группу `sudo`;
- обязательный пароль для `sudo`;
- выбор способа SSH-аутентификации:
  - SSH-ключ;
  - пароль;
- запрет входа по SSH под `root`;
- смена SSH-порта;
- ограничение SSH через `AllowUsers`;
- уменьшение числа попыток входа;
- отключение X11 Forwarding;
- отключение SSH Agent Forwarding;
- настройка keepalive;
- проверка итоговой конфигурации через `sshd -T`;
- поддержка систем с `ssh.service` и `ssh.socket`;
- настройка UFW;
- настройка Fail2Ban для SSH;
- постепенное увеличение времени блокировки Fail2Ban;
- белый список IP / подсети;
- базовые защитные параметры `sysctl`;
- автоматические security updates;
- Telegram-уведомления:
  - успешный SSH-вход;
  - блокировка IP через Fail2Ban;
- резервное копирование изменяемых конфигураций;
- автоматический rollback при ошибке;
- обязательная проверка SSH-доступа перед окончательным применением UFW.

---

## ⚠️ Перед запуском

Рекомендуется запускать скрипт через консоль VPS-провайдера или держать текущую SSH-сессию открытой.

Если у провайдера есть внешний firewall / security group, **заранее разрешите выбранный SSH-порт**.

Не закрывайте текущую SSH-сессию, пока скрипт не попросит проверить подключение в новом терминале.

---

## 🚀 Запуск

Скачайте репозиторий:

```bash
git clone https://github.com/CheBuRaShKa82/scripts.git
```
cd scripts
```

Выдайте права на выполнение:

```bash
chmod +x secure-vps-telegram-optional.sh install-docker.sh
```

Запустите:

```bash
sudo ./secure-vps-telegram-optional.sh
```

или:

```bash
sudo bash secure-vps-telegram-optional.sh
```

---

## 🔑 SSH-аутентификация

Во время установки можно выбрать один из вариантов.

### 1. SSH-ключ

Рекомендуемый вариант.

Скрипт может использовать подходящие ключи из:

```text
/root/.ssh/authorized_keys
```

или попросит вставить публичный ключ вручную.

После настройки:

```text
PasswordAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
```

### 2. Пароль

При необходимости можно оставить вход по паролю.

В этом режиме:

```text
PubkeyAuthentication no
PasswordAuthentication yes
PermitRootLogin no
AuthenticationMethods password
```

Для защиты от перебора паролей дополнительно используется Fail2Ban.

---

## 👤 Новый администратор

По умолчанию предлагается пользователь:

```text
admin
```

Можно указать другое имя.

Для нового пользователя:

- создаётся домашний каталог;
- назначается `/bin/bash`;
- пользователь добавляется в `sudo`;
- `sudo` требует пароль;
- при выборе SSH-ключа создаётся `~/.ssh/authorized_keys`.

---

## 🔥 UFW

Скрипт настраивает firewall и разрешает выбранный SSH-порт.

Если UFW уже используется, скрипт покажет текущие правила и спросит, нужно ли их сбрасывать.

После настройки базовая политика выглядит примерно так:

```text
Incoming: deny
Outgoing: allow
```

SSH-порт разрешается отдельно.

Для веб-сервера после установки можно открыть:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Проверка:

```bash
sudo ufw status verbose
```

---

## 🚫 Fail2Ban

Создаётся jail для `sshd`.

Основные параметры:

```text
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
```

Проверить состояние:

```bash
sudo fail2ban-client status
```

SSH jail:

```bash
sudo fail2ban-client status sshd
```

Просмотр логов:

```bash
sudo journalctl -u fail2ban
```

---

## 📲 Telegram-уведомления

Скрипт может отправлять уведомления через Telegram Bot API.

Используются:

```text
Telegram Bot Token
TG_CHAT_ID
```

Уведомления отправляются при:

- успешном SSH-входе;
- блокировке IP через Fail2Ban.

Пример сообщения:

```text
✅ SSH Login
Host: server
IP: 192.0.2.10
User: admin
From: 198.51.100.25
Time: 2026-09-30T12:00:00+00:00
```

Данные Telegram сохраняются с ограниченными правами доступа.

---

## 🧯 Защита от потери доступа

Перед критическими изменениями скрипт сохраняет оригинальные конфигурации.

При ошибке выполняется rollback:

- восстанавливаются конфиги SSH;
- восстанавливаются настройки UFW;
- восстанавливаются параметры sysctl;
- перезапускаются SSH и Fail2Ban;
- при необходимости удаляется созданный пользователь.

После настройки скрипт дважды просит проверить SSH:

1. после изменения SSH;
2. после окончательного включения UFW.

Это позволяет обнаружить ошибку до закрытия текущей сессии.

---

## 🧠 Sysctl

Скрипт применяет несколько базовых сетевых настроек безопасности:

```text
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
```

---

# 🐳 install-docker.sh

Универсальный установщик Docker для Ubuntu и Debian.

Скрипт автоматически определяет дистрибутив через:

```text
/etc/os-release
```

и подключает соответствующий официальный репозиторий:

```text
[https://download.docker.com/linux/ubuntu](https://download.docker.com/linux/ubuntu)
```

или:

```text
[https://download.docker.com/linux/debian](https://download.docker.com/linux/debian)
```

---

## Что устанавливается

```text
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

То есть после установки доступны:

```bash
docker
docker compose
docker buildx
```

---

## 🚀 Установка Docker

```bash
chmod +x install-docker.sh
sudo ./install-docker.sh
```

Скрипт:

1. определит Ubuntu или Debian;
2. определит codename системы;
3. определит архитектуру;
4. удалит потенциально конфликтующие неофициальные пакеты;
5. установит `ca-certificates` и `curl`;
6. добавит официальный GPG-ключ Docker;
7. создаст `/etc/apt/sources.list.d/docker.sources`;
8. установит Docker Engine, Buildx и Compose Plugin;
9. включит Docker через systemd;
10. предложит добавить пользователя в группу `docker`;
11. покажет версии Docker и Docker Compose.

---

## ✅ Проверка Docker

После установки:

```bash
sudo docker run --rm hello-world
```

Версия Docker:

```bash
docker --version
```

Docker Compose:

```bash
docker compose version
```

Статус службы:

```bash
sudo systemctl status docker
```

---

# 🐳 Docker + UFW

> [!IMPORTANT]
> Docker самостоятельно управляет `iptables`.

Из-за этого опубликованный Docker-порт может оказаться доступен извне даже при:

```text
ufw default deny incoming
```

Если контейнер должен быть доступен только локально, публикуйте его на `127.0.0.1`.

Например:

```bash
docker run -p 127.0.0.1:8080:8080 image
```

В `docker-compose.yml`:

```yaml
services:
  app:
    ports:
      - "127.0.0.1:8080:8080"
```

Если Docker-контейнер должен быть доступен снаружи, правила фильтрации лучше дополнительно контролировать через цепочку:

```text
DOCKER-USER
```

---

# 🖥️️ Поддерживаемые системы

Скрипты рассчитаны на:

- Ubuntu;
- Debian;
- `systemd`;
- `apt`;
- OpenSSH.

Не предназначены для:

- CentOS;
- AlmaLinux;
- Rocky Linux;
- Fedora;
- Alpine Linux;
- Arch Linux.

---

# 📋 Рекомендуемый порядок установки нового VPS

Для нового сервера удобно использовать следующий порядок:

### 1. Настроить безопасность

```bash
sudo ./secure-vps-telegram-optional.sh
```

Проверить новый SSH-доступ.

### 2. Переподключиться новым пользователем

```bash
ssh -p PORT USER@SERVER_IP
```

### 3. Установить Docker

```bash
sudo ./install-docker.sh
```

### 4. Проверить

```bash
sudo docker run --rm hello-world
sudo ufw status verbose
sudo fail2ban-client status sshd
```

---

# 🔎 Полезные команды

### SSH

```bash
sudo sshd -t
```

Показать эффективную конфигурацию:

```bash
sudo sshd -T
```

### UFW

```bash
sudo ufw status numbered
```

### Fail2Ban

```bash
sudo fail2ban-client status sshd
```

### Docker

```bash
docker ps
docker compose version
sudo systemctl status docker
```

### Логи SSH

Ubuntu / Debian:

```bash
sudo journalctl -u ssh
```

или:

```bash
sudo journalctl -u ssh.service
```

---

# ⚠️ Важное предупреждение

Любые изменения SSH и firewall потенциально могут привести к потере удалённого доступа к серверу.

Перед использованием:

- убедитесь, что у вас есть доступ к консоли VPS-провайдера;
- не закрывайте активную SSH-сессию до завершения проверки;
- проверьте внешний firewall хостинга;
- внимательно читайте вопросы скрипта перед подтверждением.

Используйте скрипты на свой риск и сначала протестируйте их на отдельном VPS.

---

# 📄 License

Проект распространяется под лицензией [MIT](LICENSE).

---

## ⭐ Поддержка проекта

Если скрипты оказались полезными — поставьте репозиторию ⭐.

Pull Request и предложения по улучшению приветствуются.
Pull Request и предложения по улучшению приветствуются.
