#!/usr/bin/env bash
set -Eeuo pipefail

# Универсальная установка Docker Engine для Ubuntu и Debian
# Использует официальный APT-репозиторий Docker.

if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Ошибка: скрипт запущен не от root, а команда sudo не установлена."
        echo "Запустите скрипт от root или установите sudo."
        exit 1
    fi
    SUDO="sudo"
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Ошибка: файл /etc/os-release не найден."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    ubuntu)
        DISTRO="ubuntu"
        CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        ;;
    debian)
        DISTRO="debian"
        CODENAME="${VERSION_CODENAME:-}"
        ;;
    *)
        echo "Ошибка: неподдерживаемая ОС: ${PRETTY_NAME:-${ID:-неизвестно}}"
        echo "Поддерживаются только Ubuntu и Debian."
        exit 1
        ;;
esac

if [[ -z "$CODENAME" ]]; then
    echo "Ошибка: не удалось определить codename дистрибутива."
    exit 1
fi

ARCH="$(dpkg --print-architecture)"

echo "========================================"
echo " Установка Docker Engine"
echo "========================================"
echo "ОС:          ${PRETTY_NAME:-$DISTRO}"
echo "Дистрибутив: $DISTRO"
echo "Codename:    $CODENAME"
echo "Архитектура: $ARCH"
echo "========================================"
echo

echo "[1/6] Обновление списка пакетов..."
$SUDO apt update

echo "[2/6] Установка ca-certificates и curl..."
$SUDO apt install -y ca-certificates curl

echo "[3/6] Добавление официального GPG-ключа Docker..."
$SUDO install -m 0755 -d /etc/apt/keyrings
$SUDO curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc
$SUDO chmod a+r /etc/apt/keyrings/docker.asc

echo "[4/6] Добавление официального репозитория Docker..."
$SUDO tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DISTRO}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

echo "[5/6] Обновление списка пакетов Docker..."
$SUDO apt update

echo "[6/6] Установка Docker Engine, Buildx и Docker Compose..."
$SUDO apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo
echo "Проверка службы Docker..."
$SUDO systemctl enable --now docker

echo
echo "========================================"
echo " Docker успешно установлен"
echo "========================================"
docker --version || $SUDO docker --version
docker compose version || $SUDO docker compose version

echo
echo "Статус службы:"
$SUDO systemctl --no-pager --full status docker | sed -n '1,12p'

echo
echo "Для проверки можно выполнить:"
echo "  sudo docker run hello-world"
