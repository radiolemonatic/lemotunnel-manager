#!/bin/bash

# --- COLORS & STYLE ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# --- CONSTANTS ---
BIN_PATH="/usr/local/bin/wstunnel"
SERVICE_PATH="/etc/systemd/system"

# --- HELPER FUNCTIONS ---
draw_line() {
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

print_banner() {
    echo -e "${YELLOW}"
    echo -e "  ██╗     ███████╗███╗   ███╗ ██████╗ ████████╗██╗   ██╗███╗   ██╗███╗   ██╗███████╗██╗     "
    echo -e "  ██║     ██╔════╝████╗ ████║██╔═══██╗╚══██╔══╝██║   ██║████╗  ██║████╗  ██║██╔════╝██║     "
    echo -e "  ██║     █████╗  ██╔████╔██║██║   ██║   ██║   ██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██║     "
    echo -e "  ██║     ██╔══╝  ██║╚██╔╝██║██║   ██║   ██║   ██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██║     "
    echo -e "  ███████╗███████╗██║ ╚═╝ ██║╚██████╔╝   ██║   ╚██████╔╝██║ ╚████║██║ ╚████║███████╗███████╗"
    echo -e "  ╚══════╝╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚══════╝"
    echo -e "                                 ${BOLD}${WHITE}🚀 LemoTunnel Manager 🚀${NC}"
    echo -e "${NC}"
}

check_remote_port() {
    local ip=$1
    local port=$2
    if timeout 2 bash -c "</dev/tcp/$ip/$port" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

get_status() {
    # Check if binary exists
    if [ -f "$BIN_PATH" ]; then
        CORE_STATUS="${GREEN}Installed ✅${NC}"
    else
        CORE_STATUS="${RED}Not Installed ❌${NC}"
    fi

    # Reset statuses
    IRAN_STATUS="${RED}Inactive 🔴${NC}"
    REMOTE_STATUS="${RED}Inactive 🔴${NC}"

    # Check Iran (Client) Status - If this service exists, we are likely on Iran Server
    if systemctl is-active --quiet wstunnel-client; then
        LPORT=$(grep -oP '0.0.0.0:\K[0-9]+' "${SERVICE_PATH}/wstunnel-client.service" | head -1)
        FPORT=$(grep -oP '127.0.0.1:\K[0-9]+' "${SERVICE_PATH}/wstunnel-client.service" | head -1)
        RIP=$(grep -oP 'ws://\K[0-9.]+' "${SERVICE_PATH}/wstunnel-client.service")
        RPORT=$(grep -oP 'ws://[0-9.]+:\K[0-9]+' "${SERVICE_PATH}/wstunnel-client.service")
        
        IRAN_STATUS="${GREEN}Active 🟢 ${YELLOW}(Local:$LPORT -> Remote:$FPORT)${NC}"
        
        # Checking if Remote Server is reachable from Iran
        if check_remote_port "$RIP" "$RPORT"; then
            REMOTE_STATUS="${GREEN}Online 🌐 ${YELLOW}(Connected to $RIP:$RPORT)${NC}"
        else
            REMOTE_STATUS="${RED}Unreachable ⚠️ ${YELLOW}(Check Remote Server)${NC}"
        fi
    
    # Check Remote (Server) Status - If this service exists, we are likely on Outside Server
    elif systemctl is-active --quiet wstunnel-server; then
        WSPORT=$(grep -oP 'ws://0.0.0.0:\K[0-9]+' "${SERVICE_PATH}/wstunnel-server.service")
        DIP_PORT=$(grep -oP '127.0.0.1:\K[0-9]+' "${SERVICE_PATH}/wstunnel-server.service")
        
        REMOTE_STATUS="${GREEN}Active 🟢 ${YELLOW}(WS:$WSPORT -> Dest:$DIP_PORT)${NC}"
        # Since Server cannot actively check Iran's IP/Port, we set it to Unknown/Waiting
        IRAN_STATUS="${BLUE}Unknown/Waiting... ⏳ ${YELLOW}(Inbound Connection)${NC}"
        
    elif systemctl is-failed --quiet wstunnel-server; then
        REMOTE_STATUS="${RED}Failed ⚠️${NC}"
    elif systemctl is-failed --quiet wstunnel-client; then
        IRAN_STATUS="${RED}Failed ⚠️${NC}"
    fi
}

print_header() {
    get_status
    clear
    print_banner
    draw_line
    echo -e "${BOLD}${MAGENTA}   ⚙️  SYSTEM STATUS ⚙️   ${NC}"
    draw_line
    echo -e "${BOLD} 🛠️  Core Version:   $CORE_STATUS"
    echo -e " 🇮🇷 Iran Node:      $IRAN_STATUS"
    echo -e " 🌍 Remote Node:    $REMOTE_STATUS${NC}"
    draw_line
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ Please run as root (use sudo).${NC}"
        exit 1
    fi
}

# --- MENU OPTIONS ---

install_requirements() {
    print_header
    echo -e "${YELLOW}🛠️  Installing Requirements & Binary...${NC}"
    apt-get update && apt-get install -y curl wget jq gzip unzip netcat-openbsd
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  WST_ARCH="linux_amd64" ;;
        aarch64) WST_ARCH="linux_arm64" ;;
        *)       echo -e "${RED}❌ Unsupported architecture: $ARCH${NC}"; return ;;
    esac
    LATEST_TAG=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest | jq -r .tag_name)
    VERSION=${LATEST_TAG#v}
    DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/${LATEST_TAG}/wstunnel_${VERSION}_${WST_ARCH}.tar.gz"
    wget -qO wstunnel.tar.gz "$DOWNLOAD_URL"
    tar -xvf wstunnel.tar.gz
    chmod +x wstunnel
    mv wstunnel "$BIN_PATH"
    rm -f wstunnel.tar.gz LICENSE README.md 2>/dev/null
    echo -e "${GREEN}✅ wstunnel installed successfully.${NC}"
    read -p "Press Enter..."
}

