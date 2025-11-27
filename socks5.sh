#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration file for port range and next user/port IDs
CONFIG_FILE="/etc/danted_script_config.conf"
DEFAULT_PORT_START="10000" # Default start of port range
DEFAULT_PORT_END="10099"   # Default end of port range

PROXY_PORT_START=""    # Global variable for start port
PROXY_PORT_END=""      # Global variable for end port
NEXT_USER_ID=1         # For naming users (e.g., proxy_user_1)
NEXT_AVAILABLE_PORT="" # For assigning the next port to a user

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
        # Ensure variables are set and are numbers, default if not
        if ! [[ "$PROXY_PORT_START" =~ ^[0-9]+$ ]]; then PROXY_PORT_START="$DEFAULT_PORT_START"; fi
        if ! [[ "$PROXY_PORT_END" =~ ^[0-9]+$ ]]; then PROXY_PORT_END="$DEFAULT_PORT_END"; fi
        if ! [[ "$NEXT_USER_ID" =~ ^[0-9]+$ ]]; then NEXT_USER_ID=1; fi
        # If NEXT_AVAILABLE_PORT is not set or out of range, reset it to start
        if ! [[ "$NEXT_AVAILABLE_PORT" =~ ^[0-9]+$ ]] || (( NEXT_AVAILABLE_PORT < PROXY_PORT_START || NEXT_AVAILABLE_PORT > PROXY_PORT_END )); then
            NEXT_AVAILABLE_PORT="$PROXY_PORT_START"
        fi
        echo -e "${CYAN}Loaded configuration: Port Range=${PROXY_PORT_START}-${PROXY_PORT_END}, Next User ID=${NEXT_USER_ID}, Next Assigned Port=${NEXT_AVAILABLE_PORT}${NC}"
    else
        PROXY_PORT_START="$DEFAULT_PORT_START"
        PROXY_PORT_END="$DEFAULT_PORT_END"
        NEXT_AVAILABLE_PORT="$DEFAULT_PORT_START"
        echo -e "${YELLOW}No existing configuration file found. Using default port range ${DEFAULT_PORT_START}-${DEFAULT_PORT_END}.${NC}"
    fi
}

# Function to save configuration to file
save_config() {
    sudo bash -c "cat <<EOF > $CONFIG_FILE
PROXY_PORT_START=\"$PROXY_PORT_START\"
PROXY_PORT_END=\"$PROXY_PORT_END\"
NEXT_USER_ID=\"$NEXT_USER_ID\"
NEXT_AVAILABLE_PORT=\"$NEXT_AVAILABLE_PORT\"
EOF"
    echo -e "${GREEN}Configuration (Port Range=${PROXY_PORT_START}-${PROXY_PORT_END}, Next User ID=${NEXT_USER_ID}, Next Assigned Port=${NEXT_AVAILABLE_PORT}) saved to $CONFIG_FILE.${NC}"
}

# Function to generate a random password
generate_password() {
    # Generates a 12-character random password
    openssl rand -base64 12 | tr -d "=+/" | head -c 12
}

# Function to validate port range
validate_port_range() {
    local start="$1"
    local end="$2"
    if ! [[ "$start" =~ ^[0-9]+$ ]] || ! [[ "$end" =~ ^[0-9]+$ ]] || \
       (( start < 1 || start > 65535 )) || (( end < 1 || end > 65535 )) || (( start > end )); then
        echo -e "${RED}Invalid port range. Start and end ports must be numbers between 1 and 65535, and start port must be less than or equal to end port.${NC}"
        return 1
    fi
    return 0
}

