#!/bin/bash

# ANSI цвета и стили
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Функция для отображения шапки
show_header() {
    clear # Очистка экрана
    echo -e "${RED}"
    echo "███╗   ██╗██████╗ ██████╗ ██████╗ ████████╗███████╗ █████╗ ███╗   ███╗"
    echo "████╗  ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██╔══██╗████╗ ████║"
    echo "██╔██╗ ██║██████╔╝██████╔╝██████╔╝   ██║   █████╗  ███████║██╔████╔██║"
    echo "██║╚██╗██║██╔═══╝ ██╔═══╝ ██╔══██╗   ██║   ██╔══╝  ██╔══██║██║╚██╔╝██║"
    echo "██║ ╚████║██║     ██║     ██║  ██║   ██║   ███████╗██║  ██║██║ ╚═╝ ██║"
    echo "╚═╝  ╚═══╝╚═╝     ╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝"
    echo -e "${NC}"
    echo -e "${GREEN}------------------------------------------------"
    echo "Наши контакты:"
    echo "Наш ТГ — https://t.me/nppr_team"
    echo "Наш ВК — https://vk.com/npprteam"
    echo "ТГ нашего магазина — https://t.me/npprteamshop"
    echo "Магазин аккаунтов, бизнес-менеджеров ФБ и Google — https://npprteam.shop"
    echo "Наш антидетект-браузер Antik Browser — https://antik-browser.com/"
    echo -e "------------------------------------------------${NC}"
}

# Вызов функции для отображения шапки
show_header

show_infinite_progress_bar() {
    local i=0
    local sp='/-\|'
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local NC='\033[0m' # No Color

    # Сообщение о текущей операции
    local current_operation="Устанавливаем скрипт"

    # Вывод сообщения с цветом
    echo -ne "${GREEN}${current_operation}... ${NC}"

    while true; do
        # Вывод символов прогресс бара с цветом
        echo -ne "${RED}${sp:i++%${#sp}:1} ${NC}\b\b"
        sleep 0.2
    done
}

show_final_message() {
    local download_link=$1
    local password=$2
    local local_path=$3

    # ANSI цвета и стили
    local GREEN='\033[0;32m'
    local NC='\033[0m' # No Color

    # Верхняя рамка
    echo -e "${GREEN}##################################################${NC}"
    # Тело сообщения
    echo -e "${GREEN}# Ваша ссылка на скачивание архива с прокси - ${download_link}${NC}"
    echo -e "${GREEN}# Пароль к архиву - ${password}${NC}"
    echo -e "${GREEN}# Файл с прокси можно найти по адресу - ${local_path}${NC}"
    echo -e "${GREEN}# Всегда ваш NPPRTEAM!${NC}"
    echo -e "${GREEN}# Наши контакты:${NC}"
    echo -e "${GREEN}# Наш ТГ — https://t.me/nppr_team${NC}"
    echo -e "${GREEN}# Наш ВК — https://vk.com/npprteam${NC}"
    echo -e "${GREEN}# ТГ нашего магазина — https://t.me/npprteamshop${NC}"
    echo -e "${GREEN}# Магазин аккаунтов, бизнес-менеджеров ФБ и Google — https://npprteam.shop${NC}"
    echo -e "${GREEN}# Наш антидетект-браузер Antik Browser — https://antik-browser.com/${NC}"
    # Нижняя рамка
    echo -e "${GREEN}##################################################${NC}"
}

# Запускаем прогресс бар для длительных операций
start_progress_bar() {
    show_infinite_progress_bar &
    progress_bar_pid=$!
}

# Останавливаем прогресс бар после завершения операций
stop_progress_bar() {
    kill $progress_bar_pid
    wait $progress_bar_pid 2>/dev/null
}

# Void

# Массив для генерации частей IPv6 адреса
array=(0 1 2 3 4 5 6 7 8 9 a b c d e f)

# Получение основного интерфейса для IPv4 (можно использовать и для IPv6)
main_interface=$(ip route get 8.8.8.8 | awk -- '{printf $5}')

# Функция для генерации случайной строки
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Генерация случайного сегмента
gen_segment() {
    echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
}

