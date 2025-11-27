#!/bin/bash

# Настройки
DANTE_CONF_DIR="/etc/dante"
DANTE_PROXIES_DIR="${DANTE_CONF_DIR}/proxies"
DANTE_USERS_DB="${DANTE_CONF_DIR}/users.db"
HTTP_PORT_START=10000
SOCKS_PORT_START=20000

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Функции ---

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от пользователя root."
    fi
}

check_os() {
    if ! grep -q "Debian GNU/Linux 11" /etc/os-release; then
        log_warn "ОС не Debian 11. Скрипт разработан для Debian 11 и может работать некорректно на других системах."
        read -p "Продолжить на свой страх и риск? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[yY]$ ]]; then
            log_error "Выход по запросу пользователя."
        fi
    fi
}

update_system() {
    log_info "Обновление системы..."
    apt update -y || log_error "Ошибка при обновлении списка пакетов."
    apt upgrade -y || log_error "Ошибка при обновлении пакетов."
    apt autoremove -y || log_error "Ошибка при удалении старых пакетов."
    log_info "Система обновлена."
}

install_dante_ufw() {
    log_info "Установка dante-server и ufw..."
    apt install -y dante-server ufw iproute2 net-tools openssl || log_error "Ошибка при установке dante-server, ufw или других зависимостей."
    log_info "dante-server и ufw установлены."
}

configure_ufw_base() {
    log_info "Настройка UFW..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "Allow SSH"
    ufw enable || log_error "Ошибка при включении UFW."
    log_info "UFW настроен и включен (разрешен SSH)."
}

