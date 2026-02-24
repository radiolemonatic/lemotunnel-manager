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

validate_name() {
    local name=$1
    if [[ -z "$name" ]]; then
        echo -e "${RED}❌ Name cannot be empty!${NC}"
        return 1
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}❌ Invalid Name! Only English letters, numbers, and underscores are allowed.${NC}"
        return 1
    fi
    return 0
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
    local schedule=$2
    crontab -l 2>/dev/null | grep -v "lemo-$name" | crontab -
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

# --- PROXY TEST ---
test_proxy() {
    local name=$1
    local svc_file="${SERVICE_PATH}/lemo-${name}.service"
    
    clear; print_banner; draw_line
    echo -e "${BOLD}${CYAN}🧪 PROXY TEST: ${WHITE}$name${NC}"
    draw_line
    
    # Check if it's a client tunnel
    if grep -q "server" "$svc_file"; then
        echo -e "${RED}❌ This is a SERVER tunnel. Proxy test is for CLIENT tunnels only.${NC}"
        sleep 2
        return
    fi
    
    # Check if it's SOCKS5
    if ! grep -q "socks5://" "$svc_file"; then
        echo -e "${RED}❌ This is not a SOCKS5 tunnel. Proxy test only works with SOCKS5.${NC}"
        sleep 2
        return
    fi
    
    # Extract SOCKS5 port
    local socks_port=$(grep -oE 'socks5://0.0.0.0:[0-9]+' "$svc_file" | grep -oE '[0-9]+$')
    
    if [ -z "$socks_port" ]; then
        echo -e "${RED}❌ Could not detect SOCKS5 port.${NC}"
        sleep 2
        return
    fi
    
    echo -e "${CYAN}📡 Testing SOCKS5 proxy on port: ${WHITE}$socks_port${NC}"
    draw_line
    
    # Test if port is listening
    if ! nc -z -w 1 127.0.0.1 "$socks_port" 2>/dev/null; then
        echo -e "${RED}❌ SOCKS5 port $socks_port is not listening!${NC}"
        echo -e "${YELLOW}Make sure the tunnel is running.${NC}"
        sleep 3
        return
    fi
    
    echo -e "${GREEN}✅ SOCKS5 port is listening${NC}\n"
    echo -e "${YELLOW}🌐 Fetching IP information...${NC}\n"
    
    # Fetch IP info through proxy with timeout
    local response=$(timeout 10 curl -s -x socks5h://127.0.0.1:$socks_port https://ipinfo.io/json 2>/dev/null)
    
    if [ -z "$response" ]; then
        echo -e "${RED}❌ Failed to connect through proxy!${NC}"
        echo -e "${YELLOW}Possible reasons:${NC}"
        echo -e "  • Server tunnel is not running or misconfigured"
        echo -e "  • Network connectivity issue"
        echo -e "  • Firewall blocking the connection"
        sleep 3
        return
    fi
    
    # Parse JSON response
    local ip=$(echo "$response" | jq -r '.ip // "N/A"')
    local city=$(echo "$response" | jq -r '.city // "N/A"')
    local region=$(echo "$response" | jq -r '.region // "N/A"')
    local country=$(echo "$response" | jq -r '.country // "N/A"')
    local org=$(echo "$response" | jq -r '.org // "N/A"')
    local timezone=$(echo "$response" | jq -r '.timezone // "N/A"')
    
    # Country flag emoji mapping
    local flag=""
    case $country in
        US) flag="🇺🇸" ;;
        GB) flag="🇬🇧" ;;
        DE) flag="🇩🇪" ;;
        FR) flag="🇫🇷" ;;
        NL) flag="🇳🇱" ;;
        CA) flag="🇨🇦" ;;
        JP) flag="🇯🇵" ;;
        SG) flag="🇸🇬" ;;
        AU) flag="🇦🇺" ;;
        SE) flag="🇸🇪" ;;
        FI) flag="🇫🇮" ;;
        NO) flag="🇳🇴" ;;
        DK) flag="🇩🇰" ;;
        CH) flag="🇨🇭" ;;
        AT) flag="🇦🇹" ;;
        BE) flag="🇧🇪" ;;
        IT) flag="🇮🇹" ;;
        ES) flag="🇪🇸" ;;
        PL) flag="🇵🇱" ;;
        CZ) flag="🇨🇿" ;;
        RU) flag="🇷🇺" ;;
        TR) flag="🇹🇷" ;;
        AE) flag="🇦🇪" ;;
        IN) flag="🇮🇳" ;;
        CN) flag="🇨🇳" ;;
        KR) flag="🇰🇷" ;;
        BR) flag="🇧🇷" ;;
        MX) flag="🇲🇽" ;;
        AR) flag="🇦🇷" ;;
        IR) flag="🇮🇷" ;;
        *) flag="🌍" ;;
    esac
    
    # Measure ping (latency)
    echo -e "${YELLOW}📊 Measuring latency...${NC}\n"
    local start_time=$(date +%s%3N)
    timeout 5 curl -s -x socks5h://127.0.0.1:$socks_port https://www.google.com > /dev/null 2>&1
    local end_time=$(date +%s%3N)
    local ping=$((end_time - start_time))
    
    # Display results
    draw_line
    echo -e "${BOLD}${GREEN}✅ PROXY CONNECTION SUCCESSFUL${NC}\n"
    echo -e "${BOLD}${CYAN}📍 Location:${NC}"
    echo -e "   ${flag} ${BOLD}${WHITE}${country}${NC} - ${city}, ${region}"
    echo -e ""
    echo -e "${BOLD}${CYAN}🌐 Network Info:${NC}"
    echo -e "   IP Address: ${WHITE}${ip}${NC}"
    echo -e "   ISP/Org: ${WHITE}${org}${NC}"
    echo -e "   Timezone: ${WHITE}${timezone}${NC}"
    echo -e ""
    echo -e "${BOLD}${CYAN}⚡ Performance:${NC}"
    
    if [ $ping -lt 100 ]; then
        echo -e "   Latency: ${GREEN}${ping}ms (Excellent)${NC}"
    elif [ $ping -lt 200 ]; then
        echo -e "   Latency: ${YELLOW}${ping}ms (Good)${NC}"
    elif [ $ping -lt 500 ]; then
        echo -e "   Latency: ${YELLOW}${ping}ms (Fair)${NC}"
    else
        echo -e "   Latency: ${RED}${ping}ms (Slow)${NC}"
    fi
    
    draw_line
    echo -e "${CYAN}💡 Test command used:${NC}"
    echo -e "   ${WHITE}curl -x socks5h://127.0.0.1:${socks_port} https://ipinfo.io${NC}"
    draw_line
    
    read -p "Press Enter to continue..."
}