# Генераторы для различных подсетей
gen32() { echo "$1:$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment)"; }
gen48() { echo "$1:$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment)"; }
gen56() { echo "$1:$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment)"; }
gen64() { echo "$1:$(gen_segment):$(gen_segment):$(gen_segment):$(gen_segment)"; }

# Функция для выбора нужного генератора в зависимости от размера подсети
generate_ipv6() {
    local prefix=$1
    local subnet_size=$2

    case $subnet_size in
        32) ipv6_generated=$(gen32 $prefix) ;;
        48) ipv6_generated=$(gen48 $prefix) ;;
        56) ipv6_generated=$(gen56 $prefix) ;;
        64) ipv6_generated=$(gen64 $prefix) ;;
        *)
            echo "Ошибка: неподдерживаемый размер подсети $subnet_size"
            return 1
            ;;
    esac

    echo $ipv6_generated
}

# Автоопределение информации IPv6
auto_detect_ipv6_info() {
    local main_interface=$(ip -6 route show default | awk '{print $5}' | head -n1)
    local ipv6_address=$(ip -6 addr show dev "$main_interface" | grep 'inet6' | awk '{print $2}' | head -n1)
    local ipv6_prefix=$(echo "$ipv6_address" | sed -e 's/\/.*//g' | awk -F ':' '{print $1":"$2":"$3":"$4}')
    local ipv6_subnet_size=$(echo "$ipv6_address" | grep -oP '\/\K\d+')

    if [ -z "$ipv6_address" ] || [ -z "$ipv6_subnet_size" ]; then
        echo "Не удалось определить адрес или размер подсети для интерфейса $main_interface."
        return 1
    fi

    echo "$ipv6_prefix $ipv6_subnet_size"
}

# Генерация адреса
ipv6_info=$(auto_detect_ipv6_info)
if [ $? -eq 0 ]; then
    read ipv6_prefix ipv6_subnet_size <<< "$ipv6_info"
    ipv6_generated=$(generate_ipv6 $ipv6_prefix $ipv6_subnet_size)
    if [ $? -eq 0 ]; then
        echo "Сгенерированный IPv6 адрес: $ipv6_generated"
    else
        echo "Ошибка при генерации IPv6 адреса."
        return 1
    fi
else
    echo "Ошибка при определении информации IPv6."
    return 1
fi

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
    if [[ $TYPE -eq 1 ]]
        then
          echo "$USERNAME/$PASSWORD/$IP4/$port/$(gen64 $IP6)"
        else
          echo "$USERNAME/$PASSWORD/$IP4/$FIRST_PORT/$(gen64 $IP6)"
        fi    
    done
}

gen_data_multiuser() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        if [[ $TYPE -eq 1 ]]
        then
          echo "$(random)/$(random)/$IP4/$port/$(gen64 $IP6)"
        else
          echo "$(random)/$(random)/$IP4/$FIRST_PORT/$(gen64 $IP6)"
        fi    
    done
}

