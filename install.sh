#!/bin/bash

# Reverse Tunnel Manager - Optimized for Iran DPI 2026
# Features: Trojan TLS Server + autossh Reverse + systemd
# Author: Perplexity AI - Based on best practices [web:19][web:22][web:23]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
INSTALL_DIR="/opt/reverse-tunnel"
SERVICE_NAME="reverse-tunnel"
CONFIG_DIR="$INSTALL_DIR/config"
LOGS_DIR="$INSTALL_DIR/logs"
TROJAN_CONFIG="$CONFIG_DIR/trojan-server.json"
SSH_KEY_PUB="$CONFIG_DIR/id_rsa.pub"
SSH_KEY_PRIV="$CONFIG_DIR/id_rsa"

echo -e "${BLUE}=== Reverse Tunnel Manager v1.0 ===${NC}"
echo -e "${YELLOW}Optimized for Iran-Outbound Reverse Tunneling${NC}"

# Detect OS
if [[ ! $(uname -s) =~ ^(Linux)$ ]]; then
    echo -e "${RED}Only Linux supported${NC}"
    exit 1
fi

# Install dependencies
install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    apt update -qq
    apt install -y curl wget unzip socat autossh nginx-full acme.sh jq ufw systemd-journal-remote || {
        apt install -y curl wget unzip socat autossh nginx-full certbot python3-certbot-nginx jq ufw
    }
}

# Create directories and user
setup_dirs() {
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOGS_DIR"
    useradd -r -s /bin/false -d "$INSTALL_DIR" -m tunnel || true
    chown -R tunnel:tunnel "$INSTALL_DIR"
}

# Generate SSH keys
gen_ssh_keys() {
    if [[ ! -f "$SSH_KEY_PRIV" ]]; then
        echo -e "${BLUE}Generating SSH keys...${NC}"
        sudo -u tunnel ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PRIV" -N "" -q
        chown tunnel:tunnel "$SSH_KEY_PRIV" "$SSH_KEY_PUB"
    fi
    echo -e "${GREEN}SSH Public Key:${NC} $(cat "$SSH_KEY_PUB")"
}

# Main menu
show_menu() {
    clear
    echo -e "${BLUE}=== Reverse Tunnel Menu ===${NC}"
    echo "1. Install Server Mode (Outside VPS)"
    echo "2. Install Client Mode (Iran VPS)"
    echo "3. Status"
    echo "4. Restart"
    echo "5. Stop"
    echo "6. Uninstall"
    echo "7. Logs"
    echo "8. Edit Config"
    echo "q. Quit"
    read -p "Choose: " choice
}

# Server Mode (Outside)
install_server() {
    echo -e "${BLUE}=== Server Mode Setup ===${NC}"
    read -p "Domain (e.g. tunnel.example.com): " DOMAIN
    read -p "Email for LetsEncrypt: " EMAIL
    read -p "Trojan Password (auto-gen if empty): " TROJAN_PASS

    if [[ -z "$TROJAN_PASS" ]]; then
        TROJAN_PASS=$(openssl rand -base64 32)
        echo -e "${GREEN}Generated Password: $TROJAN_PASS${NC}"
    fi

    # Trojan config with sing-box style [web:22][web:30]
    cat > "$TROJAN_CONFIG" << EOF
{
    "log": {"level": "warn"},
    "inbounds": [{
        "type": "trojan",
        "listen": "::",
        "listen_port": 443,
        "users": [{"name": "user", "password": "$TROJAN_PASS"}],
        "tls": {
            "enabled": true,
            "acme": {
                "domain": "$DOMAIN",
                "email": "$EMAIL"
            }
        },
        "multiplex": {"enabled": true, "max_streams": 2}
    }],
    "outbounds": [{"type": "direct"}]
}
EOF

    # Nginx fallback for camouflage
    cat > /etc/nginx/sites-available/tunnel << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    location / { return 200 "OK"; }
}
EOF
    ln -sf /etc/nginx/sites-available/tunnel /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # Sing-box binary (download latest)
    wget -O /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-$(uname -m)-linux.tar.gz
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    install -m 755 /tmp/sing-box-$(uname -m)-linux/sing-box "$INSTALL_DIR/sing-box"
    chown tunnel:tunnel "$INSTALL_DIR/sing-box"

    # Systemd service for server
    cat > /etc/systemd/system/$SERVICE_NAME-server.service << EOF
[Unit]
Description=Reverse Tunnel Trojan Server
After=network-online.target nginx.service