get_network_info() {
    log_info "Сбор сетевой информации..."

    # Получаем основной интерфейс по умолчанию для IPv4
    PRIMARY_INTERFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
    if [ -z "$PRIMARY_INTERFACE" ]; then
        log_error "Не удалось определить основной сетевой интерфейс для IPv4."
    fi
    log_info "Основной сетевой интерфейс: $PRIMARY_INTERFACE"

    # Получаем IPv4 адрес VDS
    VDS_IPV4=$(ip -4 addr show dev "$PRIMARY_INTERFACE" | grep inet | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    if [ -z "$VDS_IPV4" ]; then
            log_error "Не удалось получить IPv4 адрес VDS с интерфейса $PRIMARY_INTERFACE."
    fi
    log_info "IPv4 адрес VDS: $VDS_IPV4"

    # Получаем все IPv6 /64 подсети на интерфейсе
    ALL_IPV6_ADDRS_64=($(ip -6 addr show dev "$PRIMARY_INTERFACE" | grep inet6 | grep '/64' | awk '{print $2}'))
    if [ ${#ALL_IPV6_ADDRS_64[@]} -eq 0 ]; then
        log_error "Не найдено ни одной IPv6 /64 подсети на интерфейсе $PRIMARY_INTERFACE. Убедитесь, что ваш провайдер назначил ее."
    fi

    # Выбираем случайную IPv6 /64 подсеть
    SELECTED_IPV6_CIDR=${ALL_IPV6_ADDRS_64[$((RANDOM % ${#ALL_IPV6_ADDRS_64[@]}))]}
    
    # Извлекаем префикс /64 из выбранного CIDR
    # Например, из 2001:db8:abcd:0001::1/64 получаем 2001:db8:abcd:0001
    IPV6_PREFIX_PART=$(echo "$SELECTED_IPV6_CIDR" | cut -d'/' -f1 | awk -F: '{print $1":"$2":"$3":"$4}')
    log_info "Выбрана IPv6 /64 подсеть (префикс): ${IPV6_PREFIX_PART}::/64"
}

generate_ipv6_addr() {
    local prefix_part="$1" # e.g., 2001:db8:abcd:0001
    
    # Генерируем четыре 16-битных случайных сегмента для хостовой части
    RAND_HEX1=$(openssl rand -hex 2)
    RAND_HEX2=$(openssl rand -hex 2)
    RAND_HEX3=$(openssl rand -hex 2)
    RAND_HEX4=$(openssl rand -hex 2)

    # Собираем полный IPv6 адрес
    echo "${prefix_part}:${RAND_HEX1}:${RAND_HEX2}:${RAND_HEX3}:${RAND_HEX4}"
}

generate_random_string() {
    head /dev/urandom | tr -dc A-Za-z0-9_ | head -c "$1"
}

configure_dante() {
    local proxy_id=$1
    local http_port=$2
    local socks_port=$3
    local proxy_username=$4
    local proxy_password=$5
    local generated_ipv6=$6

    log_info "Настройка прокси $proxy_id (HTTP:$http_port, SOCKS5:$socks_port) с исходящим IPv6 $generated_ipv6"

    # Создаем системного пользователя для аутентификации Dante
    useradd -M -s /usr/sbin/nologin "$proxy_username" || log_error "Ошибка при создании пользователя $proxy_username."
    echo "$proxy_username:$proxy_password" | chpasswd || log_error "Ошибка при установке пароля для пользователя $proxy_username."

    # Добавляем сгенерированный IPv6 адрес на интерфейс
    ip -6 addr add "${generated_ipv6}/64" dev "$PRIMARY_INTERFACE" || log_error "Ошибка при добавлении IPv6 $generated_ipv6 на $PRIMARY_INTERFACE."
    log_info "IPv6 ${generated_ipv6}/64 добавлен на $PRIMARY_INTERFACE."

    # Создаем файл конфигурации для данного прокси
    cat <<EOF > "${DANTE_PROXIES_DIR}/proxy_${proxy_id}.conf"
# SOCKS5 Proxy ${proxy_id}
internal: ${PRIMARY_INTERFACE} port ${socks_port}
external: ${PRIMARY_INTERFACE}:${generated_ipv6}
socksmethod: username none
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
    socksmethod: username
}

# HTTP Proxy ${proxy_id}
internal: ${PRIMARY_INTERFACE} port ${http_port}
external: ${PRIMARY_INTERFACE}:${generated_ipv6}
clientmethod: username none
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
EOF

    # Открываем порты в UFW
    ufw allow "${http_port}/tcp" comment "Dante HTTP Proxy ${proxy_id}" || log_warn "Не удалось открыть HTTP порт ${http_port} в UFW."
    ufw allow "${socks_port}/tcp" comment "Dante SOCKS5 Proxy ${proxy_id}" || log_warn "Не удалось открыть SOCKS5 порт ${socks_port} в UFW."

    log_info "Конфигурация для прокси $proxy_id создана. Порты открыты в UFW."
}

# --- Основная логика скрипта ---

check_root
check_os
update_system
install_dante_ufw
configure_ufw_base
get_network_info

# Очищаем старые конфиги Dante
log_info "Очистка предыдущих конфигураций Dante..."
systemctl stop dante-server 2>/dev/null | 
| true
rm -f ${DANTE_CONF_DIR}/danted.conf
rm -rf ${DANTE_PROXIES_DIR}
mkdir -p ${DANTE_PROXIES_DIR}
log_info "Старые конфиги удалены, создан каталог ${DANTE_PROXIES_DIR}."

# Спрашиваем количество прокси
read -p "Сколько прокси вы хотите создать (по 1 HTTP и SOCKS5 на каждый)? " NUM_PROXIES
if ! [[ "$NUM_PROXIES" =~ ^[0-9]+$ ]] || [ "$NUM_PROXIES" -le 0 ]; then
    log_error "Некорректное количество прокси. Должно быть положительное число."
fi

# Основной danted.conf для включения всех под-конфигураций
cat <<EOF > ${DANTE_CONF_DIR}/danted.conf
logoutput: syslog user.info
user.privileged: root
user.notprivileged: nobody

# Include all proxy specific configurations
include: ${DANTE_PROXIES_DIR}/*.conf
EOF

# Массивы для хранения информации о прокси
declare -a PROXY_INFO

# Создание прокси в цикле
log_info "Начинается создание ${NUM_PROXIES} прокси..."
for ((i=1; i<=$NUM_PROXIES; i++)); do
    CURRENT_HTTP_PORT=$((HTTP_PORT_START + i - 1))
    CURRENT_SOCKS_PORT=$((SOCKS_PORT_START + i - 1))
    PROXY_USERNAME=$(generate_random_string 10)
    PROXY_PASSWORD=$(generate_random_string 12)
    GENERATED_IPV6=$(generate_ipv6_addr "$IPV6_PREFIX_PART")

    configure_dante "$i" "$CURRENT_HTTP_PORT" "$CURRENT_SOCKS_PORT" "$PROXY_USERNAME" "$PROXY_PASSWORD" "$GENERATED_IPV6"
    
    PROXY_INFO+=("--- Proxy ${i} ---
    IPv4 VDS: ${VDS_IPV4}
    HTTP Port: ${CURRENT_HTTP_PORT}
    SOCKS5 Port: ${CURRENT_SOCKS_PORT}
    Username: ${PROXY_USERNAME}
    Password: ${PROXY_PASSWORD}
    Outgoing IPv6: ${GENERATED_IPV6}")
done

log_info "Перезапуск службы Dante-server..."
systemctl daemon-reload
systemctl restart dante-server || log_error "Ошибка при перезапуске dante-server. Проверьте логи: journalctl -u dante-server."
systemctl enable dante-server || log_warn "Не удалось включить dante-server для автозапуска."
log_info "Служба Dante-server успешно перезапущена."

log_info "Перезагрузка правил UFW..."
ufw reload || log_warn "Ошибка при перезагрузке UFW правил."

log_info "--- Все прокси успешно настроены! ---"
echo ""
echo -e "${GREEN}Список ваших прокси:${NC}"
for info in "${PROXY_INFO[@]}"; do
    echo -e "${YELLOW}${info}${NC}"
done
echo ""
echo -e "${YELLOW}Важно:${NC} Сгенерированные IPv6 адреса (${IPV6_PREFIX_PART}::/64) будут работать до перезагрузки сервера."
echo "Для их постоянства после перезагрузки вам нужно вручную добавить их в конфигурацию сети вашего сервера (например, в /etc/network/interfaces или /etc/systemd/network/). "
echo "Примеры настройки смотрите в подробном гайде выше."
echo ""
log_info "Для проверки используйте команды curl, как описано в гайде."