install_3proxy() {
    echo "Устанавливаем прокси"
    mkdir -p /3proxy
    cd /3proxy
    #URL="https://github.com/z3APA3A/3proxy/archive/0.9.3.tar.gz"
    URL="https://raw.githubusercontent.com/mrtoan2808/3proxy-ipv6/master/3proxy-0.9.3.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.3
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    mv /3proxy/3proxy-0.9.3/bin/3proxy /usr/local/etc/3proxy/bin/
    wget https://raw.githubusercontent.com/mrtoan2808/3proxy-ipv6/master/3proxy.service-Centos8 --output-document=/3proxy/3proxy-0.9.3/scripts/3proxy.service2
    cp /3proxy/3proxy-0.9.3/scripts/3proxy.service2 /usr/lib/systemd/system/3proxy.service
    systemctl link /usr/lib/systemd/system/3proxy.service
    systemctl daemon-reload
    #systemctl enable 3proxy
    echo "* hard nofile 999999" >>  /etc/security/limits.conf -y > /dev/null 2>&1
    echo "* soft nofile 999999" >>  /etc/security/limits.conf -y > /dev/null 2>&1
    echo "net.ipv4.route.min_adv_mss = 1460" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.tcp_rmem = 8192 87380 4194304" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.tcp_wmem = 8192 87380 4194304" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.tcp_timestamps=0" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.tcp_window_scaling=0" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.icmp_echo_ignore_all = 1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.tcp_max_syn_backlog = 4096" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.conf.all.forwarding=1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.ip_nonlocal_bind = 1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv6.conf.all.proxy_ndp=1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv6.ip_nonlocal_bind = 1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    
    # ===== ОПТИМИЗАЦИЯ MTU И РАНДОМИЗАЦИЯ =====
    echo "net.ipv6.conf.all.mtu = 1280" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv6.conf.default.mtu = 1280" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.ip_local_port_range = 10000 65000" >> /etc/sysctl.conf -y > /dev/null 2>&1
    echo "net.ipv4.tcp_tw_reuse = 1" >> /etc/sysctl.conf -y > /dev/null 2>&1
    
    sysctl -p
    systemctl stop firewalld
    systemctl disable firewalld

    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF
daemon
nserver 127.0.0.1
nserver ::1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
nolog
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

# HTTP proxy part
$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -64 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' ${WORKDATA})

# SOCKS5 proxy part
$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"socks -64 -n -a -p" $4+20000 " -i" $3 " -e" $5 "\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_iptables() {
    cat <<EOF
    $(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT\n" \
                    "iptables -I INPUT -p udp --dport " $4 "  -m state --state NEW -j ACCEPT\n" \
                    "iptables -I INPUT -p tcp --dport " $4+20000 "  -m state --state NEW -j ACCEPT\n" \
                    "iptables -I INPUT -p udp --dport " $4+20000 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
    $(awk -F "/" '{print "ifconfig '$main_interface' inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
Наши контакты: 
===========================================================================
Наш ТГ — https://t.me/nppr_team
Наш ВК — https://vk.com/npprteam
ТГ нашего магазина — https://t.me/npprteamshop
Магазин аккаунтов, бизнес-менеджеров ФБ и Google— https://npprteam.shop
Наш антидетект-браузер Antik Browser — https://antik-browser.com/
===========================================================================
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

upload_proxy() {
    cd $WORKDIR
    local PASS=$(random)
    
    # Создаем запароленный архив
    zip --password $PASS proxy.zip proxy.txt > /dev/null 2>&1
    
    # Создаем директорию для хранения прокси (если не существует)
    PROXY_DIR="/root/proxy_exports"
    mkdir -p $PROXY_DIR
    
    # Генерируем уникальное имя файла с датой
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    FINAL_NAME="proxy_${TIMESTAMP}.zip"
    
    # Копируем архив в директорию
    cp proxy.zip "$PROXY_DIR/$FINAL_NAME"
    cp proxy.txt "$PROXY_DIR/proxy_${TIMESTAMP}.txt"
    
    # Устанавливаем права только для root
    chmod 600 "$PROXY_DIR/$FINAL_NAME"
    chmod 600 "$PROXY_DIR/proxy_${TIMESTAMP}.txt"
    
    # Показываем финальное сообщение
    echo -e "${GREEN}##################################################${NC}"
    echo -e "${GREEN}# ✅ Прокси успешно созданы!${NC}"
    echo -e "${GREEN}##################################################${NC}"
    echo -e "${GREEN}# 📁 Архив с прокси: ${PROXY_DIR}/${FINAL_NAME}${NC}"
    echo -e "${GREEN}# 📄 Текстовый файл: ${PROXY_DIR}/proxy_${TIMESTAMP}.txt${NC}"
    echo -e "${GREEN}# 🔑 Пароль к архиву: ${PASS}${NC}"
    echo -e "${GREEN}##################################################${NC}"
    echo -e "${GREEN}# Скачайте файлы с сервера через SCP/SFTP:${NC}"
    echo -e "${GREEN}# scp root@YOUR_SERVER_IP:${PROXY_DIR}/${FINAL_NAME} .${NC}"
    echo -e "${GREEN}##################################################${NC}"
    echo -e "${GREEN}# Всегда ваш NPPRTEAM!${NC}"
    echo -e "${GREEN}# Наш ТГ — https://t.me/nppr_team${NC}"
    echo -e "${GREEN}##################################################${NC}"
}

# Begin
echo "Добро пожаловать в установку прокси от NPPRTEAM"
echo "Установка нужных приложений"
# Обновляем систему
show_header
start_progress_bar
sudo apt update -y > /dev/null 2>&1
stop_progress_bar

# Устанавливаем необходимые инструменты
show_header
start_progress_bar
sudo apt install gcc make wget nano tar gzip -y > /dev/null 2>&1
stop_progress_bar

# Устанавливаем jq
show_header
start_progress_bar
sudo apt install epel-release -y > /dev/null 2>&1
stop_progress_bar
show_header
start_progress_bar
sudo apt update -y > /dev/null 2>&1
stop_progress_bar
show_header
start_progress_bar
sudo apt install jq -y > /dev/null 2>&1
stop_progress_bar

# Переустанавливаем инструменты для разработки
show_header
start_progress_bar
sudo apt group reinstall "Development Tools" -y > /dev/null 2>&1
stop_progress_bar

# Обновляем систему до последних версий пакетов
show_header
start_progress_bar
sudo apt upgrade -y > /dev/null 2>&1
stop_progress_bar

# Устанавливаем dnsmasq
show_header
start_progress_bar
sudo apt install -y dnsmasq > /dev/null 2>&1
stop_progress_bar

# Настраиваем dnsmasq для прослушивания локального адреса
echo "listen-address=127.0.0.1,::1" | sudo tee -a /etc/dnsmasq.conf

# Включаем и запускаем dnsmasq
sudo systemctl enable dnsmasq
sudo systemctl start dnsmasq

# ===== ЗАЩИТА ОТ DNS УТЕЧЕК И WEBRTC =====
# Блокируем DNS запросы напрямую (только через dnsmasq)
iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner root -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m owner --uid-owner root -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j DROP
iptables -A OUTPUT -p tcp --dport 53 -j DROP

# Блокируем WebRTC STUN/TURN утечки
iptables -A OUTPUT -p udp --dport 3478 -j DROP
iptables -A OUTPUT -p udp --dport 19302 -j DROP

# Дополнительная защита IPv6
ip6tables -A OUTPUT -p udp --dport 53 -j DROP
ip6tables -A OUTPUT -p tcp --dport 53 -j DROP

show_header
start_progress_bar
apt -y install gcc net-tools bsdtar zip make > /dev/null 2>&1
stop_progress_bar

show_header
start_progress_bar
install_3proxy > /dev/null 2>&1
stop_progress_bar

echo "Рабочая папка = /home/proxy-installer"
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir $WORKDIR && cd $_

USERNAME=$(random)
PASSWORD=$(random)
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

show_header
echo "Internal ip = ${IP4}. Exteranl sub for ip6 = ${IP6}"

show_header
echo "Сколько прокси вы хотите создать? Пример 500"
read COUNT
echo "Вы установили количество " $COUNT " proxy"

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT))

# Функция для настройки TCP/IP отпечатка
set_tcp_fingerprint() {
    local os=$1
	{
    echo "Применяем настройки для $os" 
    case "$os" in
        "Windows")
            # Windows 10/11 - более точная имитация
            sysctl -w net.ipv4.ip_default_ttl=128
            sysctl -w net.ipv4.tcp_syn_retries=2
            sysctl -w net.ipv4.tcp_fin_timeout=30
            sysctl -w net.ipv4.tcp_keepalive_time=7200
            sysctl -w net.ipv4.tcp_window_scaling=1
            sysctl -w net.ipv4.tcp_timestamps=1
            sysctl -w net.ipv4.tcp_sack=1
            sysctl -w net.core.rmem_max=16777216
            sysctl -w net.core.wmem_max=16777216
            ;;
        "MacOS")
            # MacOS - современные версии
            sysctl -w net.ipv4.ip_default_ttl=64
            sysctl -w net.ipv4.tcp_syn_retries=3
            sysctl -w net.ipv4.tcp_fin_timeout=15
            sysctl -w net.ipv4.tcp_keepalive_time=7200
            sysctl -w net.ipv4.tcp_window_scaling=1
            sysctl -w net.ipv4.tcp_timestamps=1
            sysctl -w net.ipv4.tcp_sack=1
            ;;
        "Linux")
            # Linux - default настройки
            sysctl -w net.ipv4.ip_default_ttl=64
            sysctl -w net.ipv4.tcp_syn_retries=5
            sysctl -w net.ipv4.tcp_fin_timeout=60
            sysctl -w net.ipv4.tcp_keepalive_time=7200
            sysctl -w net.ipv4.tcp_window_scaling=1
            sysctl -w net.ipv4.tcp_timestamps=1
            ;;
        "Android")
            # Android - современные версии
            sysctl -w net.ipv4.ip_default_ttl=64
            sysctl -w net.ipv4.tcp_syn_retries=4
            sysctl -w net.ipv4.tcp_fin_timeout=30
            sysctl -w net.ipv4.tcp_keepalive_time=300
            sysctl -w net.ipv4.tcp_window_scaling=1
            sysctl -w net.ipv4.tcp_timestamps=1
            ;;
        "iPhone")
            # iOS - современные версии
            sysctl -w net.ipv4.ip_default_ttl=64
            sysctl -w net.ipv4.tcp_syn_retries=3
            sysctl -w net.ipv4.tcp_fin_timeout=30
            sysctl -w net.ipv4.tcp_keepalive_time=7200
            sysctl -w net.ipv4.tcp_window_scaling=1
            sysctl -w net.ipv4.tcp_timestamps=1
            sysctl -w net.ipv4.tcp_sack=1
            ;;
        *)
            echo "Неизвестная операционная система: $os"
            return 1
            ;;
    esac > /dev/null 2>&1
    # Применяем изменения
    sysctl -p
    echo "Настройки для "$os" были применены."
	} > /dev/null 2>&1
    return 0
}