# Function to create multiple users and assign ports
create_multiple_users() {
    local max_users_in_range=$(( PROXY_PORT_END - NEXT_AVAILABLE_PORT + 1 ))

    if (( max_users_in_range <= 0 )); then
        echo -e "${RED}No available ports left in the current range ${PROXY_PORT_START}-${PROXY_PORT_END} starting from ${NEXT_AVAILABLE_PORT}. Please reconfigure the port range.${NC}"
        return 1
    fi

    echo -e "${CYAN}How many SOCKS5 proxy users do you want to create? (Max ${max_users_in_range} users available in current range)${NC}"
    read num_users

    if ! [[ "$num_users" =~ ^[0-9]+$ ]] || (( num_users < 1 )); then
        echo -e "${RED}Invalid number. Please enter a positive integer.${NC}"
        return 1
    fi

    if (( num_users > max_users_in_range )); then
        echo -e "${YELLOW}Requested $num_users users, but only $max_users_in_range ports are available in the current range. Creating $max_users_in_range users.${NC}"
        num_users=$max_users_in_range
    fi

    local created_proxies=()
    echo -e "${CYAN}Creating $num_users users...${NC}"

    for (( i=0; i<num_users; i++ )); do
        local username="proxy_user_${NEXT_USER_ID}"
        local password=$(generate_password)
        local assigned_port="$NEXT_AVAILABLE_PORT"
        local proxy_ip=$(hostname -I | awk '{print $1}')
        local encoded_user=$(url_encode "$username")
        local encoded_pass=$(url_encode "$password")

        if id "$username" &>/dev/null; then
            echo -e "${YELLOW}User @$username already exists. Updating password.${NC}"
        else
            sudo useradd --shell /usr/sbin/nologin "$username"
        fi
        echo "$username:$password" | sudo chpasswd
        echo -e "${GREEN}User @$username created/updated, assigned port $assigned_port.${NC}"

        created_proxies+=("socks5://${encoded_user}:${encoded_pass}@${proxy_ip}:${assigned_port}")
        
        NEXT_USER_ID=$((NEXT_USER_ID + 1))
        NEXT_AVAILABLE_PORT=$((NEXT_AVAILABLE_PORT + 1))
    done

    echo -e "${GREEN}\n--- SOCKS5 Proxy Users Created ---${NC}"
    echo -e "${CYAN}Please save these details. They will not be displayed again automatically.${NC}"
    local counter=1
    for proxy_string in "${created_proxies[@]}"; do
        echo -e "${CYAN}Proxy ${counter}: ${GREEN}${proxy_string}${NC}"
        counter=$((counter + 1))
    done
    echo -e "${GREEN}----------------------------------${NC}"

    # Save the updated NEXT_USER_ID and NEXT_AVAILABLE_PORT
    save_config

    # Test with the first created proxy
    if [[ ${#created_proxies[@]} -gt 0 ]]; then
        local first_proxy_string="${created_proxies[0]}"
        local test_user=$(echo "$first_proxy_string" | sed -E 's/socks5:\/\/(.*):(.*)@.*:\/([0-9]+)/\1/')
        local test_pass=$(echo "$first_proxy_string" | sed -E 's/socks5:\/\/(.*):(.*)@.*:\/([0-9]+)/\2/')
        local test_port=$(echo "$first_proxy_string" | sed -E 's/.*:([0-9]+)$/\1/')
        
        # We need the *decoded* username and password for the test_proxy function
        # The proxy string uses encoded ones, but the useradd part uses raw.
        # So we'll pass the raw ones to test_proxy.
        local raw_test_user="proxy_user_$(($NEXT_USER_ID - $num_users))" # Get the first user name created
        local raw_test_pass=$(echo "$first_proxy_string" | sed -E 's/socks5:\/\/.*:(.*)@.*/\1/') # This will be the encoded pass
        # Need to decode it to pass to `test_proxy` if it expects raw. Simpler to pass the raw credentials generated.
        # For simplicity of test, we will just use the first generated user/pass for a general connectivity check.
        # This part assumes `test_proxy` can handle url-encoded credentials directly or we supply the raw ones.
        
        echo -e "${CYAN}\nTesting the SOCKS5 proxy with curl using the first created user...${NC}"
        local proxy_ip_for_test=$(hostname -I | awk '{print $1}')
        curl -s -x "$first_proxy_string" https://ipinfo.io/ -m 10 # -m 10 for timeout

        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}\nSOCKS5 proxy test successful. Proxy is working.${NC}"
        else
            echo -e "${RED}\nSOCKS5 proxy test failed. Please check your configuration. (Curl exit code: $?)${NC}"
        fi
    fi
}

# --- Main Script Logic ---

# Load existing configuration
load_config

# Determine action based on danted installation status
if command -v danted &> /dev/null; then
    echo -e "${GREEN}Dante SOCKS5 server is already installed and configured on port range ${PROXY_PORT_START}-${PROXY_PORT_END}.${NC}"
    echo -e "${CYAN}Do you want to (1) Reconfigure, (2) Create multiple users, (3) Uninstall, or (4) Exit? (Enter 1, 2, 3, or 4):${NC}"
    read choice
    case "$choice" in
        1)
            echo -e "${CYAN}Reconfiguring requires a new port range.${NC}"
            echo -e "${CYAN}Please enter the START port for the SOCKS5 proxy (current: ${PROXY_PORT_START}, default: ${DEFAULT_PORT_START}):${NC}"
            read new_start_port
            new_start_port=${new_start_port:-$PROXY_PORT_START}

            echo -e "${CYAN}Please enter the END port for the SOCKS5 proxy (current: ${PROXY_PORT_END}, default: ${DEFAULT_PORT_END}):${NC}"
            read new_end_port
            new_end_port=${new_end_port:-$PROXY_PORT_END}

            if ! validate_port_range "$new_start_port" "$new_end_port"; then
                exit 1
            fi
            PROXY_PORT_START="$new_start_port"
            PROXY_PORT_END="$new_end_port"
            NEXT_AVAILABLE_PORT="$PROXY_PORT_START" # Reset next available port to the new start
            reconfigure=true
            ;;
        2)
            echo -e "${CYAN}Creating multiple users...${NC}"
            create_multiple_users
            # No exit here, allow script to finish normally after user creation if no reconfiguration needed
            exit 0 # Exit after user creation if server is already configured
            ;;
        3)
            echo -e "${YELLOW}Uninstalling Dante SOCKS5 server...${NC}"
            sudo systemctl stop danted
            sudo systemctl disable danted
            sudo apt remove --purge dante-server -y
            sudo rm -f /etc/danted.conf /var/log/danted.log "$CONFIG_FILE"
            # Remove users created by script (optional, as they might be needed for other services)
            # for user in $(grep -oP '^proxy_user_[0-9]+' /etc/passwd | cut -d: -f1); do
            #     sudo deluser --remove-home "$user"
            # done
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
    echo -e "${CYAN}Note: Port 1080 is commonly used for SOCKS5 proxies, but it may be blocked. We recommend a high port range (e.g., 10000-10099).${NC}"
    echo -e "${CYAN}Please enter the START port for the SOCKS5 proxy (default: ${DEFAULT_PORT_START}):${NC}"
    read new_start_port
    new_start_port=${new_start_port:-$DEFAULT_PORT_START}

    echo -e "${CYAN}Please enter the END port for the SOCKS5 proxy (default: ${DEFAULT_PORT_END}):${NC}"
    read new_end_port
    new_end_port=${new_end_port:-$DEFAULT_PORT_END}

    if ! validate_port_range "$new_start_port" "$new_end_port"; then
        exit 1
    fi
    PROXY_PORT_START="$new_start_port"
    PROXY_PORT_END="$new_end_port"
    NEXT_AVAILABLE_PORT="$PROXY_PORT_START"
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

    # Create the configuration file with port range
    sudo bash -c "cat <<EOF > /etc/danted.conf
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $PROXY_PORT_START-$PROXY_PORT_END
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

    # Configure firewall rules for the entire port range
    if command -v ufw &> /dev/null; then
        if sudo ufw status | grep -q "Status: active"; then
            # Delete old rules for the range if they exist
            sudo ufw delete allow "$PROXY_PORT_START:$PROXY_PORT_END/tcp" &>/dev/null
            echo -e "${YELLOW}UFW is active. Allowing port range ${PROXY_PORT_START}:${PROXY_PORT_END}/tcp...${NC}"
            sudo ufw allow "$PROXY_PORT_START:$PROXY_PORT_END/tcp"
        fi
    else
        echo -e "${YELLOW}UFW not found. Skipping UFW configuration.${NC}"
    fi

    if ! sudo iptables -L -n | grep -q "ACCEPT.*tcp.*dpts:${PROXY_PORT_START}:${PROXY_PORT_END}"; then
        echo -e "${YELLOW}Adding iptables rule for port range ${PROXY_PORT_START}:${PROXY_PORT_END}/tcp...${NC}"
        # Delete old rules for the range if they exist
        sudo iptables -D INPUT -p tcp --dport "$PROXY_PORT_START:$PROXY_PORT_END" -j ACCEPT &>/dev/null
        sudo iptables -A INPUT -p tcp --dport "$PROXY_PORT_START:$PROXY_PORT_END" -j ACCEPT
        # Save iptables rules (optional, requires iptables-persistent or similar)
        if command -v netfilter-persistent &> /dev/null; then
            sudo netfilter-persistent save
            echo -e "${GREEN}iptables rules saved.${NC}"
        elif command -v apt-get &> /dev/null && ! dpkg -s iptables-persistent &> /dev/null; then
            echo -e "${YELLOW}Consider installing 'iptables-persistent' to save iptables rules across reboots.${NC}"
        fi
    fi

    # Edit the systemd service file for danted
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
        echo -e "${GREEN}\nSocks5 server has been reconfigured and is running on port range - ${PROXY_PORT_START}-${PROXY_PORT_END}${NC}"
        save_config # Save the new port range
        # After reconfiguring, ask to create users
        echo -e "${CYAN}Do you want to create multiple SOCKS5 proxy users now? (y/n)${NC}"
        read create_users_now
        if [[ "$create_users_now" == "y" || "$create_users_now" == "Y" ]]; then
            create_multiple_users
        fi
    else
        echo -e "${RED}\nFailed to start the Socks5 server. Please check the logs for more details: /var/log/danted.log${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}\nScript finished.${NC}"
