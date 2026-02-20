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
VERSION="1.1.0"

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
    for cmd in curl wget jq gzip unzip fuser nc crontab; do
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
    declare -A pkgs=( ["curl"]="curl" ["wget"]="wget" ["jq"]="jq" ["gzip"]="gzip" ["unzip"]="unzip" ["nc"]="netcat-openbsd" ["fuser"]="psmisc" ["crontab"]="cron" )
    for cmd in "${!pkgs[@]}"; do
        local pkg=${pkgs[$cmd]}
        echo -n "Checking $pkg... "
        if command -v "$cmd" &> /dev/null; then
            echo -e "${GREEN}Already Installed${NC}"
        else
            echo -e "${YELLOW}Installing...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" &> /dev/null
            [[ $? -ne 0 && "$pkg" == "netcat-openbsd" ]] && apt-get install -y netcat-traditional &> /dev/null
            command -v "$cmd" &> /dev/null && echo -e "${GREEN}Success ✅${NC}" || echo -e "${RED}Failed ❌${NC}"
        fi
    done
    systemctl enable cron && systemctl start cron
    echo -e "${GREEN}✅ Check complete.${NC}"
    sleep 2
}

install_wstunnel_binary() {
    print_header
    echo -e "${YELLOW}📥 Downloading & Installing wstunnel Binary...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) WST_ARCH="linux_amd64" ;;
        aarch64) WST_ARCH="linux_arm64" ;;
        *) echo -e "${RED}❌ Unsupported architecture: $ARCH${NC}"; sleep 2; return ;;
    esac
    LATEST_TAG=$(get_latest_bin_version)
    [[ "$LATEST_TAG" == "Check Failed" ]] && { echo -e "${RED}❌ Version check failed.${NC}"; sleep 2; return; }
    VERSION_NUM=${LATEST_TAG#v}
    DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/${LATEST_TAG}/wstunnel_${VERSION_NUM}_${WST_ARCH}.tar.gz"
    wget -qO wstunnel.tar.gz "$DOWNLOAD_URL"
    tar -xvf wstunnel.tar.gz && chmod +x wstunnel && mv -f wstunnel "$BIN_PATH"
    rm -f wstunnel.tar.gz LICENSE README.md 2>/dev/null
    echo -e "${GREEN}✅ Binary $LATEST_TAG installed.${NC}"; sleep 2
}

# --- CRON MANAGEMENT ---

update_cron_job() {
    local name=$1
    local schedule=$2 # e.g. "0 * * * *" for hourly
    
    # Remove existing job for this tunnel
    crontab -l 2>/dev/null | grep -v "lemo-$name" | crontab -
    
    # Add new job
    (crontab -l 2>/dev/null; echo "$schedule systemctl restart lemo-$name #lemo-$name-restart") | crontab -
}

remove_cron_job() {
    local name=$1
    crontab -l 2>/dev/null | grep -v "lemo-$name" | crontab -
}

get_cron_info() {
    local name=$1
    local job=$(crontab -l 2>/dev/null | grep "lemo-$name")
    if [ -z "$job" ]; then
        echo -e "${RED}No Scheduled Restart${NC}"
    else
        local schedule=$(echo "$job" | cut -d ' ' -f 1-5)
        echo -e "${GREEN}Auto-Restart: $schedule${NC}"
    fi
}

manage_cron_menu() {
    local name=$1
    while true; do
        clear; print_banner; draw_line
        echo -e "${BOLD}${YELLOW}⏰ Scheduled Restart: $name${NC}"
        get_cron_info "$name"
        draw_line
        echo -e "1) Every 1 Hour (Default)"
        echo -e "2) Every 6 Hours"
        echo -e "3) Every 12 Hours"
        echo -e "4) Every 24 Hours (Midnight)"
        echo -e "5) Custom Cron Expression"
        echo -e "6) Disable Auto-Restart"
        echo -e "7) 🔙 Back"
        draw_line; read -p "Option: " CRON_OPT
        case $CRON_OPT in
            1) update_cron_job "$name" "0 * * * *"; echo "Updated to Hourly."; sleep 1 ;;
            2) update_cron_job "$name" "0 */6 * * *"; echo "Updated to 6h."; sleep 1 ;;
            3) update_cron_job "$name" "0 */12 * * *"; echo "Updated to 12h."; sleep 1 ;;
            4) update_cron_job "$name" "0 0 * * *"; echo "Updated to Daily."; sleep 1 ;;
            5) read -p "Enter Cron (e.g. */30 * * * *): " CUSTOM; update_cron_job "$name" "$CUSTOM"; sleep 1 ;;
            6) remove_cron_job "$name"; echo "Disabled."; sleep 1 ;;
            7) break ;;
        esac
    done
}

