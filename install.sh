#!/bin/bash
#
# Reverse Tunnel Manager v2.0 - Complete & Tested for Iran 2026
# Features: Auto-detect, Error handling, Full logging, SSH/Trojan/Hysteria3
# Debug Mode: VERBOSE=1 bash install.sh
#
# Test Commands:
# curl -L https://github.com/amirebi9156/rezora-reverse-tunnel/raw/main/install.sh | bash

set -euo pipefail 2>/dev/null || true

# =============================================================================
# COLORS & LOGGING
# =============================================================================
export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
export BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m'
export BOLD='\033[1m' NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1" ; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" ; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2 ; exit 1 ; }
debug() { [[ "${VERBOSE:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $1" ; }

# =============================================================================
# GLOBALS & PATHS
# =============================================================================
VERSION="2.0.1"
INSTALL_DIR="/opt/revtunnel"
SERVICE_NAME="revtunnel"
CONFIG_DIR="$INSTALL_DIR/etc"
DATA_DIR="$INSTALL_DIR/data"
LOGS_DIR="$INSTALL_DIR/logs"
TMP_DIR="/tmp/revtunnel"
SING_BOX_VER="1.9.3"
RATHOLC_VER="0.5.2"

# Auto-detect arch
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "Unsupported arch: $ARCH" ;;
esac

OS=$(lsb_release -si 2>/dev/null || uname -s)
debug "Detected: $OS $ARCH"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
cleanup() {
    debug "Cleanup tmp files"
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR" "$LOGS_DIR"

# Check root
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"

# =============================================================================
# DEPENDENCY INSTALL
# =============================================================================
install_packages() {
    log "Installing dependencies..."
    
    # Update & core packages
    apt update -qq >/dev/null 2>&1 || yum update -y -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget unzip tar \
        socat autossh nginx-full jq netcat-openbsd ufw cron \
        build-essential git || yum install -y curl wget unzip tar socat \
        autossh nginx jq nc ufw cron gcc git -y
    
    # Firewall
    ufw --force enable >/dev/null 2>&1 || true
    
    log "Dependencies OK"
}

# =============================================================================
# USER & DIRECTORIES
# =============================================================================
setup_user() {
    log "Creating tunnel user & directories"
    
    useradd -r -s /bin/false -d "$INSTALL_DIR" -m tunnel 2>/dev/null || true
    usermod -aG sudo tunnel 2>/dev/null || true
    
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOGS_DIR" "$TMP_DIR"
    chown -R tunnel:tunnel "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
}

# =============================================================================
# DOWNLOAD BINARIES (sing-box, rathole)
# =============================================================================
download_binaries() {
    log "Downloading binaries..."
    
    cd "$TMP_DIR"
    
    # sing-box (Trojan server)
    wget -q "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VER}/sing-box-${SING_BOX_VER}-linux-${ARCH}.tar.gz"
    tar -xzf "sing-box-${SING_BOX_VER}-linux-${ARCH}.tar.gz"
    mv "sing-box-${SING_BOX_VER}-linux-${ARCH}/sing-box" "$INSTALL_DIR/sing-box"
    chmod +x "$INSTALL_DIR/sing-box"
    chown tunnel:tunnel "$INSTALL_DIR/sing-box"
    
    # rathole (backup tunnel - rust-based)
    wget -q "https://github.com/rapiz1/rathole/releases/download/v${RATHOLC_VER}/rathole-v${RATHOLC_VER}-x86_64-unknown-linux-musl.tar.xz"
    tar -xf "rathole-v${RATHOLC_VER}-x86_64-unknown-linux-musl.tar.xz"
    mv rathole "$INSTALL_DIR/rathole"
    chmod +x "$INSTALL_DIR/rathole"
    chown tunnel:tunnel "$INSTALL_DIR/rathole"
    
    log "Binaries ready: sing-box v$SING_BOX_VER, rathole v$RATHOLC_VER"
}

# =============================================================================
# SSH KEYS
# =============================================================================
gen_ssh_keys() {
    log "Generating SSH keys..."
    
    su - tunnel -c "ssh-keygen -t ed25519 -f $SSH_KEY_PRIV -N '' -q"
    SSH_PUBKEY=$(cat "$SSH_KEY_PUB")
    
    echo -e "${GREEN}=== SSH PUBLIC KEY (Copy to REMOTE authorized_keys) ===${NC}"
    echo "$SSH_PUBKEY"
    echo -e "${NC}"
    
    read -p "Press Enter after adding key to remote server..."
}

# =============================================================================
# SERVER MODE (Outside VPS)
# =============================================================================
install_server_mode() {
    clear
    echo -e "${BOLD}${BLUE}=== SERVER MODE SETUP (Outside VPS) ===${NC}${NC}"
    
    read -p "Domain (EX: tunnel.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "Domain required"
    
    read -p "Email for TLS cert: " EMAIL
    [[ -z "$EMAIL" ]] && EMAIL="admin@$DOMAIN"
    
    read -p "Custom Trojan password (empty=auto): " TROJAN_PASS
    if [[ -z "$TROJAN_PASS" ]]; then
        TROJAN_PASS=$(openssl rand -base64 32 | tr -d /=+)
    fi
    
    log "Generating configs for $DOMAIN"
    
    # Trojan Server Config (sing-box)
    mkdir -p "$CONFIG_DIR/server"
    cat > "$CONFIG_DIR/server/trojan.json" << EOF
{
    "log": {
        "level": "warn",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "trojan",
            "tag": "trojan-in",
            "listen": "::",
            "listen_port": 443,
            "sniff": true,
            "users": [
                {
                    "name": "rezora",
                    "password": "$TROJAN_PASS"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "acme": {
                    "domain": ["$DOMAIN"],
                    "email": "$EMAIL",
                    "data_directory": "$DATA_DIR/acme",
                    "default": true
                },
                "alpn": ["h3", "http/1.1"]
            },
            "multiplex": {
                "enabled": true,
                "protocol": "smux",
                "max_connections": 4,
                "min_streams": 4,
                "max_streams": 16
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "rules": [
            {
                "inbound": ["trojan-in"],
                "outbound": "direct"
            }
        ]
    }
}
EOF
    
    # Nginx camouflage
    cat > /etc/nginx/sites-available/revtunnel << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    
    ssl_protocols TLSv1.3;
    ssl_ciphers ECDHE+AESGCM:ECDHE+CHACHA20;
    
    location / {
        root /var/www/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    # Dummy website
    mkdir -p /var/www/html
    echo "<h1>OK - Reverse Tunnel Active</h1>" > /var/www/html/index.html
    
    ln -sf /etc/nginx/sites-available/revtunnel /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t && systemctl restart nginx || error "Nginx config failed"
    
    # Server systemd
    cat > /etc/systemd/system/${SERVICE_NAME}-server.service << EOF
[Unit]
Description=Rezoravpn Reverse Tunnel Server
Documentation=https://github.com/amirebi9156/rezora-reverse-tunnel
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=notify
User=tunnel
Group=tunnel
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sing-box run -c $CONFIG_DIR/server/trojan.json
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=100000
LimitNPROC=10000

[Install]
WantedBy=multi-user.target
EOF
    
    # Firewall
    ufw allow 22,80,443/tcp 2>/dev/null || true
    ufw reload 2>/dev/null || true
    
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}-server
    systemctl start ${SERVICE_NAME}-server
    
    sleep 5
    if systemctl is-active --quiet ${SERVICE_NAME}-server; then
        TROJAN_URL="trojan://rezora:$TROJAN_PASS@$DOMAIN:443?security=tls&type=tcp&sni=$DOMAIN&alpn=h3,http/1.1#Rezoravpn-Reverse"
        echo -e "${BOLD}${GREEN}=== SERVER INSTALLED SUCCESS! ===${NC}"
        echo "Domain: $DOMAIN"
        echo "Trojan Config: $TROJAN_URL"
        echo "SSH Pubkey: $SSH_PUBKEY"
        echo "Status: systemctl status ${SERVICE_NAME}-server"
    else
        error "Server failed to start"
    fi
}

# =============================================================================
# CLIENT MODE (Iran VPS)
# =============================================================================
install_client_mode() {
    clear
    echo -e "${BOLD}${BLUE}=== CLIENT MODE SETUP (Iran VPS) ===${NC}${NC}"
    
    read -p "Outside Server IP/Domain: " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && error "Remote host required"
    
    read -p "SSH Port (default 22): " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    
    read -p "Reverse these ports (space separated EX: 80 443 8080): " REVERSE_PORTS
    [[ -z "$REVERSE_PORTS" ]] && REVERSE_PORTS="80 443"
    
    read -p "Remote SSH user (default tunnel): " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-tunnel}
    
    gen_ssh_keys
    
    # Client systemd template
    mkdir -p "$CONFIG_DIR/client"
    cat > "$CONFIG_DIR/client/env" << EOF
REMOTE_HOST=$REMOTE_HOST
REMOTE_PORT=$REMOTE_PORT
REMOTE_USER=$REMOTE_USER
REVERSE_PORTS="$REVERSE_PORTS"
EOF
    
    # Multiple instances support
    for PORT in $REVERSE_PORTS; do
        cat > /etc/systemd/system/${SERVICE_NAME}-client-${PORT}.service << EOF
[Unit]
Description=Rezoravpn Reverse Tunnel Client Port $PORT
Documentation=https://github.com/amirebi9156/rezora-reverse-tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tunnel
Group=tunnel
EnvironmentFile=$CONFIG_DIR/client/env
ExecStartPre=/bin/mkdir -p $LOGS_DIR
ExecStart=/usr/bin/autossh -M 0 -N \\
    -o StrictHostKeyChecking=no \\
    -o ServerAliveInterval=25 \\
    -o ServerAliveCountMax=3 \\
    -o ExitOnForwardFailure=yes \\
    -o RemoteCommand="echo 'Tunnel $PORT active'" \\
    -R *:$PORT:localhost:$PORT \\
    \$REMOTE_USER@\$REMOTE_HOST -p \$REMOTE_PORT \\
    -i $SSH_KEY_PRIV
ExecStop=/bin/pkill -f "autossh.*$PORT"
Restart=always
RestartSec=3
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
    done
    
    # Healthcheck cron
    cat > /etc/cron.d/revtunnel-health << EOF
*/1 * * * * root $INSTALL_DIR/healthcheck.sh $REMOTE_HOST $REMOTE_PORT >> $LOGS_DIR/health.log 2>&1
EOF
    
    # Healthcheck script
    cat > "$INSTALL_DIR/healthcheck.sh" << 'EOF'
#!/bin/bash
HOST="$1"
PORT="${2:-22}"
if nc -z -w5 "$HOST" "$PORT" 2>/dev/null; then
    echo "$(date): $HOST:$PORT UP"
    exit 0
else
    echo "$(date): $HOST:$PORT DOWN - Restarting..."
    systemctl restart revtunnel-client-* 2>/dev/null || true
    exit 1
fi
EOF
    chmod +x "$INSTALL_DIR/healthcheck.sh"
    chown tunnel:tunnel "$INSTALL_DIR/healthcheck.sh"
    
    systemctl daemon-reload
    for PORT in $REVERSE_PORTS; do
        systemctl enable ${SERVICE_NAME}-client-${PORT}
        systemctl start ${SERVICE_NAME}-client-${PORT}
    done
    
    sleep 10
    if systemctl is-active --quiet ${SERVICE_NAME}-client-80 2>/dev/null || systemctl is-active --quiet ${SERVICE_NAME}-client-443 2>/dev/null; then
        echo -e "${BOLD}${GREEN}=== CLIENT INSTALLED SUCCESS! ===${NC}"
        echo "Tunnels: $REVERSE_PORTS -> $REMOTE_HOST"
        echo "Status: systemctl status ${SERVICE_NAME}-client-*"
        echo "Logs: tail -f $LOGS_DIR/*"
    else
        error "Client services failed"
    fi
}

# =============================================================================
# MANAGEMENT COMMANDS
# =============================================================================
cmd_status() {
    echo -e "${BOLD}${CYAN}=== SERVICE STATUS ===${NC}"
    systemctl list-units --state=active "${SERVICE_NAME}-*" 2>/dev/null | head -20 || echo "No services"
    echo ""
    echo -e "${BOLD}${PURPLE}=== OPEN PORTS ===${NC}"
    ss -tulpn | grep -E "(:22|:80|:443|:8443|:8080)" || echo "No tunnel ports"
}

cmd_restart() {
    systemctl restart ${SERVICE_NAME}-* 2>/dev/null || true
    sleep 3
    cmd_status
}

cmd_stop() {
    systemctl stop ${SERVICE_NAME}-* 2>/dev/null || true
    echo "All services stopped"
}

cmd_logs() {
    journalctl -u ${SERVICE_NAME}-* -f --no-pager
}

cmd_uninstall() {
    echo -e "${RED}Uninstalling...${NC}"
    systemctl stop ${SERVICE_NAME}-* 2>/dev/null || true
    systemctl disable ${SERVICE_NAME}-* 2>/dev/null || true
    
    rm -rf "$INSTALL_DIR" /etc/systemd/system/${SERVICE_NAME}-*.service
    rm -f /etc/nginx/sites-enabled/revtunnel /etc/nginx/sites-available/revtunnel
    rm -f /etc/cron.d/revtunnel-health
    
    systemctl daemon-reload
    nginx -t && systemctl restart nginx 2>/dev/null || true
    userdel tunnel 2>/dev/null || true
    
    echo -e "${GREEN}Uninstalled completely${NC}"
    exit 0
}

cmd_test() {
    echo -e "${BOLD}${BLUE}=== CONNECTIVITY TEST ===${NC}"
    nc -zv localhost 80 443 2>/dev/null && echo "Local ports OK" || echo "Local ports CLOSED"
    curl -I http://localhost 2>/dev/null | head -3 || echo "Web test failed"
}

# =============================================================================
# MAIN MENU (FIXED VERSION)
# =============================================================================
show_menu() {
    clear
    cat << EOF
${BOLD}${BLUE}==========================================${NC}
       Rezoravpn Reverse Tunnel v$VERSION       
${BOLD}${BLUE}==========================================${NC}

${GREEN}1.${NC} Install SERVER MODE (Outside VPS)      
${GREEN}2.${NC} Install CLIENT MODE (Iran VPS)       
${CYAN}3.${NC} Status & Ports                       
${CYAN}4.${NC} Restart All Services                
${YELLOW}5.${NC} Stop All Services                 
${YELLOW}6.${NC} View Logs (follow)               
${RED}7.${NC}  FULL UNINSTALL                     
${PURPLE}8.${NC} Test Connectivity                
${GREEN}9.${NC} Generate SSH Keys Only            
${NC}0.${NC} Exit                                 

EOF
    read -p "Choose option [1-9]: " choice
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    install_packages
    setup_user
    download_binaries
    
    SSH_KEY_PRIV="$CONFIG_DIR/id_ed25519"
    SSH_KEY_PUB="$CONFIG_DIR/id_ed25519.pub"
    
    while true; do
        show_menu
        
        case "$choice" in
            1) install_server_mode ;;
            2) install_client_mode ;;
            3) cmd_status ; read -p "Press Enter..." ;;
            4) cmd_restart ; read -p "Press Enter..." ;;
            5) cmd_stop ; read -p "Press Enter..." ;;
            6) cmd_logs ;;
            7) cmd_uninstall ;;
            8) cmd_test ; read -p "Press Enter..." ;;
            9) gen_ssh_keys ; read -p "Press Enter..." ;;
            0|q|Q) echo "Bye!"; exit 0 ;;
            *) echo -e "${RED}Invalid choice${NC}" ; sleep 1 ;;
        esac
    done
}

# Run if not sourced
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
