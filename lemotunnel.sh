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
VERSION="1.1.3"

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
    echo -e "                                 ${BOLD}${WHITE}🚀 LemoTunnel Manager v$VERSION 🚀${NC}"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ Please run as root (use sudo).${NC}"
        exit 1
    fi
}

get_current_bin_version() {
    if [ -f "$BIN_PATH" ]; then
        local ver=$($BIN_PATH --version 2>/dev/null | awk '{print $2}')
        if [ -z "$ver" ]; then echo "Unknown"; else echo "v$ver"; fi
    else
        echo "None"
    fi
}

get_latest_bin_version() {
    local latest=$(curl -s https://api.github.com/repos/erebe/wstunnel/releases/latest | jq -r .tag_name)
    if [ "$latest" == "null" ] || [ -z "$latest" ]; then
        echo "Check Failed"
    else
        echo "$latest"
    fi
}

get_core_status() {
    if [ -f "$BIN_PATH" ]; then
        local ver=$(get_current_bin_version)
        echo -e "${GREEN}Installed ($ver) ✅${NC}"
    else
        echo -e "${RED}Not Installed ❌${NC}"
    fi
}

check_requirements() {
    local missing=0
    # Checking for commands instead of just package names
    for cmd in curl wget jq gzip unzip fuser nc; do
        if ! command -v $cmd &> /dev/null; then
            missing=$((missing + 1))
        fi
    done
    if [ $missing -eq 0 ]; then
        echo -e "${GREEN}(All Installed ✅)${NC}"
    else
        echo -e "${RED}($missing Missing ❌)${NC}"
    fi
}

install_requirements() {
    print_header
    echo -e "${YELLOW}🛠️  Installing System Requirements...${NC}"
    apt-get update
    
    # Define package mapping (Command -> Package Name)
    declare -A pkgs=( 
        ["curl"]="curl" 
        ["wget"]="wget" 
        ["jq"]="jq" 
        ["gzip"]="gzip" 
        ["unzip"]="unzip" 
        ["nc"]="netcat-openbsd" 
        ["fuser"]="psmisc" 
    )

    for cmd in "${!pkgs[@]}"; do
        local pkg=${pkgs[$cmd]}
        echo -n "Checking $pkg... "
        if command -v "$cmd" &> /dev/null; then
            echo -e "${GREEN}Already Installed${NC}"
        else
            echo -e "${YELLOW}Installing...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" &> /dev/null
            if [ $? -ne 0 ]; then
                # Try fallback for netcat
                if [ "$pkg" == "netcat-openbsd" ]; then
                    apt-get install -y netcat-traditional &> /dev/null
                fi
            fi
            
            # Re-verify
            if command -v "$cmd" &> /dev/null; then
                echo -e "${GREEN}Success ✅${NC}"
            else
                echo -e "${RED}Failed ❌${NC}"
            fi
        fi
    done
    echo -e "${GREEN}✅ Check complete.${NC}"
    sleep 2
}

install_wstunnel_binary() {
    print_header
    echo -e "${YELLOW}📥 Downloading & Installing wstunnel Binary...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  WST_ARCH="linux_amd64" ;;
        aarch64) WST_ARCH="linux_arm64" ;;
        *)       echo -e "${RED}❌ Unsupported architecture: $ARCH${NC}"; sleep 2; return ;;
    esac
    
    LATEST_TAG=$(get_latest_bin_version)
    if [ "$LATEST_TAG" == "Check Failed" ]; then
        echo -e "${RED}❌ Could not fetch version. Check your internet.${NC}"
        sleep 2; return
    fi
    
    VERSION_NUM=${LATEST_TAG#v}
    DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/${LATEST_TAG}/wstunnel_${VERSION_NUM}_${WST_ARCH}.tar.gz"
    
    rm -f wstunnel.tar.gz
    wget -qO wstunnel.tar.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then echo -e "${RED}❌ Download failed.${NC}"; sleep 2; return; fi
    
    tar -xvf wstunnel.tar.gz
    chmod +x wstunnel
    mv -f wstunnel "$BIN_PATH"
    rm -f wstunnel.tar.gz LICENSE README.md 2>/dev/null
    echo -e "${GREEN}✅ Binary $LATEST_TAG installed at $BIN_PATH${NC}"
    sleep 2
}

