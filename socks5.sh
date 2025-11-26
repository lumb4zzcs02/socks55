#!/bin/bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- User-defined network parameters ---
# Your public IPv4 address for clients to connect to
IPV4_PUBLIC="80.87.108.107"
# Your IPv6 subnet prefix (excluding the host part, ending with ::)
IPV6_SUBNET_PREFIX="2a01:5560:1001:df4f::"
# Network interface for both IPv4 and IPv6
NETWORK_INTERFACE="eth0"
# ------------------------------------

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

# Function to validate IPv6 subnet
validate_ipv6_subnet() {
    local subnet="$1"
    # Basic validation: starts with hexdigits, contains ':', ends with '::'
    if [[ ! "$subnet" =~ ^([0-9a-fA-F]{1,4}:){1,7}:(:[0-9a-fA-F]{1,4}){0,7}$ ]]; then
        echo -e "${RED}Invalid IPv6 subnet prefix: $subnet. It should end with '::' and be a valid prefix (e.g., 2a01:db8::).${NC}"
        return 1
    fi
    return 0
}

# Function to generate a specified number of unique IPv6 addresses
generate_unique_ipv6s() {
    local prefix="$1"
    local num_addresses="$2"
    local ipv6_list=()
    echo -e "${CYAN}Generating $num_addresses unique IPv6 addresses from $prefix/64...${NC}"
    for (( i=1; i<=$num_addresses; i++ )); do
        # Generate a unique host part (simple increment, ensuring it fits)
        # Using a simple increment for the last segment. For production, consider more robust methods to avoid conflicts.
        # This will generate addresses like 2a01:5560:1001:df4f::1, 2a01:5560:1001:df4f::2, etc.
        local host_part=$(printf "%x" $i)
        local new_ipv6="${prefix}${host_part}"
        ipv6_list+=("$new_ipv6")
    done
    echo "${ipv6_list[@]}"
}

# Check if eth0 exists
if ! ip link show "$NETWORK_INTERFACE" &>/dev/null; then
    echo -e "${RED}Error: Network interface '$NETWORK_INTERFACE' not found. Please ensure it exists and is correct.${NC}"
    exit 1
fi

# Validate IPv6 subnet prefix
if ! validate_ipv6_subnet "$IPV6_SUBNET_PREFIX"; then
    exit 1
fi

# Get number of unique IPv6 proxies to generate
if [[ -z "$NUM_IPV6_PROXIES" ]]; then
    echo -e "${CYAN}How many unique IPv6 addresses do you want to generate for outbound connections? (e.g., 10, default: 1)${NC}"
    read -p "Enter number: " num_proxies_input
    NUM_IPV6_PROXIES=${num_proxies_input:-1}
    if ! [[ "$NUM_IPV6_PROXIES" =~ ^[0-9]+$ ]] || (( NUM_IPV6_PROXIES < 1 || NUM_IPV6_PROXIES > 200 )); then # Cap at 200 for sanity
        echo -e "${RED}Invalid number. Please enter a number between 1 and 200.${NC}"
        exit 1
    fi
fi

# Generate the unique IPv6 addresses
GENERATED_IPV6S=($(generate_unique_ipv6s "$IPV6_SUBNET_PREFIX" "$NUM_IPV6_PROXIES"))

# Check if danted is installed
if command -v danted &> /dev/null; then
    echo -e "${GREEN}Dante SOCKS5 server is already installed.${NC}"
    echo -e "${CYAN}Do you want to (1) Reconfigure, (2) Add a new user, (3) Uninstall, or (4) Exit? (Enter 1, 2, 3, or 4):${NC}"
    read choice
    if [[ "$choice" == "1" ]]; then
        echo -e "${CYAN}Reconfiguring requires a port. Please enter the port for the SOCKS5 proxy (default: 1080):${NC}"
        read port
        port=${port:-1080}
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
            exit 1
        fi
        reconfigure=true
        add_user=false
    elif [[ "$choice" == "2" ]]; then
        echo -e "${CYAN}Adding a new user...${NC}"
        reconfigure=false
        add_user=true
    elif [[ "$choice" == "3" ]]; then
        echo -e "${YELLOW}Uninstalling Dante SOCKS5 server...${NC}"
        sudo systemctl stop danted
        sudo systemctl disable danted
        sudo apt remove --purge dante-server -y
        sudo rm -f /etc/danted.conf /var/log/danted.log
        echo -e "${GREEN}Dante SOCKS5 server has been uninstalled successfully.${NC}"
        exit 0
    else
        echo -e "${YELLOW}Exiting.${NC}"
        exit 0
    fi