# --- MONITORING LOGIC ---
run_monitor() {
    local name=$1
    local svc_file="${SERVICE_PATH}/lemo-${name}.service"
    clear; print_banner; draw_line
    echo -e "${BOLD}${MAGENTA}🔍 REAL-TIME MONITORING: ${WHITE}$name${NC}"
    draw_line
    (
        set +m
        local stop_monitor=false
        cleanup_monitor() { stop_monitor=true; pkill -P $$ 2>/dev/null; echo -e "\n${YELLOW}Monitoring stopped.${NC}"; sleep 1; }
        trap cleanup_monitor SIGINT
        
        if grep -q "server" "$svc_file"; then
            local port=$(grep -oE '127.0.0.1:[0-9]+' "$svc_file" | head -1 | cut -d':' -f2)
            echo -e "${CYAN}📡 Role: SERVER | Listening on Port: $port${NC}"
            echo -e "${YELLOW}Press [q] or [Ctrl+C] to return to menu${NC}"
            draw_line
            while [ "$stop_monitor" = false ]; do
                { timeout 2 nc -l -p "$port" 2>/dev/null | grep "lemotunnel"; } & disown
                read -t 2 -n 1 key
                [[ "$key" == "q" ]] && { cleanup_monitor; break; }
            done
        else
            local port=$(grep -oE '0.0.0.0:[0-9]+' "$svc_file" | head -1 | cut -d':' -f2)
            
            # Check if it's SOCKS5
            if grep -q "socks5://" "$svc_file"; then
                echo -e "${CYAN}📡 Role: CLIENT (IRAN) | SOCKS5 Proxy on Port: $port${NC}"
                echo -e "${YELLOW}Press [q] or [Ctrl+C] to return to menu${NC}"
                draw_line
                echo -e "${GREEN}SOCKS5 proxy is running on 0.0.0.0:$port${NC}"
                echo -e "${CYAN}You can test it with: curl -x socks5h://127.0.0.1:$port https://google.com${NC}"
                draw_line
                while [ "$stop_monitor" = false ]; do
                    if nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; then
                        echo -e "${GREEN}[$(date +%T)]${NC} SOCKS5 Port $port is listening ✅"
                    else
                        echo -e "${RED}[$(date +%T)]${NC} SOCKS5 Port $port is NOT listening ❌"
                    fi
                    read -t 3 -n 1 key
                    [[ "$key" == "q" ]] && { cleanup_monitor; break; }
                done
            else
                echo -e "${CYAN}📡 Role: CLIENT (IRAN) | Forwarding to Local Port: $port${NC}"
                draw_line
                while [ "$stop_monitor" = false ]; do
                    if grep -q "tcp://" "$svc_file"; then
                        echo "lemotunnel working" | nc -w 1 127.0.0.1 "$port" 2>/dev/null
                        echo -e "${GREEN}[$(date +%T)]${NC} Heartbeat Sent (TCP)"
                    elif grep -q "udp://" "$svc_file"; then
                        echo "lemotunnel working" | nc -u -w 1 127.0.0.1 "$port" 2>/dev/null
                        echo -e "${BLUE}[$(date +%T)]${NC} Heartbeat Sent (UDP)"
                    fi
                    read -t 3 -n 1 key
                    [[ "$key" == "q" ]] && { cleanup_monitor; break; }
                done
            fi
        fi
    )
}

