#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration file for port and next user ID
CONFIG_FILE="/etc/danted_script_config.conf"
DEFAULT_PORT="1080"
NEXT_USER_ID=1
PROXY_PORT="" # Global variable to store the actual port in use

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

# Function to load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        # Ensure NEXT_USER_ID is a number, default to 1 if not set or invalid
        if ! [[ "$NEXT_USER_ID" =~ ^[0-9]+$ ]]; then
            NEXT_USER_ID=1
        fi
        # Ensure PROXY_PORT is a number, default if not set or invalid
        if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
            PROXY_PORT="$DEFAULT_PORT"
        fi
        echo -e "${CYAN}Loaded configuration: Port=$PROXY_PORT, Next User ID=$NEXT_USER_ID${NC}"
    else
        PROXY_PORT="$DEFAULT_PORT"
        echo -e "${YELLOW}No existing configuration file found. Using default port $DEFAULT_PORT.${NC}"
    fi
}

# Function to save configuration to file
save_config() {
    sudo bash -c "cat <<EOF > $CONFIG_FILE
PROXY_PORT=\"$PROXY_PORT\"
NEXT_USER_ID=\"$NEXT_USER_ID\"
EOF"
    echo -e "${GREEN}Configuration (Port=$PROXY_PORT, Next User ID=$NEXT_USER_ID) saved to $CONFIG_FILE.${NC}"
}

# Function to generate a random password
generate_password() {
    # Generates a 12-character random password
    openssl rand -base64 12 | tr -d "=+/" | head -c 12
}

# Function to add a single user
add_single_user() {
    echo -e "${CYAN}Please enter the username for the SOCKS5 proxy:${NC}"
    read username
    echo -e "${CYAN}Please enter the password for the SOCKS5 proxy:${NC}"
    read -s password
    echo

    if id "$username" &>/dev/null; then
        echo -e "${YELLOW}User @$username already exists. Updating password.${NC}"
    else
        sudo useradd --shell /usr/sbin/nologin "$username"
        echo -e "${GREEN}User @$username created successfully.${NC}"
    fi
    echo "$username:$password" | sudo chpasswd
    echo -e "${GREEN}Password updated successfully for user: $username.${NC}"
        # Test with the newly created user
    test_proxy "$username" "$password" "$PROXY_PORT"
}

# Function to create multiple users
create_multiple_users() {
    echo -e "${CYAN}How many SOCKS5 proxy users do you want to create?${NC}"
    read num_users

    if ! [[ "$num_users" =~ ^[0-9]+$ ]] || (( num_users < 1 )); then
        echo -e "${RED}Invalid number. Please enter a positive integer.${NC}"
        return 1
    fi

    local created_users=()
    echo -e "${CYAN}Creating $num_users users...${NC}"

    for (( i=0; i<num_users; i++ )); do
        local username="proxy_user_${NEXT_USER_ID}"
        local password=$(generate_password)

        if id "$username" &>/dev/null; then
            echo -e "${YELLOW}User @$username already exists. Updating password.${NC}"
        else
            sudo useradd --shell /usr/sbin/nologin "$username"
        fi
        echo "$username:$password" | sudo chpasswd
        echo -e "${GREEN}User @$username created.${NC}"

        created_users+=("$username:$password")
        NEXT_USER_ID=$((NEXT_USER_ID + 1))
    done

    echo -e "${GREEN}\n--- SOCKS5 Proxy Users Created ---${NC}"
    local proxy_ip=$(hostname -I | awk '{print $1}')
    for user_creds in "${created_users[@]}"; do
        local user=$(echo "$user_creds" | cut -d: -f1)
        local pass=$(echo "$user_creds" | cut -d: -f2)
        local encoded_user=$(url_encode "$user")
        local encoded_pass=$(url_encode "$pass")
        echo -e "User: ${CYAN}$user${NC}"
        echo -e "Pass: ${CYAN}$pass${NC}"
        echo -e "Proxy: ${CYAN}socks5://${encoded_user}:${encoded_pass}@${proxy_ip}:${PROXY_PORT}${NC}"
        echo -e "----------------------------------"
    done

    # Save the updated NEXT_USER_ID
    save_config

    # Test with the first created user
    if [[ ${#created_users[@]} -gt 0 ]]; then
        local first_user=$(echo "${created_users[0]}" | cut -d: -f1)
        local first_pass=$(echo "${created_users[0]}" | cut -d: -f2)
        test_proxy "$first_user" "$first_pass" "$PROXY_PORT"
    fi
}

# Function to test the SOCKS5 proxy
test_proxy() {
    local test_user="$1"
    local test_pass="$2"
    local test_port="$3"

    if [[ -z "$test_user" || -z "$test_pass" || -z "$test_port" ]]; then
        echo -e "${YELLOW}\nSkipping proxy test due to missing credentials/port.${NC}"
        return
    fi

    echo -e "${CYAN}\nTesting the SOCKS5 proxy with curl using user '$test_user' on port $test_port...${NC}"
    local proxy_ip=$(hostname -I | awk '{print $1}')
    local encoded_username=$(url_encode "$test_user")
    local encoded_password=$(url_encode "$test_pass")

    curl -s -x socks5://"$encoded_username":"$encoded_password"@"$proxy_ip":"$test_port" https://ipinfo.io/ -m 10 # -m 10 for timeout

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}\nSOCKS5 proxy test successful. Proxy is working.${NC}"
    else
        echo -e "${RED}\nSOCKS5 proxy test failed. Please check your configuration and network. (Curl exit code: $?)${NC}"
    fi
}

# --- Main Script Logic ---

# Load existing configuration
load_config

# Determine action based on danted installation status
if command -v danted &> /dev/null; then
    echo -e "${GREEN}Dante SOCKS5 server is already installed and configured on port $PROXY_PORT.${NC}"
    echo -e "${CYAN}Do you want to (1) Reconfigure, (2) Add a new single user, (3) Create multiple users, (4) Uninstall, or (5) Exit? (Enter 1, 2, 3, 4, or 5):${NC}"
    read choice
    case "$choice" in
        1)
            echo -e "${CYAN}Reconfiguring requires a new port. Please enter the port for the SOCKS5 proxy (current: $PROXY_PORT, default: $DEFAULT_PORT):${NC}"
            read port_input
            port_input=${port_input:-$PROXY_PORT} # Use current port as default if user just presses enter
            if ! [[ "$port_input" =~ ^[0-9]+$ ]] || (( port_input < 1 || port_input > 65535 )); then
                echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
                exit 1
            fi
            PROXY_PORT="$port_input"
            reconfigure=true
            ;;
        2)
            echo -e "${CYAN}Adding a new single user...${NC}"
            add_single_user
            ;;
        3)
            echo -e "${CYAN}Creating multiple users...${NC}"
            create_multiple_users
            ;;
        4)
            echo -e "${YELLOW}Uninstalling Dante SOCKS5 server...${NC}"
            sudo systemctl stop danted
            sudo systemctl disable danted
            sudo apt remove --purge dante-server -y
            sudo rm -f /etc/danted.conf /var/log/danted.log "$CONFIG_FILE"
            echo -e "${GREEN}Dante SOCKS5 server has been uninstalled successfully. Configuration file $CONFIG_FILE removed.${NC}"
            exit 0
            ;;
        *)
            echo -e "${YELLOW}Exiting.${NC}"
            exit 0
            ;;
    esac