else
    echo -e "${YELLOW}Dante SOCKS5 server is not installed on this system.${NC}"
    echo -e "${CYAN}Note: Port 1080 is commonly used for SOCKS5 proxies. However, it may be blocked by your ISP or server provider. If this happens, choose an alternate port.${NC}"
    echo -e "${CYAN}Please enter the port for the SOCKS5 proxy (default: 1080):${NC}"
    read port
    port=${port:-1080}
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
        exit 1
    fi
    reconfigure=true
    add_user=true
fi

# Install or Reconfigure Dante
if [[ "$reconfigure" == "true" ]]; then
    echo -e "${CYAN}Updating package lists and installing dante-server and curl...${NC}"
    sudo apt update -y
    sudo apt install dante-server curl -y
    echo -e "${GREEN}Dante SOCKS5 server installed successfully.${NC}"

    # Add unique IPv6 addresses to eth0 permanently via netplan
    echo -e "${CYAN}Configuring Netplan for persistent unique IPv6 addresses on $NETWORK_INTERFACE...${NC}"
    NETPLAN_CONFIG_FILE="/etc/netplan/01-custom-ipv6.yaml"
    sudo bash -c "cat <<EOF > $NETPLAN_CONFIG_FILE
network:
  version: 2
  renderer: networkd
  ethernets:
    $NETWORK_INTERFACE:
      addresses:
EOF"

    for ipv6_addr in "${GENERATED_IPV6S[@]}"; do
        sudo bash -c "echo \"        - $ipv6_addr/64\" >> $NETPLAN_CONFIG_FILE"
    done
    echo -e "${GREEN}Netplan configuration created at $NETPLAN_CONFIG_FILE.${NC}"
    echo -e "${CYAN}Applying Netplan configuration...${NC}"
    sudo netplan apply
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Netplan applied successfully. IPv6 addresses are now configured and persistent.${NC}"
    else
        echo -e "${RED}Failed to apply Netplan configuration. Please check '$NETPLAN_CONFIG_FILE' for errors.${NC}"
        exit 1
    fi

    # Create the log file before starting the service
    sudo touch /var/log/danted.log
    sudo chown nobody:nogroup /var/log/danted.log

    # Create the configuration file for Dante
    echo -e "${CYAN}Creating /etc/danted.conf...${NC}"
    sudo bash -c "cat <<EOF > /etc/danted.conf
logoutput: /var/log/danted.log
# Listen on all IPv4 addresses on port $port
internal: 0.0.0.0 port = $port
# Listen on all IPv6 addresses on port $port
internal: :: port = $port
# Use the specified network interface for external connections
# Dante will pick an available IPv6 address from this interface for outbound traffic
external: $NETWORK_INTERFACE
method: username
user.privileged: root
user.notprivileged: nobody

# Client rules for both IPv4 and IPv6
client pass {
    from: 0/0 to: 0/0
    log: connect disconnect error
}
client pass {
    from: ::/0 to: ::/0
    log: connect disconnect error
}

# SOCKS rules for both IPv4 and IPv6 outbound traffic
# Dante will automatically select an available IPv6 address from the 'external' interface ($NETWORK_INTERFACE)
# for outbound connections. This ensures unique IPv6 addresses are used for egress.
socks pass {
    from: 0/0 to: 0/0
    log: connect disconnect error
}
socks pass {
    from: ::/0 to: ::/0
    log: connect disconnect error
}
EOF"
    echo -e "${GREEN}Dante configuration file created at /etc/danted.conf.${NC}"

    # Configure firewall rules with UFW
    echo -e "${CYAN}Configuring UFW firewall rules...${NC}"
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW is not installed. Installing UFW...${NC}"
        sudo apt install ufw -y
    fi

    sudo ufw enable # Ensure UFW is enabled if not already
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh # Allow SSH if not already
    sudo ufw allow "$port"/tcp comment "Dante SOCKS5 Proxy" # This rule covers both IPv4 and IPv6 if UFW is configured for both
    echo -e "${GREEN}UFW rules configured to allow TCP traffic on port $port.${NC}"
    sudo ufw status verbose

    # Edit the systemd service file for danted to allow writing to /var/log
    if ! grep -q "ReadWriteDirectories=/var/log" /lib/systemd/system/danted.service; then
        echo -e "${CYAN}Editing danted systemd service file for log permissions...${NC}"
        sudo sed -i '/^\[Service\]/aReadWriteDirectories=/var/log' /lib/systemd/system/danted.service
    fi

    # Reload the systemd daemon and restart the service
    echo -e "${CYAN}Reloading systemd daemon and restarting danted service...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart danted
    sudo systemctl enable danted

    # Check if the service is active
    if systemctl is-active --quiet danted; then
        echo -e "${GREEN}\nSocks5 server has been reconfigured and is running on port - $port${NC}"
        echo -e "${GREEN}Outbound connections will now use one of the generated unique IPv6 addresses from $NETWORK_INTERFACE.${NC}"
    else
        echo -e "${RED}\nFailed to start the Socks5 server. Please check the logs for more details: /var/log/danted.log${NC}"
        exit 1
    fi
