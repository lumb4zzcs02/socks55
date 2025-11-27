#!/bin/bash

# --- НАСТРОЙКИ СКРИПТА ---
DANTE_CONF_DIR="/etc/dante/proxies"          # Директория для хранения конфигов отдельных прокси
DANTE_LOG_DIR="/var/log/dante"               # Директория для логов отдельных прокси
PROXY_DETAILS_FILE="/root/socks5_proxies_details.txt" # Файл для сохранения деталей прокси
DEFAULT_USER_PREFIX="proxyuser"
DEFAULT_PASSWORD_LENGTH=16
START_PORT=20000                             # Начальный порт для прокси
GENERATED_IPV6_LIST_FILE="/var/lib/dante/generated_ipv6_addresses.txt" # Файл для отслеживания сгенерированных IPv6

# --- Проверка прав суперпользователя ---
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени пользователя root."
   exit 1
fi

echo "--- Инициализация: Обновление системы и установка необходимых пакетов ---"
# Обновление списка пакетов и системы
apt update && apt upgrade -y || { echo "Ошибка при обновлении системы. Проверьте подключение или репозитории."; exit 1; }

# Установка dante-server, apache2-utils (для htpasswd, хотя здесь не используется, но было в примере), ufw, qrencode
# qrencode и curl используются для вывода QR-кода/ссылок в конце, если они вам нужны.
apt install -y dante-server apache2-utils ufw qrencode curl || { echo "Ошибка при установке необходимых пакетов."; exit 1; }

# --- Настройка UFW ---
echo -e "\n--- Настройка UFW (брандмауэра) ---"
if ! ufw status | grep -q "Status: active"; then
    echo "UFW не активен. Включаем UFW и разрешаем SSH (порт 22)."
    ufw enable <<< "y" # Автоматическое подтверждение
    ufw allow 22/tcp || { echo "Ошибка при разрешении порта 22 в UFW."; exit 1; }
    # Разрешаем UFW для loopback
    ufw allow in on lo
    ufw allow out on lo
    ufw reload || { echo "Ошибка при перезагрузке UFW."; exit 1; }
else
    echo "UFW уже активен. Разрешаем SSH (порт 22), если еще не разрешен."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
fi
echo "UFW настроен. Порты для прокси будут открыты автоматически."


# --- Определение сетевого интерфейса и IP-адресов ---
echo -e "\n--- Определение сетевого интерфейса и IP-адресов ---"
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -n 1)
if [ -z "$INTERFACE" ]; then
    echo "Ошибка: Не удалось автоматически определить сетевой интерфейс."
    echo "Попробуйте указать его вручную, например: export INTERFACE=eth0"
    exit 1