setup_remote_server() {
    print_header
    read -p "Enter WebSocket Port to listen (WS Port): " RPORT
    read -p "Enter Destination Port to forward (e.g., 51820 for WireGuard): " FPORT
    cat <<EOF > "${SERVICE_PATH}/wstunnel-server.service"
[Unit]
Description=WSTunnel Server
After=network.target
[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} server --restrict-to 127.0.0.1:${FPORT} ws://0.0.0.0:${RPORT}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable wstunnel-server && systemctl restart wstunnel-server
    sleep 3
    read -p "Setup complete. Press Enter..."
}

setup_iran_server() {
    print_header
    read -p "Enter Remote Server IP: " RIP
    read -p "Enter Remote Server WS Port: " RPORT
    read -p "Enter Local Port to Bind (e.g. 51820): " LPORT
    read -p "Enter Destination Port on Remote: " FPORT
    
    # Adding --udp flag for better WireGuard support
    cat <<EOF > "${SERVICE_PATH}/wstunnel-client.service"
[Unit]
Description=WSTunnel Client
After=network.target
[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} client --local-to-remote udp://0.0.0.0:${LPORT}:127.0.0.1:${FPORT} --local-to-remote tcp://0.0.0.0:${LPORT}:127.0.0.1:${FPORT} ws://${RIP}:${RPORT}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable wstunnel-client && systemctl restart wstunnel-client
    sleep 3
    read -p "Setup complete. Press Enter..."
}

live_monitor_test() {
    print_header
    echo -e "${MAGENTA}🔍 LIVE CONNECTION MONITOR & TEST${NC}"
    draw_line
    echo -e "1) Server Mode: Listen for packets (Run this on Outside Server)"
    echo -e "2) Client Mode: Send test packet (Run this on Iran Server)"
    echo -e "3) Back"
    draw_line
    read -p "Select [1-3]: " TOPT
    
    case $TOPT in
        1)
            FPORT=$(grep -oP '127.0.0.1:\K[0-9]+' "${SERVICE_PATH}/wstunnel-server.service" 2>/dev/null)
            if [ -z "$FPORT" ]; then echo -e "${RED}Server service not found!${NC}"; sleep 2; return; fi
            echo -e "${YELLOW}📡 Listening on localhost:${FPORT} for incoming tunnel data...${NC}"
            echo -e "${CYAN}(Press Ctrl+C to stop listening and return)${NC}"
            nc -l -v -p "$FPORT" -s 127.0.0.1
            echo -e "\n${GREEN}✅ Listening session ended.${NC}"
            read -p "Press Enter to return to menu..."
            ;;
        2)
            LPORT=$(grep -oP '0.0.0.0:\K[0-9]+' "${SERVICE_PATH}/wstunnel-client.service" 2>/dev/null | head -1)
            if [ -z "$LPORT" ]; then echo -e "${RED}Client service not found!${NC}"; sleep 2; return; fi
            echo -e "${BLUE}🚀 Sending test packet to local port ${LPORT}...${NC}"
            echo "Lemonatic-FM-Tunnel-Test-OK" | nc -w 3 127.0.0.1 "$LPORT"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Packet sent to local bridge! Check Server side for receipt.${NC}"
            else
                echo -e "${RED}❌ Failed to send packet. Is the tunnel local port open?${NC}"
            fi
            read -p "Press Enter..."
            ;;
        *) return ;;
    esac
}