run_reverse_monitor() {
    local name=$1
    local svc_file="${SERVICE_PATH}/lemo-${name}.service"
    clear; print_banner; draw_line
    echo -e "${BOLD}${MAGENTA}🔍 REVERSE MONITORING (Server → Iran): ${WHITE}$name${NC}"
    draw_line
    
    if grep -q "server" "$svc_file"; then
        echo -e "${RED}❌ This is a SERVER tunnel. Reverse monitoring is for CLIENT tunnels only.${NC}"
        sleep 2
        return
    fi
    
    local remote_ip=$(grep -oE 'ws://[^:]+' "$svc_file" | sed 's|ws://||')
    local remote_port=$(grep -oE 'ws://[^:]+:[0-9]+' "$svc_file" | grep -oE '[0-9]+$')
    local dest_port=$(grep -oE '127.0.0.1:[0-9]+' "$svc_file" | head -1 | cut -d':' -f2)
    
    echo -e "${CYAN}📡 Testing connection from SERVER ($remote_ip:$remote_port) to IRAN (port $dest_port)${NC}"
    echo -e "${YELLOW}Press [q] or [Ctrl+C] to return to menu${NC}"
    draw_line
    
    (
        set +m
        local stop_monitor=false
        cleanup_monitor() { stop_monitor=true; pkill -P $$ 2>/dev/null; echo -e "\n${YELLOW}Monitoring stopped.${NC}"; sleep 1; }
        trap cleanup_monitor SIGINT
        
        while [ "$stop_monitor" = false ]; do
            if nc -z -w 2 127.0.0.1 "$dest_port" 2>/dev/null; then
                echo -e "${GREEN}[$(date +%T)]${NC} Port $dest_port is reachable ✅"
            else
                echo -e "${RED}[$(date +%T)]${NC} Port $dest_port is NOT reachable ❌"
            fi
            read -t 3 -n 1 key
            [[ "$key" == "q" ]] && { cleanup_monitor; break; }
        done
    )
}

