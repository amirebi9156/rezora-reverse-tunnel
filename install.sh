#!/bin/bash
#===============================================================================
# Rezoravpn Reverse Tunnel Installer v1.3 - Production Ready
# SSH Reverse Tunnel for Iran-Out (DPI Resistant)
# Single file - No dependencies - Works everywhere
#===============================================================================

set -euo pipefail

# Colors (Terminal safe)
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
CYAN='\033[0;36m' NC='\033[0m'

BOLD=$(tput bold 2>/dev/null || true) NORM=$(tput sgr0 2>/dev/null || true)

# Logo (ASCII only)
logo() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  _____                        _   _      _            "
    echo " / ____|                      | | | |    | |           "
    echo "| |  __  ___ _ __   ___ _ __ | |_| |__  | |_ ___  ___ "
    echo "| | |_ |/ _ \\ '_ \\ / _ \\ '_ \\| __| '_ \\ | __/ _ \\/ __|"
    echo "| |__| |  __/ | | |  __/ | | | |_| | | | | ||  __/\\__ \\"
    echo " \\_____|\\___|_| |_|\\___|_| |_|\\__|_| |_|  \\__\\___||___/"
    echo "                       Rezoravpn Reverse Tunnel v1.3   "
    echo -e "${NC}${NORM}"
}

success() { echo -e "${GREEN}${BOLD}OK: $1${NC}${NORM}"; }
warn()   { echo -e "${YELLOW}${BOLD}WARN: $1${NC}${NORM}"; }
error()  { echo -e "${RED}${BOLD}ERROR: $1${NC}${NORM}"; }
info()   { echo -e "${CYAN}${BOLD}INFO: $1${NC}${NORM}"; }

# Root check
root_check() {
    [[ $EUID -ne 0 ]] && { error "Run as root/sudo"; exit 1; }
}

# Install minimal deps
deps_install() {
    info "Installing dependencies..."
    apt update -qq 2>/dev/null || yum update -q 2>/dev/null || true
    apt install -y -qq openssh-server autossh curl nc jq 2>/dev/null || \
    yum install -y -q openssh-server autossh curl nc bind-utils jq 2>/dev/null || \
    dnf install -y -q openssh-server autossh curl nc bind-utils jq 2>/dev/null || \
    { error "Package manager failed"; exit 1; }
    success "Dependencies OK"
}

# SSH config for REMOTE server
ssh_remote_setup() {
    info "Configuring SSH for reverse tunnel..."
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-rezora.conf << 'EOF'
# Rezoravpn Reverse Tunnel - Optimized for Iran
PermitRootLogin yes
PasswordAuthentication yes
GatewayPorts clientspecified
AllowTcpForwarding global
PermitTunnel yes
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
UseDNS no
AcceptEnv *
MaxSessions 100
MaxStartups 100:30:200
EOF
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null
    success "SSH remote ready"
}

# Save client config
client_config_save() {
    mkdir -p /etc/rezora
    cat > /etc/rezora/env << EOF
REMOTE_IP="$REMOTE_IP"
REMOTE_PORT="$REMOTE_PORT"
REMOTE_USER="$REMOTE_USER"
PORTS="$PORTS"
EOF
}