fi

# Add user
if [[ "$add_user" == "true" ]]; then
    echo -e "${CYAN}Please enter the username for the SOCKS5 proxy:${NC}"
    read username
    echo -e "${CYAN}Please enter the password for the SOCKS5 proxy:${NC}"
    read -s password
    if id "$username" &>/dev/null; then
        echo -e "${YELLOW}User @$username already exists. Updating password.${NC}"
    else
        sudo useradd --shell /usr/sbin/nologin "$username"
        echo -e "${GREEN}User @$username created successfully.${NC}"
    fi
    echo "$username:$password" | sudo chpasswd
    echo -e "${GREEN}Password updated successfully for user: $username.${NC}"
fi

# Test the SOCKS5 proxy
if [[ "$add_user" == "true" ]]; then
    echo -e "${CYAN}\nTesting the SOCKS5 proxy with curl...${NC}"
    encoded_username=$(url_encode "$username")
    encoded_password=$(url_encode "$password")

    echo -e "${YELLOW}Attempting to connect to proxy via IPv4: $IPV4_PUBLIC:$port${NC}"
    echo -e "${YELLOW}Expecting outbound IP to be one of the generated IPv6 addresses.${NC}"

    curl_output=$(curl -sS -x socks5://"$encoded_username":"$encoded_password"@"$IPV4_PUBLIC":"$port" https://ipinfo.io/json)
    curl_exit_code=$?

    if [[ $curl_exit_code -eq 0 ]]; then
        echo -e "${GREEN}\nSOCKS5 proxy test successful.${NC}"
        echo -e "${GREEN}Details from ipinfo.io: ${NC}"
        echo "$curl_output" | jq . # Use jq for pretty printing if installed
        
        # Check if the reported IP is an IPv6 address
        reported_ip=$(echo "$curl_output" | jq -r .ip)
        if [[ "$reported_ip" =~ ^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$ ]]; then
            echo -e "${GREEN}Reported IP is an IPv6 address: $reported_ip.${NC}"
            # Optionally check if it's one of our generated ones (simple prefix match)
            if [[ "$reported_ip" =~ ^${IPV6_SUBNET_PREFIX%.*} ]]; then # Check if prefix matches
                echo -e "${GREEN}The reported IPv6 address ($reported_ip) belongs to your configured subnet! Proxy is working as expected.${NC}"
            else
                echo -e "${YELLOW}The reported IPv6 address ($reported_ip) is IPv6, but does not seem to be from the configured subnet. Please check your network configuration.${NC}"
            fi
        else
            echo -e "${YELLOW}Reported IP is IPv4 ($reported_ip). This might indicate an issue with IPv6 routing or Dante's external configuration.${NC}"
        fi

    else
        echo -e "${RED}\nSOCKS5 proxy test failed. (Exit code: $curl_exit_code)${NC}"
        echo -e "${RED}Please check your configuration, logs (/var/log/danted.log), and firewall rules.${NC}"
        echo -e "${YELLOW}If 'jq' is not installed, the raw output might be above.${NC}"
        echo -e "${YELLOW}Raw curl output (if any):${NC}"
        echo "$curl_output"
    fi
    echo -e "${CYAN}\nGenerated Proxy URL (for client configuration):${NC}"
    echo -e "${GREEN}socks5://$username:$password@$IPV4_PUBLIC:$port${NC}"
fi