# --- TUNNEL MANAGEMENT ---
list_tunnels() {
    local tunnels=$(ls ${SERVICE_PATH}/lemo-*.service 2>/dev/null)
    [[ -z "$tunnels" ]] && { echo -e "${YELLOW}⚠️  No Tunnels found.${NC}"; return 1; }
    
    echo -e "${BOLD}${CYAN}╔══════╤══════════════╤══════════╤══════════╤═══════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║ ID   │ Name         │ Type     │ Status   │ Details       ║${NC}"
    echo -e "${BOLD}${CYAN}╟──────┼──────────────┼──────────┼──────────┼───────────────╢${NC}"
    
    local count=1
    for t in $tunnels; do
        local name=$(basename "$t" .service | sed 's/lemo-//')
        local is_active=false
        (systemctl is-active --quiet "lemo-$name" || pgrep -f "lemo-$name" > /dev/null) && is_active=true
        
        local type="Unknown"
        grep -q "server" "$t" && type="Outside" || type="Iran"
        
        # We use standard ASCII characters for status to ensure perfect alignment
        local status_text=" Off    "
        local status_color="$RED"
        if [ "$is_active" = true ]; then
            status_text=" Active "
            status_color="$GREEN"
        fi

        # Format everything to fixed widths
        printf "${BOLD}${CYAN}║${NC} %-4s │ %-12s │ %-8s │ ${status_color}%-8s${NC} │ %-13s ${BOLD}${CYAN}║${NC}\n" \
            "$count" "$name" "$type" "$status_text" "Select to see"
        
        eval "tunnel_$count=\"$name\""
        count=$((count + 1))
    done
    echo -e "${BOLD}${CYAN}╚══════╧══════════════╧══════════╧══════════╧═══════════════╝${NC}"
    return 0
}

