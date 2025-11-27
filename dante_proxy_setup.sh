#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Configuration for Multi-Proxy Generation ---
PROXY_USERNAME="r4g3ng"
PROXY_PASSWORD="admin"
START_PORT=20000
END_PORT=21500
# -----------------------------------------------

# Function to URL-encode username and password
url_encode() {
    local raw="$1"
    local encoded=""
    for (( i=0; i<${#raw}; i++ )); do
        char="${raw:i:1}"
        case "$char" in
            [a-zA-Z0-9._~-]) encoded+="$char" ;;
            *) encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    echo "$encoded"
}

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен быть запущен с правами root. Используйте sudo.${NC}"
   exit 1
fi

echo -e "${CYAN}Начинается настройка ${END_PORT - START_PORT + 1} SOCKS5 прокси...${NC}"
echo -e "${YELLOW}Логин: ${PROXY_USERNAME}, Пароль: ${PROXY_PASSWORD}${NC}"
echo -e "${YELLOW}Диапазон портов: ${START_PORT} - ${END_PORT}${NC}"

# Check and install danted if not present
if ! command -v danted &> /dev/null; then
    echo -e "${YELLOW}Dante SOCKS5 сервер не установлен. Устанавливаем...${NC}"
    apt update -y
    apt install dante-server curl -y netfilter-persistent -y # Добавляем netfilter-persistent для сохранения iptables
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Ошибка: Не удалось установить dante-server. Проверьте подключение к интернету или репозитории.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Dante SOCKS5 сервер установлен успешно.${NC}"
else
    echo -e "${GREEN}Dante SOCKS5 сервер уже установлен.${NC}"
fi

# Create the log file before starting the service and clear any old logs
echo -e "${CYAN}Очистка и создание файла логов /var/log/danted.log...${NC}"
rm -f /var/log/danted.log # Удаляем старый лог, чтобы не путаться
touch /var/log/danted.log
chown nobody:nogroup /var/log/danted.log

# Automatically detect the primary network interface
primary_interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
if [[ -z "$primary_interface" ]]; then
    echo -e "${RED}Не удалось определить основной сетевой интерфейс. Пожалуйста, проверьте настройки сети.${NC}"
    exit 1
fi
echo -e "${CYAN}Обнаружен основной сетевой интерфейс: ${primary_interface}${NC}"

# Generate the internal port configuration lines
PORT_CONFIG=""
for p in $(seq "$START_PORT" "$END_PORT"); do
    PORT_CONFIG+="internal: 0.0.0.0 port = $p"$'\n'
done
# Calculate number of proxies for a cleaner message
NUM_PROXIES=$((END_PORT - START_PORT + 1))

# Create the configuration file with multiple ports
echo -e "${CYAN}Создание конфигурационного файла /etc/danted.conf с ${NUM_PROXIES} портами...${NC}"
cat <<EOF > /etc/danted.conf
logoutput: /var/log/danted.log
# Listening ports for SOCKS5 proxy
${PORT_CONFIG}external: $primary_interface
socksmethod: username # ИСПРАВЛЕНО: 'method' на 'socksmethod'
user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0/0 to: 0/0
    log: connect disconnect error
}
socks pass {
    from: 0/0 to: 0/0
    log: connect disconnect error
}
EOF
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка: Не удалось создать /etc/danted.conf.${NC}"
    exit 1
fi
echo -e "${GREEN}Конфигурационный файл danted.conf создан успешно. Проверьте его содержимое командой: cat /etc/danted.conf${NC}"

# Configure firewall rules for the port range
echo -e "${CYAN}Настройка правил брандмауэра для диапазона портов ${START_PORT}:${END_PORT}...${NC}"
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}UFW активен. Разрешаем диапазон портов ${START_PORT}:${END_PORT}/tcp...${NC}"
    ufw allow "$START_PORT:$END_PORT/tcp"
    ufw reload # Применяем изменения UFW