# Меню выбора
echo "Выберите TCP/IP Отпечаток для ваших прокси:"
echo "1 - Windows"
echo "2 - MacOS"
echo "3 - Linux"
echo "4 - Android"
echo "5 - iPhone"

read -p "Введите номер (1-5): " os_choice

# Убедитесь, что ввод пользователя - это числа от 1 до 5
if [[ ! $os_choice =~ ^[1-5]$ ]]; then
    echo "Неправильный выбор. Пожалуйста, введите номер от 1 до 5."
    exit 1
fi

# Переводим выбор в название операционной системы
os=""
case $os_choice in
    1) os="Windows" ;;
    2) os="MacOS" ;;
    3) os="Linux" ;;
    4) os="Android" ;;
    5) os="iPhone" ;;
esac

# Вызов функции с выбранным типом ОС
echo "Выбранная операционная система: $os"
set_tcp_fingerprint "$os"

echo "Какие прокси вы хотите создать?"
echo "1 - Статические"
echo "2 - С ротацией"
read TYPE
if [[ $TYPE -eq 1 ]]
then
show_header
  echo "Вы выбрали статические прокси"
else
show_header
  echo "Вы выбрали прокси с ротацией"
fi

echo "Вы хотите создать однин логин и пароль для всех прокси, или разные?"
echo "1 - Один"
echo "2 - Разные"
read NUSER
if [[ NUSER -eq 1 ]]
then
show_header
start_progress_bar
  echo "Вы выбрали один логин и пароль для всех прокси"
  gen_data >$WORKDIR/data.txt
  stop_progress_bar
else
show_header
start_progress_bar
  echo "Вы выбрали разные данные для прокси"
  gen_data_multiuser >$WORKDIR/data.txt
  stop_progress_bar
fi

gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
echo NM_CONTROLLED="no" >> /etc/sysconfig/network-scripts/ifcfg-${main_interface}
chmod +x $WORKDIR/boot_*.sh /etc/rc.local

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.local <<EOF
systemctl start NetworkManager.service
#ifup ${main_interface}
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

bash /etc/rc.local

gen_proxy_file_for_user


upload_proxy


# End

cd /root
rm -f Final_Origin.sh