get_detailed_status() {
    local name=$1
    local svc_file="${SERVICE_PATH}/lemo-${name}.service"
    local status_line=$(systemctl status "lemo-$name" | grep "Active:" | xargs)
    
    # Extract Secret Key
    local secret=$(grep -oE 'path-prefix "[^"]+' "$svc_file" | sed 's/path-prefix "//')
    
    # Extract WS Port
    local ws_port=""
    if grep -q "server" "$svc_file"; then
        ws_port=$(grep -oE 'ws://0.0.0.0:[0-9]+' "$svc_file" | grep -oE '[0-9]+$')
    else
        ws_port=$(grep -oE 'ws://[^:]+:[0-9]+' "$svc_file" | grep -oE '[0-9]+$')
    fi
    
    # Extract Protocol
    local protocol=""
    local has_tcp=$(grep -q "tcp://" "$svc_file" && echo "yes" || echo "no")
    local has_udp=$(grep -q "udp://" "$svc_file" && echo "yes" || echo "no")
    local has_socks5=$(grep -q "socks5://" "$svc_file" && echo "yes" || echo "no")
    
    if [[ "$has_socks5" == "yes" ]]; then
        protocol="${GREEN}SOCKS5${NC}"
    elif [[ "$has_tcp" == "yes" && "$has_udp" == "yes" ]]; then
        protocol="${BLUE}TCP${NC} + ${MAGENTA}UDP${NC}"
    elif [[ "$has_tcp" == "yes" ]]; then
        protocol="${BLUE}TCP${NC}"
    elif [[ "$has_udp" == "yes" ]]; then
        protocol="${MAGENTA}UDP${NC}"
    else
        protocol="${YELLOW}N/A${NC}"
    fi
    
    # Extract Forwarding Info
    local forward_info=""
    if grep -q "server" "$svc_file"; then
        # Fixed port extraction for server mode
        local target=$(grep "restrict-to" "$svc_file" | sed 's/.*127.0.0.1://' | awk '{print $1}')
        forward_info="${CYAN}Restricted to Local Port: ${WHITE}${target:-Unknown}${NC}"
    else
        # Check for SOCKS5 first
        local socks5_map=$(grep "socks5://" "$svc_file" | grep -oE 'socks5://[^ ]+')
        if [[ ! -z "$socks5_map" ]]; then
            local socks_port=$(echo "$socks5_map" | grep -oE ':[0-9]+' | head -1 | sed 's/://')
            local has_auth=$(echo "$socks5_map" | grep -q "login=" && echo "yes" || echo "no")
            if [[ "$has_auth" == "yes" ]]; then
                forward_info="${GREEN}[SOCKS5] ${WHITE}Port: ${socks_port} (Auth Enabled)${NC}"
            else
                forward_info="${GREEN}[SOCKS5] ${WHITE}Port: ${socks_port}${NC}"
            fi
        else
            # Extract multiple mappings using sed for better reliability
            local tcp_map=$(grep "tcp://" "$svc_file" | grep -oE 'tcp://[^ ]+')
            local udp_map=$(grep "udp://" "$svc_file" | grep -oE 'udp://[^ ]+')
            
            if [[ ! -z "$tcp_map" ]]; then
                local formatted_tcp=$(echo "$tcp_map" | sed 's|tcp://0.0.0.0:\([0-9]*\):127.0.0.1:\([0-9]*\)|\1 ➔ \2|')
                forward_info+="${BLUE}[TCP] ${WHITE}${formatted_tcp}${NC} "
            fi
            if [[ ! -z "$udp_map" ]]; then
                local formatted_udp=$(echo "$udp_map" | sed 's|udp://0.0.0.0:\([0-9]*\):127.0.0.1:\([0-9]*\)|\1 ➔ \2|')
                forward_info+="${MAGENTA}[UDP] ${WHITE}${formatted_udp}${NC}"
            fi
            [[ -z "$forward_info" ]] && forward_info="${RED}No Port Map Found${NC}"
        fi
    fi

    if systemctl is-active --quiet "lemo-$name"; then
        echo -e "${BOLD}Status: ${GREEN}● ACTIVE${NC} (${status_line#Active: })"
    else
        echo -e "${BOLD}Status: ${RED}○ INACTIVE / ERROR${NC}"
    fi
    echo -e "${BOLD}Secret Key: ${CYAN}${secret:-Unknown}${NC}"
    echo -e "${BOLD}WS Port: ${YELLOW}${ws_port:-Unknown}${NC}"
    echo -e "${BOLD}Protocol: ${NC}$protocol"
    echo -e "${BOLD}Forwarding: ${NC}$forward_info"
}