elif command -v iptables &> /dev/null; then
    echo -e "${YELLOW}UFW не активен. Настраиваем iptables для диапазона портов ${START_PORT}:${END_PORT}/tcp...${NC}"
    # Удаляем существующие правила для этого диапазона, чтобы избежать дублирования
    iptables -D INPUT -p tcp --dport "$START_PORT:$END_PORT" -j ACCEPT 2>/dev/null
    iptables -A INPUT -p tcp --dport "$START_PORT:$END_PORT" -j ACCEPT
    # Сохраняем правила iptables для постоянства
    if command -v netfilter-persistent &>/dev/null; then
        echo -e "${YELLOW}Сохраняем правила iptables с помощью netfilter-persistent...${NC}"
        netfilter-persistent save
    elif command -v iptables-save &>/dev/null; then
        echo -e "${YELLOW}Сохраняем правила iptables в /etc/iptables/rules.v4...${NC}"
        # Убедимся, что директория существует
        mkdir -p /etc/iptables/
        iptables-save > /etc/iptables/rules.v4
    else
        echo -e "${RED}Предупреждение: Не удалось найти способ сохранить правила iptables. Они могут не сохраниться после перезагрузки.${NC}"
    fi
else
    echo -e "${RED}Предупреждение: Ни UFW, ни iptables не найдены или не настроены. Пожалуйста, вручную откройте порты ${START_PORT}:${END_PORT} в вашем брандмауэре.${NC}"
fi
echo -e "${GREEN}Правила брандмауэра настроены.${NC}"

# Add or update user for SOCKS5 proxy
echo -e "${CYAN}Создание/обновление пользователя '${PROXY_USERNAME}'...${NC}"
if ! id "$PROXY_USERNAME" &>/dev/null; then
    useradd --shell /usr/sbin/nologin "$PROXY_USERNAME"
    echo -e "${GREEN}Пользователь @$PROXY_USERNAME создан успешно.${NC}"
else
    echo -e "${YELLOW}Пользователь @$PROXY_USERNAME уже существует. Обновляем пароль.${NC}"
fi
echo "$PROXY_USERNAME:$PROXY_PASSWORD" | chpasswd
echo -e "${GREEN}Пароль установлен/обновлен для пользователя: ${PROXY_USERNAME}.${NC}"

# Create systemd override file for danted to set nofile limit and ReadWriteDirectories
echo -e "${CYAN}Создание файла переопределения Systemd для danted.service (LimitNOFILE и ReadWriteDirectories)...${NC}"
OVERRIDE_DIR="/etc/systemd/system/danted.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

mkdir -p "$OVERRIDE_DIR"

# Устанавливаем очень высокий лимит, чтобы гарантированно избежать "Too many open files"
NOFILE_LIMIT=8192 

cat <<EOF > "$OVERRIDE_FILE"
[Service]
LimitNOFILE=${NOFILE_LIMIT}
ReadWriteDirectories=/var/log
EOF

echo -e "${GREEN}Файл переопределения Systemd создан: ${OVERRIDE_FILE}${NC}"
echo -e "${GREEN}  - Установлен LimitNOFILE=${NOFILE_LIMIT} (максимально возможное количество открытых файлов)${NC}"
echo -e "${GREEN}  - Добавлена ReadWriteDirectories=/var/log для разрешения записи логов.${NC}"

# Reload the systemd daemon and restart the service
echo -e "${CYAN}Перезагрузка демона systemd и перезапуск службы danted...${NC}"
systemctl daemon-reload
systemctl restart danted
systemctl enable danted

# Check if the service is active
if systemctl is-active --quiet danted; then
    echo -e "${GREEN}\nSocks5 серверы были успешно настроены и запущены на портах ${START_PORT} - ${END_PORT}.${NC}"
    echo -e "${CYAN}Для проверки статуса службы: systemctl status danted${NC}"
    echo -e "${CYAN}Для проверки лимитов открытых файлов для процесса danted: cat /proc/$(systemctl show --value -p MainPID danted 2>/dev/null)/limits | grep 'Max open files'${NC}"
else
    echo -e "${RED}\nНе удалось запустить Socks5 сервер. Проверьте логи для получения дополнительной информации: tail -n 50 /var/log/danted.log${NC}"
    echo -e "${RED}  Или полный статус: systemctl status danted${NC}"
    echo -e "${YELLOW}  Возможные причины: конфликт портов, неверный IP-адрес интерфейса, или лимит 'nofile' всё ещё недостаточен.${NC}"
    exit 1
fi

# Output the list of proxies
proxy_ip=$(hostname -I | awk '{print $1}' | head -n 1)
encoded_username=$(url_encode "$PROXY_USERNAME")
encoded_password=$(url_encode "$PROXY_PASSWORD")

echo -e "${CYAN}\nСписок всех SOCKS5 прокси:${NC}"
echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
for p in $(seq "$START_PORT" "$END_PORT"); do
    echo "socks5://${encoded_username}:${encoded_password}@${proxy_ip}:${p}"
done
echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
echo -e "${GREEN}Конфигурация завершена!${NC}"