manage_tunnels() {
    print_header
    echo -e "${YELLOW}⚙️  Manage Tunnels:${NC}"
    echo -e "1) Restart Server Service"
    echo -e "2) Restart Client Service"
    echo -e "3) Stop All Tunnels"
    echo -e "4) Back to Main Menu"
    draw_line
    read -p "Select an option [1-4]: " MOPT
    case $MOPT in
        1) systemctl restart wstunnel-server && echo -e "${GREEN}Server Restarted.${NC}" ;;
        2) systemctl restart wstunnel-client && echo -e "${GREEN}Client Restarted.${NC}" ;;
        3) systemctl stop wstunnel-server wstunnel-client && echo -e "${RED}All Tunnels Stopped.${NC}" ;;
        *) return ;;
    esac
    sleep 2
}

view_logs() {
    print_header
    echo -e "${BLUE}📝 View Logs:${NC}"
    echo -e "1) Server Logs"
    echo -e "2) Client Logs"
    echo -e "3) Back"
    draw_line
    read -p "Select an option [1-3]: " LOPT
    case $LOPT in
        1) journalctl -u wstunnel-server -n 50 --no-pager ;;
        2) journalctl -u wstunnel-client -n 50 --no-pager ;;
        *) return ;;
    esac
    read -p "Press Enter to return..."
}

uninstall_all() {
    print_header
    echo -e "${RED}⚠️  Uninstalling...${NC}"
    systemctl stop wstunnel-server wstunnel-client 2>/dev/null
    systemctl disable wstunnel-server wstunnel-client 2>/dev/null
    rm -f "${SERVICE_PATH}/wstunnel-server.service" "${SERVICE_PATH}/wstunnel-client.service" "$BIN_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}✅ Uninstalled successfully.${NC}"
    read -p "Press Enter..."
}

check_root
while true; do
    print_header
    echo -e "${BOLD}${WHITE}1)${NC} ${CYAN}🛠️  Install Requirements & WSTunnel${NC}"
    echo -e "${BOLD}${WHITE}2)${NC} ${MAGENTA}🌍 Setup Remote Server (Outside)${NC}"
    echo -e "${BOLD}${WHITE}3)${NC} ${GREEN}🇮🇷 Setup Iran Server (Client)${NC}"
    echo -e "${BOLD}${WHITE}4)${NC} ${BOLD}${YELLOW}📡 Live Connection Test (Monitor)${NC}"
    echo -e "${BOLD}${WHITE}5)${NC} ${YELLOW}⚙️  Manage Tunnels (Start/Stop)${NC}"
    echo -e "${BOLD}${WHITE}6)${NC} ${BLUE}📝 View Logs${NC}"
    echo -e "${BOLD}${WHITE}7)${NC} ${RED}🗑️  Uninstall Completely${NC}"
    echo -e "${BOLD}${WHITE}8)${NC} ${BOLD}🚪 Exit${NC}"
    draw_line
    read -p "Please choose an option [1-8]: " CHOICE
    case $CHOICE in
        1) install_requirements ;;
        2) setup_remote_server ;;
        3) setup_iran_server ;;
        4) live_monitor_test ;;
        5) manage_tunnels ;;
        6) view_logs ;;
        7) uninstall_all ;;
        8) 
            echo -e "${GREEN}Goodbye 👋🍋${NC}"
            break 
            ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done