# --- TUNNEL MANAGEMENT ---

list_tunnels() {
    local tunnels=$(ls ${SERVICE_PATH}/lemo-*.service 2>/dev/null)
    if [ -z "$tunnels" ]; then
        echo -e "${YELLOW}⚠️  No LemoTunnels found.${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║ ID   | Name         | Type    | Status   | Details       ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    
    local count=1
    for t in $tunnels; do
        local name=$(basename "$t" .service | sed 's/lemo-//')
        local status_icon="🔴"
        
        if systemctl is-active --quiet "lemo-$name"; then
            status_icon="🟢"
        else
            if pgrep -f "wstunnel.*lemo-$name" > /dev/null || pgrep -f "lemo-$name" > /dev/null; then
                 status_icon="🟢"
            fi
        fi
        
        local type="Unknown"
        grep -q "server" "$t" && type="Outside "
        grep -q "client" "$t" && type="Iran    "
        
        printf "${BOLD}${CYAN}║${NC} %-4s | %-12s | %-7s |    %-5s | %-13s ${BOLD}${CYAN}║${NC}\n" \
            "$count" "$name" "$type" "$status_icon" "Select to see"
        
        eval "tunnel_$count=\"$name\""
        count=$((count + 1))
    done
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    return 0
}

setup_new_tunnel() {
    print_header
    echo -e "${MAGENTA}🆕 Create New Tunnel${NC}"
    read -p "Enter a name for this tunnel (e.g. sw): " TNAME
    if [ -f "${SERVICE_PATH}/lemo-${TNAME}.service" ]; then
        echo -e "${RED}❌ Name already exists!${NC}"; sleep 2; return
    fi

    echo -e "1) Iran Node (Client)"
    echo -e "2) Outside Node (Server)"
    read -p "Choose type [1-2]: " TTYPE

    if [ "$TTYPE" == "1" ]; then
        read -p "Remote Server IP: " RIP
        read -p "Remote WS Port: " RWPORT
        read -p "Local Port: " LPORT
        read -p "Remote Dest Port: " RPORT
        echo -e "${YELLOW}Select Protocol:${NC}"
        echo -e "1) TCP"
        echo -e "2) UDP"
        echo -e "3) Both (TCP & UDP)"
        read -p ">> [1-3]: " PROT
        
        local CMD_PROT=""
        [[ "$PROT" == "1" || "$PROT" == "3" ]] && CMD_PROT+="--local-to-remote tcp://0.0.0.0:${LPORT}:127.0.0.1:${RPORT} "
        [[ "$PROT" == "2" || "$PROT" == "3" ]] && CMD_PROT+="--local-to-remote udp://0.0.0.0:${LPORT}:127.0.0.1:${RPORT} "

        cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel Client: ${TNAME}
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BIN_PATH} client $CMD_PROT ws://${RIP}:${RWPORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    else
        read -p "WS Port to listen: " RWPORT
        read -p "Dest Port to forward (e.g. 22): " FPORT
        cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel Server: ${TNAME}
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BIN_PATH} server --restrict-to 127.0.0.1:${FPORT} ws://0.0.0.0:${RWPORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload && systemctl enable "lemo-${TNAME}" && systemctl start "lemo-${TNAME}"
    echo -e "${GREEN}✅ Tunnel $TNAME created and started!${NC}"
    sleep 2
}

