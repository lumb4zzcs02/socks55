#!/bin/bash

# Настройки
DANTE_CONF_DIR="/etc/dante"
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

# --- Основная логика скрипта ---

check_root
check_os
update_system
install_dante_ufw
configure_ufw_base
get_network_info

# Очищаем старые конфиги Dante
log_info "Очистка предыдущих конфигураций Dante..."
systemctl stop danted 2>/dev/null || true
rm -f ${DANTE_CONF_DIR}/danted.conf
rm -rf ${DANTE_CONF_DIR}/proxies # Убедимся, что папка proxies удалена
log_info "Старые конфиги удалены."

# Спрашиваем количество прокси
read -p "Сколько прокси вы хотите создать (по 1 HTTP и SOCKS5 на каждый)? " NUM_PROXIES
if ! [[ "$NUM_PROXIES" =~ ^[0-9]+$ ]] || [ "$NUM_PROXIES" -le 0 ]; then
    log_error "Некорректное количество прокси. Должно быть положительное число."
fi

# Инициализируем основную конфигурацию Dante в переменную
DANTE_GLOBAL_CONFIG=""
DANTE_GLOBAL_CONFIG+="logoutput: syslog user.info\n"
DANTE_GLOBAL_CONFIG+="user.privileged: root\n"
DANTE_GLOBAL_CONFIG+="user.notprivileged: nobody\n"

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

    log_info "Настройка прокси $i (HTTP:$CURRENT_HTTP_PORT, SOCKS5:$CURRENT_SOCKS_PORT) с исходящим IPv6 $GENERATED_IPV6"

    # Создаем системного пользователя для аутентификации Dante
    useradd -M -s /usr/sbin/nologin "$PROXY_USERNAME" || log_error "Ошибка при создании пользователя $PROXY_USERNAME."
    echo "$PROXY_USERNAME:$PROXY_PASSWORD" | chpasswd || log_error "Ошибка при установке пароля для пользователя $PROXY_USERNAME."

    # Добавляем сгенерированный IPv6 адрес на интерфейс
    ip -6 addr add "${GENERATED_IPV6}/64" dev "$PRIMARY_INTERFACE" || log_error "Ошибка при добавлении IPv6 $GENERATED_IPV6 на $PRIMARY_INTERFACE."
    log_info "IPv6 ${GENERATED_IPV6}/64 добавлен на $PRIMARY_INTERFACE."

    # Добавляем конфигурацию для текущего прокси в общую переменную
    DANTE_GLOBAL_CONFIG+="\n# SOCKS5 Proxy ${i}\n"
    DANTE_GLOBAL_CONFIG+="internal: ${VDS_IPV4} port ${CURRENT_SOCKS_PORT}\n"
    DANTE_GLOBAL_CONFIG+="external: ${PRIMARY_INTERFACE}\n"
    DANTE_GLOBAL_CONFIG+="socksmethod: username\n"

    DANTE_GLOBAL_CONFIG+="client pass {
    \n"
    DANTE_GLOBAL_CONFIG+="    from: 0.0.0.0/0 to: 0.0.0.0/0\n"
    DANTE_GLOBAL_CONFIG+="    log: error connect disconnect\n"
    DANTE_GLOBAL_CONFIG+="}\n"
    DANTE_GLOBAL_CONFIG+="socks pass {\n"
    DANTE_GLOBAL_CONFIG+="    from: 0.0.0.0/0 to: 0.0.0.0/0\n"
    DANTE_GLOBAL_CONFIG+="    log: error connect disconnect\n"
    DANTE_GLOBAL_CONFIG+="    socksmethod: username\n"
    DANTE_GLOBAL_CONFIG+="    proxy-address: ${GENERATED_IPV6}\n"
    DANTE_GLOBAL_CONFIG+="}\n"
    
    DANTE_GLOBAL_CONFIG+="\n# HTTP Proxy ${i}\n"
    DANTE_GLOBAL_CONFIG+="internal: ${VDS_IPV4} port ${CURRENT_HTTP_PORT}\n"
    DANTE_GLOBAL_CONFIG+="external: ${PRIMARY_INTERFACE}\n"
    DANTE_GLOBAL_CONFIG+="clientmethod: username\n"

    DANTE_GLOBAL_CONFIG+="client pass {\n"
    DANTE_GLOBAL_CONFIG+="    from: 0.0.0.0/0 to: 0.0.0.0/0\n"
    DANTE_GLOBAL_CONFIG+="    log: error connect disconnect\n"
    DANTE_GLOBAL_CONFIG+="    proxy-address: ${GENERATED_IPV6}\n"
    DANTE_GLOBAL_CONFIG+="}\n"

    # Открываем порты в UFW
    ufw allow "${CURRENT_HTTP_PORT}/tcp" comment "Dante HTTP Proxy ${i}" || log_warn "Не удалось открыть HTTP порт ${CURRENT_HTTP_PORT} в UFW."
    ufw allow "${CURRENT_SOCKS_PORT}/tcp" comment "Dante SOCKS5 Proxy ${i}" || log_warn "Не удалось открыть SOCKS5 порт ${CURRENT_SOCKS_PORT} в UFW."

    log_info "Конфигурация для прокси $i собрана. Порты открыты в UFW."
    
    PROXY_INFO+=("--- Proxy ${i} ---
    IPv4 VDS: ${VDS_IPV4}
    HTTP Port: ${CURRENT_HTTP_PORT}
    SOCKS5 Port: ${CURRENT_SOCKS_PORT}
    Username: ${PROXY_USERNAME}
    Password: ${PROXY_PASSWORD}
    Outgoing IPv6: ${GENERATED_IPV6}")
done

# Записываем всю собранную конфигурацию в danted.conf
echo -e "$DANTE_GLOBAL_CONFIG" > "${DANTE_CONF_DIR}/danted.conf" || log_error "Ошибка при записи danted.conf."
log_info "Полный danted.conf создан."

log_info "Перезапуск службы Dante-server..."
systemctl daemon-reload
systemctl restart danted || log_error "Ошибка при перезапуске danted. Проверьте логи: journalctl -u danted."
systemctl enable danted || log_warn "Не удалось включить danted для автозапуска."
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