# Systemd service template
systemd_template() {
    cat > /etc/systemd/system/rezora-tunnel@.service << 'EOF'
[Unit]
Description=Rezoravpn Reverse SSH Tunnel - Port %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/rezora/env
ExecStartPre=/bin/sh -c 'echo "Tunnel %%i -> ${REMOTE_IP}:${REMOTE_PORT}"'
ExecStart=/usr/bin/autossh -M 0 -N -T -q \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o BatchMode=no \
  -o ConnectTimeout=10 \
  -p ${REMOTE_PORT} \
  -R 0.0.0.0:%i:127.0.0.1:%i \
  ${REMOTE_USER}@${REMOTE_IP}
ExecStop=/bin/pkill -f "autossh.*%i"
Restart=always
RestartSec=20
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# Menu
show_menu() {
    logo
    cat << EOF

[1] Install REMOTE server (Outside Iran)
[2] Install CLIENT server (Iran VPS)  
[3] Status check
[4] Live logs
[5] Test ports
[6] Restart all
[7] Full uninstall
[0] Exit

EOF
    read -p "Choice (0-7): " opt
}

# 1. REMOTE install
opt_remote() {
    logo
    info "REMOTE server setup (Outside Iran)..."
    deps_install
    ssh_remote_setup
    success "REMOTE ready! Use option 2 on Iran VPS"
    warn "Open ports: ufw allow 22,443,8443"
}

# 2. CLIENT install  
opt_client() {
    logo
    info "CLIENT setup (Iran VPS)..."
    deps_install
    
    # Inputs with validation
    while [[ ! $REMOTE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
        read -p "REMOTE IP: " REMOTE_IP
    done
    
    read -p "REMOTE SSH port [22]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "REMOTE user [root]: " REMOTE_USER; REMOTE_USER=${REMOTE_USER:-root}
    read -s -p "REMOTE password: " REMOTE_PASS; echo
    
    echo "Tunnel ports (space separated, default 443 8443):"
    read -ra PORTS; [[ ${#PORTS[@]} -eq 0 ]] && PORTS=(443 8443 2083 8080)
    
    client_config_save
    systemd_template
    
    # Enable & start
    for p in "${PORTS[@]}"; do
        systemctl enable "rezora-tunnel@${p}"
        systemctl start "rezora-tunnel@${p}"
    done
    
    success "CLIENT ready! Ports: ${PORTS[*]}"
    info "Test: ssh root@IRAN_IP -p443"
}

# 3. Status
opt_status() {
    logo
    info "Service status:"
    systemctl list-units "rezora-tunnel@*" --state=active,failed 2>/dev/null || true
    echo
    systemctl status "rezora-tunnel@*" --no-pager -l 2>/dev/null | head -25 || true
}

# 4. Logs
opt_logs() {
    logo
    info "Live logs (Ctrl+C to exit)"
    journalctl -u rezora-tunnel@* -f --no-pager -l
}

# 5. Test
opt_test() {
    logo
    read -p "Test port [443]: " port; port=${port:-443}
    if nc -z -w 3 127.0.0.1 "$port" 2>/dev/null; then
        success "Port $port: OPEN"
    else
        error "Port $port: CLOSED/TIMEOUT"
    fi
}

# 6. Restart
opt_restart() {
    logo
    info "Restarting all tunnels..."
    systemctl restart rezora-tunnel@* 2>/dev/null || true
    sleep 2
    systemctl status rezora-tunnel@* --no-pager 2>/dev/null | head -20
    success "Restart complete"
}

# 7. Uninstall
opt_uninstall() {
    logo
    echo -n "Full uninstall? (y/N): "; read -r yn
    [[ $yn =~ [Yy] ]] || { warn "Cancelled"; return; }
    
    systemctl stop rezora-tunnel@* 2>/dev/null || true
    systemctl disable rezora-tunnel@* 2>/dev/null || true
    rm -f /etc/systemd/system/rezora-tunnel@.service
    rm -rf /etc/rezora /etc/ssh/sshd_config.d/99-rezora.conf
    systemctl daemon-reload
    success "Clean uninstall complete"
}

# Main loop
main_loop() {
    while true; do
        root_check
        show_menu
        
        case $opt in
            1) opt_remote ;;
            2) opt_client ;;
            3) opt_status ;;
            4) opt_logs ;;
            5) opt_test ;;
            6) opt_restart ;;
            7) opt_uninstall ;;
            0|q|Q) success "Bye!"; exit 0 ;;
            *) error "Invalid: 0-7";;
        esac
        
        echo; info "Press Enter..."; read -r
    done
}

# Run!
main_loop "$@"