fi
echo "Определён сетевой интерфейс: $INTERFACE"
IPV4_ADDRESS=$(ip a show dev "$INTERFACE" | grep 'inet ' | grep 'global' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
if [ -z "$IPV4_ADDRESS" ]; then
    echo "Ошибка: Не удалось определить публичный IPv4-адрес для интерфейса $INTERFACE."
    echo "Проверьте сетевые настройки или наличие IPv4-адреса на интерфейсе."
    exit 1
fi
echo "Определён публичный IPv4-адрес для интерфейса $INTERFACE: $IPV4_ADDRESS"

# Поиск всех подсетей IPv6 /64 на интерфейсе
IPV6_SUBNEYS=()
mapfile -t IPV6_SUBNEYS < <(ip -6 addr show dev "$INTERFACE" | grep 'inet6 ' | grep '/64' | awk '{print $2}')

if [ ${#IPV6_SUBNEYS[@]} -eq 0 ]; then
    echo "Ошибка: На интерфейсе $INTERFACE не найдено IPv6-подсетей /64."
    echo "Проверьте конфигурацию IPv6 вашего VDS. Без /64 подсети невозможно создать исходящий IPv6-адрес."
    exit 1
fi

# Выбираем одну случайную подсеть IPv6 /64
SELECTED_IPV6_PREFIX="${IPV6_SUBNEYS[$RANDOM % ${#IPV6_SUBNEYS[@]}]}"
# Удаляем /64 из префикса для генерации адреса
SELECTED_IPV6_BASE_PREFIX="${SELECTED_IPV6_PREFIX%/*}" # Удаляем /64
SELECTED_IPV6_BASE_PREFIX="${SELECTED_IPV6_BASE_PREFIX%::*}::" # Убедимся, что заканчивается на ::
echo "Выбрана IPv6-подсеть для исходящих соединений: $SELECTED_IPV6_PREFIX"

# --- Функции ---

# Функция для генерации случайного IPv6-адреса (правильная версия)
function generate_random_ipv6() {
    local base_prefix="$1"
    # Генерируем 64 бита случайных шестнадцатеричных цифр для Host ID
    local random_host_id=$(head /dev/urandom | tr -dc a-f0-9 | head -c 16)
    echo "${base_prefix}${random_host_id}"
}

# Функция для генерации уникального порта (последовательно)
current_port=$START_PORT
function get_next_available_port() {
    while true; do
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$current_port"; then
            echo "$current_port"
            current_port=$((current_port + 1))
            return
        fi
        current_port=$((current_port + 1))
        if [ "$current_port" -gt 65535 ]; then
            echo "Ошибка: Достигнут максимальный порт (65535). Невозможно выделить новый порт." >&2
            exit 1
        fi
    done
}

# --- Подготовка директорий и файлов ---
echo -e "\n--- Подготовка директорий ---"
mkdir -p "$DANTE_CONF_DIR" || { echo "Ошибка: Не удалось создать $DANTE_CONF_DIR."; exit 1; }
mkdir -p "$DANTE_LOG_DIR" || { echo "Ошибка: Не удалось создать $DANTE_LOG_DIR."; exit 1; }
mkdir -p "$(dirname "$GENERATED_IPV6_LIST_FILE")" || { echo "Ошибка: Не удалось создать директорию для $GENERATED_IPV6_LIST_FILE."; exit 1; }
touch "$GENERATED_IPV6_LIST_FILE" || { echo "Ошибка: Не удалось создать $GENERATED_IPV6_LIST_FILE."; exit 1; }
chmod 700 "$DANTE_CONF_DIR" "$DANTE_LOG_DIR"
chown root:root "$DANTE_CONF_DIR" "$DANTE_LOG_DIR"

echo "=============================================================" > "$PROXY_DETAILS_FILE"
echo "Детали созданных SOCKS5 прокси (IPv4 вход, IPv6 выход):" >> "$PROXY_DETAILS_FILE"
echo "=============================================================" >> "$PROXY_DETAILS_FILE"
chmod 600 "$PROXY_DETAILS_FILE" # Защищаем файл с данными

# --- Спрашиваем у пользователя количество прокси ---
num_proxies=0
while true; do
    read -p "Сколько SOCKS5 прокси вы хотите создать? (Введите число > 0): " input_num
    if [[ "$input_num" =~ ^[1-9][0-9]*$ ]]; then
        num_proxies=$input_num
        break
    else
        echo "Некорректный ввод. Пожалуйста, введите число больше 0."
    fi
done

# --- Цикл создания прокси ---
echo -e "\n--- Запуск создания прокси ---"
for i in $(seq 1 "$num_proxies"); do
    echo -e "\nНастройка прокси #$i из $num_proxies..."

    # 1. Генерация данных
    local_username="${DEFAULT_USER_PREFIX}$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    local_password=$(tr -dc 'a-zA-Z0-9!@#$%^&*()_+' </dev/urandom | head -c $DEFAULT_PASSWORD_LENGTH)
    local_port=$(get_next_available_port)
    # Генерируем уникальный IPv6-адрес для исходящих соединений
    generated_ipv6=$(generate_random_ipv6 "$SELECTED_IPV6_BASE_PREFIX")

    echo "  Данные для прокси #$i:"
    echo "    Логин: $local_username"
    echo "    Пароль: $local_password"
    echo "    Порт: $local_port (IPv4 входящий)"
    echo "    Исходящий IPv6: $generated_ipv6"

    # 2. Добавляем сгенерированный IPv6 на интерфейс
    echo "  Добавляем исходящий IPv6-адрес $generated_ipv6/64 на интерфейс $INTERFACE..."
    if ! ip -6 addr add "$generated_ipv6/64" dev "$INTERFACE"; then
        echo "Ошибка: Не удалось добавить IPv6-адрес $generated_ipv6 на интерфейс $INTERFACE."
        echo "Прокси #$i будет пропущен."
        continue
    fi
    echo "$generated_ipv6" >> "$GENERATED_IPV6_LIST_FILE" # Сохраняем для отслеживания

    # 3. Создаём системного пользователя для аутентификации
    # `-r` создает системного пользователя, `-s /bin/false` запрещает ему логиниться
    echo "  Создаём системного пользователя '$local_username'..."
    useradd -r -s /bin/false "$local_username" >/dev/null 2>&1
    echo "$local_username:$local_password" | chpasswd >/dev/null 2>&1

    # 4. Создаём конфигурационный файл для dante-server инстанса
    DANTE_INSTANCE_CONF="$DANTE_CONF_DIR/danted-proxy-$i.conf"
    DANTE_INSTANCE_LOG="$DANTE_LOG_DIR/danted-proxy-$i.log"
    DANTE_INSTANCE_PID="/run/danted-proxy-$i.pid" # PID-файл для каждого инстанса

    cat > "$DANTE_INSTANCE_CONF" <<EOL
logoutput: stderr $DANTE_INSTANCE_LOG
internal: 0.0.0.0 port = $local_port
external: $generated_ipv6
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error
}

socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        method: username
        protocol: tcp udp
        log: error
}
EOL
    chmod 640 "$DANTE_INSTANCE_CONF"
    chown root:root "$DANTE_INSTANCE_CONF"

    # 5. Создаём systemd unit файл для автозагрузки каждого прокси
    SYSTEMD_SERVICE_FILE="/etc/systemd/system/danted-proxy-$i.service"
    cat > "$SYSTEMD_SERVICE_FILE" <<EOL
[Unit]
Description=SOCKS (dante) proxy instance #$i (IPv4-in, IPv6-out)
After=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/danted -f $DANTE_INSTANCE_CONF -p $DANTE_INSTANCE_PID
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=$DANTE_INSTANCE_PID
LimitNOFILE=32768
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    chmod 644 "$SYSTEMD_SERVICE_FILE"

    # 6. Открываем порт в брандмауэре
    echo "  Открываем порт $local_port/tcp в UFW..."
    ufw allow "$local_port"/tcp > /dev/null

    # 7. Перезагружаем systemd, включаем и запускаем новый сервис
    echo "  Перезагружаем systemd и запускаем danted-proxy-$i..."
    systemctl daemon-reload
    systemctl enable danted-proxy-"$i" > /dev/null
    systemctl start danted-proxy-"$i"

    if systemctl is-active --quiet danted-proxy-"$i"; then
        echo "  Прокси #$i (danted-proxy-$i) успешно запущен."
    else
        echo "  Ошибка: Прокси #$i (danted-proxy-$i) не удалось запустить. Проверьте логи: journalctl -u danted-proxy-$i"
        # Попытка удалить добавленный IPv6, если сервис не запустился
        echo "  Попытка удалить неиспользуемый IPv6 $generated_ipv6 с интерфейса $INTERFACE."
        ip -6 addr del "$generated_ipv6/64" dev "$INTERFACE" >/dev/null 2>&1
        sed -i "/^$generated_ipv6$/d" "$GENERATED_IPV6_LIST_FILE"
    fi

    # Выводим информацию и сохраняем в файл
    echo "============================================================="
    echo "SOCKS5-прокси #$i установлен и запущен."
    echo "Входящий IP: $IPV4_ADDRESS"
    echo "Порт: $local_port"
    echo "Логин: $local_username"
    echo "Пароль: $local_password"
    echo "Исходящий IPv6: $generated_ipv6"
    echo "============================================================="
    echo "Готовая строка для антидетект браузеров:"
    echo "$IPV4_ADDRESS:$local_port:$local_username:$local_password"
    echo "или $local_username:$local_password@$IPV4_ADDRESS:$local_port"
    echo "============================================================="

    echo "Прокси #$i:" >> "$PROXY_DETAILS_FILE"
    echo "Входящий IP: $IPV4_ADDRESS" >> "$PROXY_DETAILS_FILE"
    echo "Порт: $local_port" >> "$PROXY_DETAILS_FILE"
    echo "Логин: $local_username" >> "$PROXY_DETAILS_FILE"
    echo "Пароль: $local_password" >> "$PROXY_DETAILS_FILE"
    echo "Исходящий IPv6: $generated_ipv6" >> "$PROXY_DETAILS_FILE"
    echo "Строка (для антидетект): $local_username:$local_password@$IPV4_ADDRESS:$local_port" >> "$PROXY_DETAILS_FILE"
    echo "Сервис Systemd: danted-proxy-$i" >> "$PROXY_DETAILS_FILE"
    echo "-------------------------------------------------------------" >> "$PROXY_DETAILS_FILE"
done

# --- Финальные сообщения ---
echo -e "\n============================================================="
echo "Все $num_proxies SOCKS5-прокси успешно настроены и запущены."
echo "Детали всех прокси сохранены в файле: $PROXY_DETAILS_FILE"
echo "Список сгенерированных IPv6-адресов: $GENERATED_IPV6_LIST_FILE"
echo "Прокси будут автоматически запускаться при старте сервера."
echo "Проверьте добавленные IPv6-адреса командой: ip -6 addr show dev $INTERFACE"
echo "============================================================="

echo "Спасибо за использование скрипта! Вы можете оставить чаевые по QR-коду ниже:"
qrencode -t ANSIUTF8 "https://pay.cloudtips.ru/p/7410814f"
echo "Ссылка на чаевые: https://pay.cloudtips.ru/p/7410814f"
echo "============================================================="
echo "Рекомендуемые хостинги для VPN и прокси:"
echo "Хостинг #1: https://vk.cc/ct29NQ (промокод off60 для 60% скидки на первый месяц)"
echo "Хостинг #2: https://vk.cc/czDwwy (будет действовать 15% бонус в течение 24 часов!)"
echo "============================================================="