setup_new_tunnel() {
    local TNAME=""
    while true; do
        print_header
        echo -ne "${BOLD}${YELLOW}Tunnel Name (English only): ${NC}"
        read TNAME
        if validate_name "$TNAME"; then
            if [[ -f "${SERVICE_PATH}/lemo-${TNAME}.service" ]]; then
                echo -e "${RED}❌ Tunnel with this name already exists!${NC}"
                sleep 2
            else
                break
            fi
        else
            sleep 2
        fi
    done
    
    echo -e "1) ${BOLD}${CYAN}Iran (Client)${NC}\n2) ${BOLD}${MAGENTA}Outside (Server)${NC}"
    echo -ne "${BOLD}${YELLOW}Type Choice: ${NC}"; read TTYPE
    
    draw_line
    echo -ne "${BOLD}${YELLOW}Secret Key (SAME on both): ${NC}"; read SKEY
    draw_line

    if [ "$TTYPE" == "1" ]; then
        echo -ne "${BOLD}${WHITE}Remote IP: ${NC}"; read RIP
        echo -ne "${BOLD}${WHITE}WS Port: ${NC}"; read RWPORT
        
        # Ask for tunnel mode
        echo -e "1) ${BOLD}Port Forward (TCP/UDP)${NC}\n2) ${BOLD}SOCKS5 Proxy${NC}"
        echo -ne "${BOLD}${YELLOW}Tunnel Mode: ${NC}"; read TUNNEL_MODE
        
        local CMD=""
        if [ "$TUNNEL_MODE" == "2" ]; then
            # SOCKS5 mode
            echo -ne "${BOLD}${WHITE}SOCKS5 Port (Iran): ${NC}"; read SOCKS_PORT
            echo -ne "${BOLD}${YELLOW}Enable Authentication? (y/n): ${NC}"; read USE_AUTH
            
            if [[ "$USE_AUTH" == "y" || "$USE_AUTH" == "Y" ]]; then
                echo -ne "${BOLD}${WHITE}Username: ${NC}"; read SOCKS_USER
                echo -ne "${BOLD}${WHITE}Password: ${NC}"; read -s SOCKS_PASS
                echo ""
                CMD="--local-to-remote socks5://0.0.0.0:${SOCKS_PORT}?login=${SOCKS_USER}&password=${SOCKS_PASS} "
            else
                CMD="--local-to-remote socks5://0.0.0.0:${SOCKS_PORT} "
            fi
        else
            # Port forward mode
            echo -ne "${BOLD}${WHITE}Local Port (Iran): ${NC}"; read LPORT
            echo -ne "${BOLD}${WHITE}Destination Port: ${NC}"; read RPORT
            echo -e "1) ${BOLD}TCP${NC}\n2) ${BOLD}UDP${NC}\n3) ${BOLD}Both${NC}"
            echo -ne "${BOLD}${YELLOW}Protocol: ${NC}"; read PROT
            [[ "$PROT" == "1" || "$PROT" == "3" ]] && CMD+="--local-to-remote tcp://0.0.0.0:${LPORT}:127.0.0.1:${RPORT} "
            [[ "$PROT" == "2" || "$PROT" == "3" ]] && CMD+="--local-to-remote udp://0.0.0.0:${LPORT}:127.0.0.1:${RPORT} "
        fi
        
        cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel: ${TNAME}
After=network.target
[Service]
ExecStart=${BIN_PATH} client --http-upgrade-path-prefix "${SKEY}" $CMD ws://${RIP}:${RWPORT}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    else
        echo -ne "${BOLD}${WHITE}WS Port (Server): ${NC}"; read RWPORT
        
        # Ask if this server is for SOCKS5 or port forward
        echo -e "1) ${BOLD}Port Forward (Restrict to specific port)${NC}\n2) ${BOLD}SOCKS5 Server (No restrictions)${NC}"
        echo -ne "${BOLD}${YELLOW}Server Mode: ${NC}"; read SERVER_MODE
        
        if [ "$SERVER_MODE" == "2" ]; then
            # SOCKS5 server - no restrictions
            cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel: ${TNAME} (Server)
After=network.target
[Service]
ExecStart=${BIN_PATH} server --restrict-http-upgrade-path-prefix "${SKEY}" ws://0.0.0.0:${RWPORT}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        else
            # Port forward - restrict to specific port
            echo -ne "${BOLD}${WHITE}Forward Port (e.g. 22): ${NC}"; read FPORT
            cat <<EOF > "${SERVICE_PATH}/lemo-${TNAME}.service"
[Unit]
Description=LemoTunnel: ${TNAME} (Server)
After=network.target
[Service]
ExecStart=${BIN_PATH} server --restrict-http-upgrade-path-prefix "${SKEY}" --restrict-to 127.0.0.1:${FPORT} ws://0.0.0.0:${RWPORT}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        fi
    fi
    systemctl daemon-reload && systemctl enable "lemo-${TNAME}" && systemctl start "lemo-${TNAME}"
    update_cron_job "$TNAME" "0 * * * *"
    echo -e "${GREEN}✅ Tunnel created successfully!${NC}"
    echo -ne "${YELLOW}Press Enter to manage this tunnel...${NC}"
    read
    
    # Go directly to tunnel management menu
    while true; do
        clear; print_banner; draw_line; echo -e "${BOLD}${YELLOW}🛠️  Tunnel: $TNAME${NC}"
        get_detailed_status "$TNAME"
        get_cron_info "$TNAME"
        draw_line
        echo -e "1) ${GREEN}▶️ Start${NC}\n2) ${YELLOW}🔄 Restart${NC}\n3) ${RED}⏹️ Stop${NC}\n4) ${MAGENTA}👁️  Monitor (Live)${NC}\n5) ${BLUE}📝 Logs${NC}\n6) ${CYAN}⏰ Scheduled Restart${NC}\n7) ${CYAN}🧪 Test Proxy (SOCKS5)${NC}\n8) ${WHITE}✏️  Rename Tunnel${NC}\n9) ${WHITE}📝 Edit Config (nano)${NC}\n10) ${MAGENTA}🔄 Reverse Monitor${NC}\n11) ${RED}🗑️ Delete${NC}\n12) 🔙 Back to Main Menu"
        draw_line; echo -ne "${BOLD}${YELLOW}Action: ${NC}"; read T_ACT
        case $T_ACT in
            1) systemctl start "lemo-$TNAME" ;;
            2) systemctl restart "lemo-$TNAME" ;;
            3) systemctl stop "lemo-$TNAME" ;;
            4) run_monitor "$TNAME" ;;
            5) journalctl -u "lemo-$TNAME" -n 50 --no-pager; read -p "Press Enter..." ;;
            6) manage_cron_menu "$TNAME" ;;
            7) test_proxy "$TNAME" ;;
            8) rename_tunnel "$TNAME"; break ;;
            9) edit_tunnel_config "$TNAME" ;;
            10) run_reverse_monitor "$TNAME" ;;
            11) systemctl stop "lemo-$TNAME" && systemctl disable "lemo-$TNAME"
               rm -f "${SERVICE_PATH}/lemo-${TNAME}.service" && systemctl daemon-reload
               remove_cron_job "$TNAME"
               echo -e "${GREEN}Deleted.${NC}"; sleep 1; break ;;
            12) break ;;
        esac
    done
}