else
    echo -e "${YELLOW}Dante SOCKS5 server is not installed on this system.${NC}"
    echo -e "${CYAN}Note: Port 1080 is commonly used for SOCKS5 proxies. However, it may be blocked by your ISP or server provider. If this happens, choose an alternate port.${NC}"
    echo -e "${CYAN}Please enter the port for the SOCKS5 proxy (default: $DEFAULT_PORT):${NC}"
    read port_input
    port_input=${port_input:-$DEFAULT_PORT}
    if ! [[ "$port_input" =~ ^[0-9]+$ ]] || (( port_input < 1 || port_input > 65535 )); then
        echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
        exit 1
    fi
    PROXY_PORT="$port_input"
    reconfigure=true
fi

# Install or Reconfigure Dante if needed
if [[ "$reconfigure" == "true" ]]; then
    sudo apt update -y
    sudo apt install dante-server curl -y
    echo -e "${GREEN}Dante SOCKS5 server installed successfully.${NC}"

    # Create the log file before starting the service
    sudo touch /var/log/danted.log
    sudo chown nobody:nogroup /var/log/danted.log

    # Automatically detect the primary network interface
    primary_interface=$(ip route | grep default | awk '{print $5}')
    if [[ -z "$primary_interface" ]]; then
        echo -e "${RED}Could not detect the primary network interface. Please check your network settings.${NC}"
        exit 1
    fi

    # Create the configuration file
    sudo bash -c "cat <<EOF > /etc/danted.conf
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $PROXY_PORT
external: $primary_interface
method: username
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
EOF"

    # Configure firewall rules
    if command -v ufw &> /dev/null; then
        if sudo ufw status | grep -q "Status: active"; then
            if ! sudo ufw status | grep -q "$PROXY_PORT/tcp"; then
                echo -e "${YELLOW}UFW is active. Allowing port $PROXY_PORT/tcp...${NC}"
                sudo ufw allow "$PROXY_PORT/tcp"
            fi
        fi
    else
        echo -e "${YELLOW}UFW not found. Skipping UFW configuration.${NC}"
    fi

    # Using iptables for systems without ufw or as a fallback
    if ! sudo iptables -L -n | grep -q "ACCEPT.*tcp.*dpt:$PROXY_PORT"; then
        echo -e "${YELLOW}Adding iptables rule for port $PROXY_PORT/tcp...${NC}"
        sudo iptables -A INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT
        # Save iptables rules (optional, requires iptables-persistent or similar)
        if command-v netfilter-persistent &> /dev/null; then
        sudo netfilter-persistent save
            echo -e "${GREEN}iptables rules saved.${NC}"
        elif command -v apt-get &> /dev/null && ! dpkg -s iptables-persistent &> /dev/null; then
            echo -e "${YELLOW}Consider installing 'iptables-persistent' to save iptables rules across reboots.${NC}"
        fi
    fi

    # Edit the systemd service file for danted
    # This ensures danted can write to its log file /var/log/danted.log
    if ! sudo grep -q "ReadWriteDirectories=/var/log" /lib/systemd/system/danted.service &>/dev/null; then
        sudo sed -i '/^\[Service\]/a ReadWriteDirectories=/var/log' /lib/systemd/system/danted.service
        echo -e "${GREEN}Added ReadWriteDirectories=/var/log to danted.service.${NC}"
    fi

    # Reload the systemd daemon and restart the service
    sudo systemctl daemon-reload
    sudo systemctl restart danted
    sudo systemctl enable danted

    # Check if the service is active
    if systemctl is-active --quiet danted; then
        echo -e "${GREEN}\nSocks5 server has been reconfigured and is running on port - $PROXY_PORT${NC}"
        save_config # Save the new port
    else
        echo -e "${RED}\nFailed to start the Socks5 server. Please check the logs for more details: /var/log/danted.log${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}\nScript finished.${NC}"