[Service]
User=tunnel
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sing-box run -c $TROJAN_CONFIG
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # UFW
    ufw allow 22,80,443/tcp

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME-server
    systemctl start $SERVICE_NAME-server

    echo -e "${GREEN}Server installed!${NC}"
    echo "Trojan URL: trojan://$TROJAN_PASS@$DOMAIN:443?security=tls&type=tcp&sni=$DOMAIN#Reverse-Tunnel"
    echo "SSH Pubkey for Iran client: $(cat $SSH_KEY_PUB)"
}

# Client Mode (Iran)
install_client() {
    echo -e "${BLUE}=== Client Mode Setup (Iran VPS) ===${NC}"
    read -p "Outside Server IP/Domain: " REMOTE_HOST
    read -p "Outside SSH Port (default 22): " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "Local Ports to Reverse (e.g. 80,443,8080): " LOCAL_PORTS
    read -p "Remote User (default tunnel): " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-tunnel}

    # Copy SSH key to remote (expect pubkey pasted)
    gen_ssh_keys
    read -p "Paste Outside SSH Pubkey or press Enter if already added: " dummy

    # Reverse ports template
    REVERSE_CMD="ServerAliveInterval=30 ServerAliveCountMax=3"
    for PORT in $LOCAL_PORTS; do
        REVERSE_CMD="$REVERSE_CMD -R $PORT:localhost:$PORT"
    done

    # Autossh config
    cat > "$CONFIG_DIR/autossh.conf" << EOF
AUTOSSH_GATETIME=0
AUTOSSH_PORT=0
REMOTE_HOST=$REMOTE_HOST
REMOTE_PORT=$REMOTE_PORT
REMOTE_USER=$REMOTE_USER
REVERSE_CMD="$REVERSE_CMD"
EOF

    # Systemd client service [web:23][web:27]
    cat > /etc/systemd/system/$SERVICE_NAME-client@.service << EOF
[Unit]
Description=Reverse Tunnel Client to %i
After=network-online.target
Wants=network-online.target

[Service]
User=tunnel
Group=tunnel
EnvironmentFile=$CONFIG_DIR/autossh.conf
ExecStart=/usr/bin/autossh -M 0 -o "StrictHostKeyChecking=no" -o "$REVERSE_CMD" %i
ExecStop=/usr/bin/pkill -f "autossh.*%i"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Healthcheck script
    cat > "$INSTALL_DIR/healthcheck.sh" << 'EOF'
#!/bin/bash
HOST="$1"
PORT="${2:-22}"
nc -z -w3 "$HOST" "$PORT" 2>/dev/null && echo "UP" || echo "DOWN"
EOF
    chmod +x "$INSTALL_DIR/healthcheck.sh"

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME-client@$REMOTE_HOST
    systemctl start $SERVICE_NAME-client@$REMOTE_HOST

    echo -e "${GREEN}Client installed! Tunnel: $LOCAL_PORTS <- $REMOTE_HOST${NC}"
}

# Status
status() {
    systemctl status $SERVICE_NAME-server $SERVICE_NAME-client@* --no-pager 2>/dev/null | grep -E "(Active|Loaded)" || echo "No services found"
    ss -tulpn | grep -E "(:443|:22|:80)"
}

# Other functions
case_cmd() {
    case "$1" in
        restart) systemctl restart $SERVICE_NAME-*-client@* $SERVICE_NAME-server 2>/dev/null || true ;;
        stop) systemctl stop $SERVICE_NAME-*-client@* $SERVICE_NAME-server 2>/dev/null || true ;;
        uninstall)
            systemctl stop $SERVICE_NAME-*-client@* $SERVICE_NAME-server 2>/dev/null || true
            systemctl disable $SERVICE_NAME-*-client@* $SERVICE_NAME-server 2>/dev/null || true
            rm -rf "$INSTALL_DIR" /etc/systemd/system/$SERVICE_NAME*.service /etc/nginx/sites-enabled/tunnel
            systemctl daemon-reload
            nginx -t && systemctl restart nginx
            userdel tunnel || true
            echo -e "${GREEN}Uninstalled${NC}"
            ;;
        logs) journalctl -u $SERVICE_NAME-* -f ;;
        edit) nano "$CONFIG_DIR"/* ;;
    esac
}

# Main loop
install_deps
setup_dirs

while true; do
    show_menu
    case "$choice" in
        1) install_server ;;
        2) install_client ;;
        3) status ;;
        4) case_cmd restart ;;
        5) case_cmd stop ;;
        6) case_cmd uninstall && exit 0 ;;
        7) case_cmd logs ;;
        8) case_cmd edit ;;
        q|Q) exit 0 ;;
        *) echo "Invalid" ;;
    esac
    read -p "Press Enter to continue..."
done