rename_tunnel() {
    local old_name=$1
    local new_name=""
    
    while true; do
        echo -ne "${BOLD}${YELLOW}New Tunnel Name: ${NC}"
        read new_name
        if validate_name "$new_name"; then
            if [[ -f "${SERVICE_PATH}/lemo-${new_name}.service" ]]; then
                echo -e "${RED}❌ A tunnel with this name already exists!${NC}"
                sleep 2
            else
                break
            fi
        else
            sleep 2
        fi
    done
    
    systemctl stop "lemo-$old_name"
    systemctl disable "lemo-$old_name"
    
    mv "${SERVICE_PATH}/lemo-${old_name}.service" "${SERVICE_PATH}/lemo-${new_name}.service"
    sed -i "s/Description=LemoTunnel: ${old_name}/Description=LemoTunnel: ${new_name}/" "${SERVICE_PATH}/lemo-${new_name}.service"
    
    local old_cron=$(crontab -l 2>/dev/null | grep "lemo-$old_name")
    if [ ! -z "$old_cron" ]; then
        local schedule=$(echo "$old_cron" | cut -d ' ' -f 1-5)
        remove_cron_job "$old_name"
        update_cron_job "$new_name" "$schedule"
    fi
    
    systemctl daemon-reload
    systemctl enable "lemo-${new_name}"
    systemctl start "lemo-${new_name}"
    
    echo -e "${GREEN}✅ Tunnel renamed from '$old_name' to '$new_name'${NC}"
    sleep 2
}