# --- MONITORING LOGIC ---

run_monitor() {
    local name=$1
    local svc_file="${SERVICE_PATH}/lemo-${name}.service"
    clear
    print_banner
    draw_line
    echo -e "${BOLD}${MAGENTA}🔍 REAL-TIME MONITORING: ${WHITE}$name${NC}"
    draw_line
    
    (
        set +m
        local stop_monitor=false
        
        cleanup_monitor() {
            stop_monitor=true
            pkill -P $$ 2>/dev/null
            echo -e "\n${YELLOW}Monitoring stopped.${NC}"
            sleep 1
        }
        
        trap cleanup_monitor SIGINT
        
        if grep -q "server" "$svc_file"; then
            local port=$(grep -oP '127.0.0.1:\K[0-9]+' "$svc_file" | head -1)
            echo -e "${CYAN}📡 Role: SERVER | Listening on Port: $port${NC}"
            echo -e "${YELLOW}Press [q] or [Ctrl+C] to return to menu${NC}"
            draw_line
            
            while [ "$stop_monitor" = false ]; do
                { timeout 2 nc -l -p "$port" 2>/dev/null | grep "lemotunnel"; } & disown
                { timeout 2 nc -u -l -p "$port" 2>/dev/null | grep "lemotunnel"; } & disown
                
                read -t 2 -n 1 key
                [[ "$key" == "q" ]] && { cleanup_monitor; break; }
            done
        else
            local port=$(grep -oP '0.0.0.0:\K[0-9]+' "$svc_file" | head -1)
            echo -e "${CYAN}📡 Role: CLIENT (IRAN) | Forwarding to Local Port: $port${NC}"
            echo -e "${YELLOW}Press [q] or [Ctrl+C] to return to menu${NC}"
            draw_line
            
            while [ "$stop_monitor" = false ]; do
                if grep -q "tcp://" "$svc_file"; then
                    echo "lemotunnel working" | nc -w 1 127.0.0.1 "$port" 2>/dev/null
                    echo -e "${GREEN}[$(date +%T)]${NC} Heartbeat Sent"
                elif grep -q "udp://" "$svc_file"; then
                    echo "lemotunnel working" | nc -u -w 1 127.0.0.1 "$port" 2>/dev/null
                    echo -e "${BLUE}[$(date +%T)]${NC} Heartbeat Sent"
                fi
                
                read -t 3 -n 1 key
                [[ "$key" == "q" ]] && { cleanup_monitor; break; }
            done
        fi
    )
}

# --- TUNNEL MANAGEMENT ---

list_tunnels() {
    local tunnels=$(ls ${SERVICE_PATH}/lemo-*.service 2>/dev/null)
    [[ -z "$tunnels" ]] && { echo -e "${YELLOW}⚠️  No Tunnels found.${NC}"; return 1; }
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║ ID   | Name         | Type    | Status   | Details       ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    local count=1
    for t in $tunnels; do
        local name=$(basename "$t" .service | sed 's/lemo-//')
        local status_icon="🔴"
        (systemctl is-active --quiet "lemo-$name" || pgrep -f "lemo-$name" > /dev/null) && status_icon="🟢"
        local type="Unknown"
        grep -q "server" "$t" && type="Outside " || type="Iran    "
        printf "${BOLD}${CYAN}║${NC} %-4s | %-12s | %-7s |    %-5s | %-13s ${BOLD}${CYAN}║${NC}\n" "$count" "$name" "$type" "$status_icon" "Select to see"
        eval "tunnel_$count=\"$name\""
        count=$((count + 1))
    done
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    return 0
}

