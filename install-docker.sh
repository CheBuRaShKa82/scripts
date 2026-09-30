#!/usr/bin/env bash
set -Eeuo pipefail

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Определение привилегий
# ------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    if ! command -v sudo >/dev/null 2>&1; then
        die "Скрипт запущен не от root, а утилита sudo не установлена."
    fi

    SUDO=(sudo)
fi

# ------------------------------------------------------------
# Определение ОС
# ------------------------------------------------------------

if [[ ! -r /etc/os-release ]]; then
    die "Файл /etc/os-release не найден."
fi

# shellcheck disable=SC1091
source /etc/os-release

DISTRO=""
CODENAME=""

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
        # Попытка определить базовый дистрибутив для совместимых
        # Ubuntu/Debian-производных.
        if [[ "${ID_LIKE:-}" =~ ubuntu ]]; then
            DISTRO="ubuntu"
            CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

        elif [[ "${ID_LIKE:-}" =~ debian ]]; then
            DISTRO="debian"
            CODENAME="${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
        fi
        ;;
esac

if [[ -z "$DISTRO" || -z "$CODENAME" ]]; then
    die "Неподдерживаемая ОС или не удалось определить codename (${PRETTY_NAME:-${ID:-неизвестно}})."
fi

command -v dpkg >/dev/null 2>&1 ||
    die "Команда dpkg не найдена."

ARCH="$(dpkg --print-architecture)"

if [[ -z "$ARCH" ]]; then
    die "Не удалось определить архитектуру."
fi

echo "========================================"
echo " Установка Docker Engine"
echo "========================================"
echo "ОС:          ${PRETTY_NAME:-$DISTRO}"
echo "База:        $DISTRO"
echo "Codename:    $CODENAME"
echo "Архитектура: $ARCH"
echo "========================================"
echo

# ------------------------------------------------------------
# Удаление конфликтующих пакетов
# ------------------------------------------------------------

echo "[1/7] Удаление потенциально конфликтующих пакетов..."

"${SUDO[@]}" apt-get remove -y \
    docker.io \
    docker-doc \
    docker-compose \
    docker-compose-v2 \
    docker-buildx \
    podman-docker \
    containerd \
    runc 2>/dev/null || true

# ------------------------------------------------------------
# Зависимости
# ------------------------------------------------------------

echo
echo "[2/7] Обновление индексов и установка зависимостей..."

"${SUDO[@]}" apt-get update -qq

"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl

# ------------------------------------------------------------
# GPG-ключ Docker
# ------------------------------------------------------------

echo
echo "[3/7] Добавление официального GPG-ключа Docker..."

"${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings

"${SUDO[@]}" curl -fsSL \
    "https://download.docker.com/linux/${DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc

"${SUDO[@]}" chmod a+r /etc/apt/keyrings/docker.asc

# ------------------------------------------------------------
# Репозиторий Docker
# ------------------------------------------------------------

echo
echo "[4/7] Добавление официального репозитория Docker..."

"${SUDO[@]}" tee \
    /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DISTRO}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# ------------------------------------------------------------
# Установка Docker
# ------------------------------------------------------------

echo
echo "[5/7] Обновление списка пакетов Docker..."

"${SUDO[@]}" apt-get update -qq

echo
echo "[6/7] Установка Docker Engine, Buildx и Compose..."

"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# ------------------------------------------------------------
# Запуск службы Docker
# ------------------------------------------------------------

echo
echo "[7/7] Запуск службы Docker..."

if [[ -d /run/systemd/system ]]; then
    "${SUDO[@]}" systemctl enable --now docker
else
    echo "Предупреждение: systemd не обнаружен или не запущен."
    echo "Автоматический запуск Docker через systemctl пропущен."
fi

# ------------------------------------------------------------
# Проверка установки
# ------------------------------------------------------------

echo
echo "========================================"
echo " Docker успешно установлен"
echo "========================================"

docker --version
docker compose version

if [[ -d /run/systemd/system ]]; then
    echo
    echo "Статус службы Docker:"

    "${SUDO[@]}" systemctl \
        --no-pager \
        --full \
        status docker |
        sed -n '1,12p'
fi

# ------------------------------------------------------------
# Настройка запуска Docker без sudo
# ------------------------------------------------------------

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo
    echo "Docker сейчас можно запускать через sudo."
    echo
    echo "При желании пользователя '$SUDO_USER' можно добавить"
    echo "в группу docker для запуска без sudo."
    echo
    echo "ВНИМАНИЕ: членство в группе docker предоставляет"
    echo "практически root-доступ к системе."
    echo

    ADD_DOCKER_GROUP="n"

    if [[ -t 0 ]]; then
        read -r -p "Добавить $SUDO_USER в группу docker? [y/N]: " \
            ADD_DOCKER_GROUP || ADD_DOCKER_GROUP="n"
    else
        echo "Неинтерактивный запуск: добавление в группу docker пропущено."
    fi

    if [[ "${ADD_DOCKER_GROUP,,}" == "y" ||
          "${ADD_DOCKER_GROUP,,}" == "yes" ]]; then

        "${SUDO[@]}" usermod -aG docker "$SUDO_USER"

        echo
        echo "Пользователь $SUDO_USER добавлен в группу docker."
        echo "Для применения изменений перелогиньтесь"
        echo "или выполните:"
        echo
        echo "  newgrp docker"
    fi
fi

# ------------------------------------------------------------
# Финальная подсказка
# ------------------------------------------------------------

echo
echo "Для проверки Docker выполните:"
echo
echo "  sudo docker run --rm hello-world"
echo