manage_tunnels_menu() {
    while true; do
        clear
        print_banner
        draw_line
        echo -e "${BOLD}${MAGENTA}   📦 TUNNEL EXPLORER   ${NC}"
        draw_line
        list_tunnels
        local ret=$?
        draw_line
        
        if [ $ret -ne 0 ]; then
            read -p "Press Enter to return to main menu..."
            break
        fi

        echo -e "Enter Tunnel ID to manage or 'b' to back:"
        read -p ">> " T_ID
        
        [[ "$T_ID" == "b" ]] && break
        
        local T_NAME=$(eval echo \$tunnel_$T_ID)
        if [ -z "$T_NAME" ]; then echo -e "${RED}Invalid ID!${NC}"; sleep 1; continue; fi
        
        while true; do
            clear
            print_banner
            draw_line
            echo -e "${BOLD}${YELLOW}   🛠️ Managing Tunnel: ${WHITE}$T_NAME${NC}"
            draw_line
            echo -e "1) ${GREEN}▶️ Start${NC}"
            echo -e "2) ${YELLOW}🔄 Restart${NC}"
            echo -e "3) ${RED}⏹️ Stop${NC}"
            echo -e "4) ${BLUE}📝 View Logs${NC}"
            echo -e "5) ${CYAN}📊 Status Detail${NC}"
            echo -e "6) ${RED}🗑️ Delete Tunnel${NC}"
            echo -e "7) 🔙 Back"
            draw_line
            read -p "Select action [1-7]: " T_ACT
            
            case $T_ACT in
                1) systemctl start "lemo-$T_NAME" ;;
                2) systemctl restart "lemo-$T_NAME" ;;
                3) systemctl stop "lemo-$T_NAME" ;;
                4) journalctl -u "lemo-$T_NAME" -n 50 --no-pager ; read -p "Press Enter..." ;;
                5) systemctl status "lemo-$T_NAME" ; read -p "Press Enter..." ;;
                6) 
                    echo -e "${YELLOW}Cleaning up ports and removing service...${NC}"
                    local ports=$(grep -oP '(tcp|udp)://0.0.0.0:\K[0-9]+|ws://0.0.0.0:\K[0-9]+' "${SERVICE_PATH}/lemo-${T_NAME}.service")
                    systemctl stop "lemo-$T_NAME" && systemctl disable "lemo-$T_NAME"
                    for p in $ports; do
                        fuser -k -n tcp $p 2>/dev/null
                        fuser -k -n udp $p 2>/dev/null
                    done
                    rm -f "${SERVICE_PATH}/lemo-${T_NAME}.service"
                    systemctl daemon-reload
                    echo -e "${GREEN}Tunnel $T_NAME deleted.${NC}"; sleep 1; break 2 ;;
                7) break ;;
            esac
        done
    done
}

print_header() {
    clear
    print_banner
    draw_line
    echo -e "${BOLD} 🛠️  Core Engine: $(get_core_status)"
    draw_line
}

# --- MAIN MENU ---
check_root
LATEST_VER=$(get_latest_bin_version)
CURRENT_VER=$(get_current_bin_version)

while true; do
    if [ "$CURRENT_VER" == "$LATEST_VER" ] && [ "$CURRENT_VER" != "None" ]; then
        VER_COLOR=$GREEN
    else
        VER_COLOR=$YELLOW
    fi

    print_header
    echo -e "${BOLD}${WHITE}0)${NC} ${CYAN}📥 Install/Update wstunnel Binary${NC} ${VER_COLOR}[$CURRENT_VER]${NC}"
    echo -e "${BOLD}${WHITE}1)${NC} ${CYAN}⚙️  System Requirements Check/Install${NC} $(check_requirements)"
    echo -e "${BOLD}${WHITE}2)${NC} ${MAGENTA}🆕 Create New Tunnel${NC}"
    echo -e "${BOLD}${WHITE}3)${NC} ${YELLOW}📦 Manage Tunnels & Services${NC}"
    echo -e "${BOLD}${WHITE}4)${NC} ${RED}🗑️  Full Uninstall LemoTunnel${NC}"
    echo -e "${BOLD}${WHITE}5)${NC} ${BOLD}Goodbye 👋🍋${NC}"
    draw_line
    read -p "Option [0-5]: " CHOICE
    case $CHOICE in
        0) 
            install_wstunnel_binary
            CURRENT_VER=$(get_current_bin_version)
            LATEST_VER=$(get_latest_bin_version)
            ;;
        1) install_requirements ;;
        2) setup_new_tunnel ;;
        3) manage_tunnels_menu ;;
        4) 
            systemctl stop lemo-* 2>/dev/null
            fuser -k -n tcp $BIN_PATH 2>/dev/null
            rm -f ${SERVICE_PATH}/lemo-*.service
            rm -f "$BIN_PATH"
            systemctl daemon-reload
            echo -e "${GREEN}Full removal complete.${NC}"; sleep 2 
            CURRENT_VER="None"
            ;;
        5) echo -e "${GREEN}Goodbye 👋🍋${NC}"; break ;;
        *) echo -e "${RED}Invalid!${NC}"; sleep 1 ;;
    esac
done