setup_new_tunnel() {
    print_header
    read -p "Tunnel Name: " TNAME
    [[ -f "${SERVICE_PATH}/lemo-${TNAME}.service" ]] && { echo -e "${RED}❌ Exists!${NC}"; sleep 2; return; }
    echo -e "1) Iran (Client)\n2) Outside (Server)"
    read -p "Type: " TTYPE
    if [ "$TTYPE" == "1" ]; then
        read -p "Remote IP: " RIP; read -p "WS Port: " RWPORT; read -p "Local Port: " LPORT; read -p "Dest Port: " RPORT
        echo -e "1) TCP\n2) UDP\n3) Both"
        read -p "Prot: " PROT
        local CMD=""
        [[ "$PROT" == "1" || "$PROT" == "3" ]] && CMD+="--local-to-remote tcp://0.0.0.0:${LPORT}:127.0.0.1:${RPORT} "
        [[ "$PROT" == "2" || "$PROT" == "3" ]] && CMD+="--local-to-remote udp://0.0.0.0:${LPORT}:127.0.0.1:${RPORT} "
        cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel: ${TNAME}
After=network.target
[Service]
ExecStart=${BIN_PATH} client $CMD ws://${RIP}:${RWPORT}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    else
        read -p "WS Port: " RWPORT; read -p "Forward Port (e.g. 22): " FPORT
        cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel: ${TNAME}
After=network.target
[Service]
ExecStart=${BIN_PATH} server --restrict-to 127.0.0.1:${FPORT} ws://0.0.0.0:${RWPORT}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload && systemctl enable "lemo-${TNAME}" && systemctl start "lemo-${TNAME}"
    
    # Set default 1h restart cron
    update_cron_job "$TNAME" "0 * * * *"
    
    echo -e "${GREEN}✅ Done! Hourly restart scheduled.${NC}"; sleep 2
}

manage_tunnels_menu() {
    while true; do
        clear; print_banner; draw_line; list_tunnels || { read -p "Press Enter..."; break; }
        draw_line; read -p "Enter ID (or 'b'): " T_ID
        [[ "$T_ID" == "b" ]] && break
        local T_NAME=$(eval echo \$tunnel_$T_ID)
        [[ -z "$T_NAME" ]] && continue
        while true; do
            clear; print_banner; draw_line; echo -e "${BOLD}${YELLOW}🛠️  Tunnel: $T_NAME${NC}"
            get_cron_info "$T_NAME"
            draw_line
            echo -e "1) ${GREEN}▶️ Start${NC}\n2) ${YELLOW}🔄 Restart${NC}\n3) ${RED}⏹️ Stop${NC}\n4) ${MAGENTA}👁️  Monitor (Live)${NC}\n5) ${BLUE}📝 Logs${NC}\n6) ${CYAN}⏰ Scheduled Restart${NC}\n7) ${RED}🗑️ Delete${NC}\n8) 🔙 Back"
            draw_line; read -p "Action: " T_ACT
            case $T_ACT in
                1) systemctl start "lemo-$T_NAME" ;;
                2) systemctl restart "lemo-$T_NAME" ;;
                3) systemctl stop "lemo-$T_NAME" ;;
                4) run_monitor "$T_NAME" ;;
                5) journalctl -u "lemo-$T_NAME" -n 50 --no-pager; read -p "Enter..." ;;
                6) manage_cron_menu "$T_NAME" ;;
                7) systemctl stop "lemo-$T_NAME" && systemctl disable "lemo-$T_NAME"
                   rm -f "${SERVICE_PATH}/lemo-${T_NAME}.service" && systemctl daemon-reload
                   remove_cron_job "$T_NAME"
                   echo -e "${GREEN}Deleted.${NC}"; sleep 1; break 2 ;;
                8) break ;;
            esac
        done
    done
}

print_header() { clear; print_banner; draw_line; echo -e "${BOLD} 🛠️  Core: $(get_core_status)"; draw_line; }

# --- MAIN ---
check_root
while true; do
    print_header
    echo -e "0) 📥 Install wstunnel\n1) ⚙️  Requirements $(check_requirements)\n2) 🆕 New Tunnel\n3) 📦 Manage/Monitor\n4) 🗑️  Uninstall\n5) 🚪 Exit"
    draw_line; read -p "Option: " CHOICE
    case $CHOICE in
        0) install_wstunnel_binary ;;
        1) install_requirements ;;
        2) setup_new_tunnel ;;
        3) manage_tunnels_menu ;;
        4) systemctl stop lemo-*; rm -f ${SERVICE_PATH}/lemo-*.service; rm -f "$BIN_PATH"; systemctl daemon-reload; crontab -l | grep -v "lemo-" | crontab -; echo "Removed."; sleep 2 ;;
        5) break ;;
    esac
done