edit_tunnel_config() {
    local name=$1
    local svc_file="${SERVICE_PATH}/lemo-${name}.service"
    
    systemctl stop "lemo-$name"
    nano "$svc_file"
    
    echo -ne "${BOLD}${YELLOW}Restart tunnel now? (y/n): ${NC}"
    read restart_choice
    if [[ "$restart_choice" == "y" || "$restart_choice" == "Y" ]]; then
        systemctl daemon-reload
        systemctl start "lemo-$name"
        echo -e "${GREEN}✅ Tunnel restarted${NC}"
    else
        echo -e "${YELLOW}⚠️  Remember to restart manually later${NC}"
    fi
    sleep 2
}

manage_tunnels_menu() {
    while true; do
        clear; print_banner; draw_line; list_tunnels || { read -p "Press Enter..."; break; }
        draw_line; echo -ne "${BOLD}${YELLOW}Enter ID (or 'b' to back): ${NC}"; read T_ID
        [[ "$T_ID" == "b" ]] && break
        local T_NAME=$(eval echo \$tunnel_$T_ID)
        [[ -z "$T_NAME" ]] && continue
        while true; do
            clear; print_banner; draw_line; echo -e "${BOLD}${YELLOW}🛠️  Tunnel: $T_NAME${NC}"
            get_detailed_status "$T_NAME"
            get_cron_info "$T_NAME"
            draw_line
            echo -e "1) ${GREEN}▶️ Start${NC}\n2) ${YELLOW}🔄 Restart${NC}\n3) ${RED}⏹️ Stop${NC}\n4) ${MAGENTA}👁️  Monitor (Live)${NC}\n5) ${BLUE}📝 Logs${NC}\n6) ${CYAN}⏰ Scheduled Restart${NC}\n7) ${CYAN}🧪 Test Proxy (SOCKS5)${NC}\n8) ${WHITE}✏️  Rename Tunnel${NC}\n9) ${WHITE}📝 Edit Config (nano)${NC}\n10) ${MAGENTA}🔄 Reverse Monitor${NC}\n11) ${RED}🗑️ Delete${NC}\n12) 🔙 Back"
            draw_line; echo -ne "${BOLD}${YELLOW}Action: ${NC}"; read T_ACT
            case $T_ACT in
                1) systemctl start "lemo-$T_NAME" ;;
                2) systemctl restart "lemo-$T_NAME" ;;
                3) systemctl stop "lemo-$T_NAME" ;;
                4) run_monitor "$T_NAME" ;;
                5) journalctl -u "lemo-$T_NAME" -n 50 --no-pager; read -p "Press Enter..." ;;
                6) manage_cron_menu "$T_NAME" ;;
                7) test_proxy "$T_NAME" ;;
                8) rename_tunnel "$T_NAME"; break ;;
                9) edit_tunnel_config "$T_NAME" ;;
                10) run_reverse_monitor "$T_NAME" ;;
                11) systemctl stop "lemo-$T_NAME" && systemctl disable "lemo-$T_NAME"
                   rm -f "${SERVICE_PATH}/lemo-${T_NAME}.service" && systemctl daemon-reload
                   remove_cron_job "$T_NAME"
                   echo -e "${GREEN}Deleted.${NC}"; sleep 1; break 2 ;;
                12) break ;;
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
    draw_line; echo -ne "${BOLD}${YELLOW}Option: ${NC}"; read CHOICE
    case $CHOICE in
        0) install_wstunnel_binary ;;
        1) install_requirements ;;
        2) setup_new_tunnel ;;
        3) manage_tunnels_menu ;;
        4) systemctl stop lemo-*; rm -f ${SERVICE_PATH}/lemo-*.service; rm -f "$BIN_PATH"; systemctl daemon-reload; crontab -l | grep -v "lemo-" | crontab -; echo "Removed successfully."; sleep 2 ;;
        5) clear; echo -e "${GREEN}${BOLD}👋 Goodbye! Thanks for using LemoTunnel${NC}"; break ;;
    esac
done
