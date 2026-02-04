#!/bin/bash
#===============================================================================
# 🚀 Rezoravpn Reverse Tunnel Installer v1.2
# 🔒 تونل ریورس SSH پایدار برای ایران-خارج (DPI Resistant)
# 💻 Developed by Perplexity for @Rezoravpn
#===============================================================================

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# 🎨 رنگ‌ها و استایل‌ها
# ═══════════════════════════════════════════════════════════════════════════════
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
PURPLE='\033[0;35m' CYAN='\033[0;36m' WHITE='\033[1;37m' NC='\033[0m'

BOLD=$(tput bold) NORMAL=$(tput sgr0)

# ═══════════════════════════════════════════════════════════════════════════════
# 🎨 لوگو و بنر
# ═══════════════════════════════════════════════════════════════════════════════
logo() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════════════════╗
║                           🚀 REZORAVPN TUNNEL                               ║
║                     🔒 تونل ریورس آسان و پایدار                            ║
║                           💻 v1.2 | Feb 2026                               ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}${NORMAL}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🔧 توابع کمکی
# ═══════════════════════════════════════════════════════════════════════════════
print_success() { echo -e "${GREEN}${BOLD}✅ $1${NC}${NORMAL}"; }
print_warning() { echo -e "${YELLOW}${BOLD}⚠️  $1${NC}${NORMAL}"; }
print_error() { echo -e "${RED}${BOLD}❌ $1${NC}${NORMAL}"; }
print_info() { echo -e "${CYAN}${BOLD}ℹ️  $1${NC}${NORMAL}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "نیاز به root/sudo"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# 📦 نصب وابستگی‌ها
# ═══════════════════════════════════════════════════════════════════════════════
install_deps() {
    print_info "نصب وابستگی‌ها..."
    apt update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt install -y -qq \
        openssh-server autossh curl netcat-openbsd jq ufw \
        >/dev/null 2>&1 || {
        print_error "خطا در نصب بسته‌ها"
        exit 1
    }
    print_success "وابستگی‌ها نصب شد"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🔐 تنظیمات SSH برای سرور خارج
# ═══════════════════════════════════════════════════════════════════════════════
setup_ssh_remote() {
    print_info "تنظیم SSH برای reverse tunnel..."
    
    # Backup اصلی config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    cat > /etc/ssh/sshd_config.d/50-rezora.conf << 'EOF'
# Rezoravpn Reverse Tunnel Settings
PermitRootLogin yes
PasswordAuthentication yes
GatewayPorts clientspecified
AllowTcpForwarding yes
PermitTunnel yes
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
UseDNS no
AcceptEnv LANG LC_*
MaxSessions 50
MaxStartups 50:30:100
EOF
    
    systemctl restart ssh >/dev/null 2>&1
    systemctl enable ssh >/dev/null 2>&1
    
    # UFW
    ufw allow ssh >/dev/null 2>&1 || true
    print_success "SSH برای reverse tunnel آماده شد"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 💾 ذخیره کانفیگ کلاینت ایران
# ═══════════════════════════════════════════════════════════════════════════════
save_client_config() {
    mkdir -p /etc/rezora
    cat > /etc/rezora/config << EOF
REMOTE_IP="$REMOTE_IP"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_USER="${REMOTE_USER:-root}"
PORTS="$PORTS"
TUNNEL_NAME="$TUNNEL_NAME"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🛠️ systemd service template
# ═══════════════════════════════════════════════════════════════════════════════
create_systemd_service() {
    cat > /etc/systemd/system/rezora-reverse@.service << 'EOF'
[Unit]
Description=Rezoravpn Reverse Tunnel - Port %i
Documentation=https://github.com/YOURUSERNAME/rezora-reverse-tunnel
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root
EnvironmentFile=/etc/rezora/config
ExecStartPre=/bin/bash -c 'source /etc/rezora/config && echo "Starting tunnel to %%i@$${REMOTE_IP}:$${REMOTE_PORT}"'
ExecStart=/usr/bin/autossh -M 20000 -N -T \
    -o "ServerAliveInterval=60" \
    -o "ServerAliveCountMax=3" \
    -o "ExitOnForwardFailure=yes" \
    -o "StrictHostKeyChecking=no" \
    -o "UserKnownHostsFile=/dev/null" \
    -o "BatchMode=yes" \
    -o "ConnectTimeout=10" \
    -p ${REMOTE_PORT} \
    -R 0.0.0.0:%i:localhost:%i \
    ${REMOTE_USER}@${REMOTE_IP}
ExecStop=/bin/bash -c 'pkill -f "autossh.*%i"'
Restart=always
RestartSec=30
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🎛️ منوی اصلی
# ═══════════════════════════════════════════════════════════════════════════════
main_menu() {
    logo
    echo -e "${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    ${BOLD}گزینه‌های موجود:${NORMAL}                     ║${NC}"
    echo -e "${WHITE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}  1${NC} ${YELLOW}نصب سرور خارج (Listener)${NC}"
    echo -e "${GREEN}  2${NC} ${YELLOW}نصب کلاینت ایران (Reverse Tunnel)${NC}"
    echo -e "${GREEN}  3${NC} ${CYAN}وضعیت سرویس‌ها${NC}"
    echo -e "${GREEN}  4${NC} ${CYAN}مشاهده لاگ realtime${NC}"
    echo -e "${GREEN}  5${NC} ${PURPLE}تست اتصال پورت${NC}"
    echo -e "${GREEN}  6${NC} ${PURPLE}ریستارت همه سرویس‌ها${NC}"
    echo -e "${GREEN}  7${NC} ${RED}حذف کامل${NC}"
    echo -e "${GREEN}  8${NC} ${YELLOW}بک‌آپ کانفیگ${NC}"
    echo -e "${GREEN}  0${NC} ${RED}خروج${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    read -p "$(print_info 'انتخاب کنید [0-8]: ')" choice
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1️⃣ نصب سرور خارج
# ═══════════════════════════════════════════════════════════════════════════════
install_remote() {
    logo
    print_info "نصب سرور خارج (Listener)..."
    install_deps
    setup_ssh_remote
    
    print_success "🎉 سرور خارج آماده شد!"
    print_warning "🔥 نکات مهم:"
    echo "  • پورت‌های 22,443,8443,2083 را در فایروال باز کنید"
    echo "  • از کلاینت ایران استفاده کنید"
    echo "  • ssh root@YOUR_IP تست کنید"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2️⃣ نصب کلاینت ایران
# ═══════════════════════════════════════════════════════════════════════════════
install_client() {
    logo
    print_info "نصب کلاینت ایران (Reverse Tunnel)..."
    install_deps
    
    # Input validation
    while true; do
        read -p "🌐 IP سرور خارج: " REMOTE_IP
        [[ $REMOTE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        print_error "IP معتبر وارد کنید"
    done
    
    read -p "🔌 پورت SSH خارج (22): " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    
    read -p "👤 یوزر (root): " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}
    
    read -p "🔑 پسورد: " -s REMOTE_PASS
    echo
    
    echo "🌉 پورت‌های تونل (فاصله‌دار، Enter برای پیش‌فرض):"
    echo "پیشنهاد: 443 8443 2083 8080"
    read -r -a PORTS
    
    if [[ ${#PORTS[@]} -eq 0 ]]; then
        PORTS=(443 8443 2083 8080)
    fi
    
    read -p "📛 نام سرویس (rezora1): " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-rezora1}
    
    save_client_config
    create_systemd_service
    
    # Start services
    for PORT in "${PORTS[@]}"; do
        systemctl enable "rezora-reverse@${PORT}" >/dev/null 2>&1
        systemctl start "rezora-reverse@${PORT}" >/dev/null 2>&1
    done
    
    print_success "🎉 کلاینت ایران نصب شد!"
    echo -e "${YELLOW}✅ سرویس‌ها فعال:${NC} ${PORTS[*]}"
    print_warning "🔥 تست کنید: nc -zv localhost 443"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3️⃣ وضعیت سرویس‌ها
# ═══════════════════════════════════════════════════════════════════════════════
status_services() {
    logo
    print_info "وضعیت سرویس‌ها:"
    echo
    systemctl list-units --state=active,failed | grep rezora || print_warning "هیچ سرویسی فعال نیست"
    echo
    systemctl status rezora-reverse@* --no-pager -l 2>/dev/null | head -30 || print_warning "سرویس پیدا نشد"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4️⃣ لاگ realtime
# ═══════════════════════════════════════════════════════════════════════════════
view_logs() {
    logo
    print_info "لاگ realtime (Ctrl+C برای خروج)"
    echo
    journalctl -u rezora-reverse@* -f --no-pager -l
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5️⃣ تست اتصال
# ═══════════════════════════════════════════════════════════════════════════════
test_connection() {
    logo
    print_info "تست اتصال پورت"
    read -p "پورت (443): " TEST_PORT
    TEST_PORT=${TEST_PORT:-443}
    
    if nc -z -w3 localhost "$TEST_PORT" 2>/dev/null; then
        print_success "✅ پورت $TEST_PORT باز و آماده"
    else
        print_error "❌ پورت $TEST_PORT بسته یا timeout"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6️⃣ ریستارت همه
# ═══════════════════════════════════════════════════════════════════════════════
restart_all() {
    logo
    print_info "ریستارت همه سرویس‌ها..."
    systemctl restart rezora-reverse@* 2>/dev/null || true
    sleep 3
    systemctl status rezora-reverse@* --no-pager -l 2>/dev/null | head -20
    print_success "✅ ریستارت کامل شد"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 7️⃣ حذف کامل
# ═══════════════════════════════════════════════════════════════════════════════
uninstall_all() {
    logo
    print_warning "⚠️  حذف کامل (آیا مطمئنید؟ y/N)"
    read -r -n 1 confirm
    echo
    if [[ $confirm =~ ^[Yy]$ ]]; then
        print_info "توقف سرویس‌ها..."
        systemctl stop rezora-reverse@* 2>/dev/null || true
        systemctl disable rezora-reverse@* 2>/dev/null || true
        
        rm -f /etc/systemd/system/rezora-reverse@.service
        rm -rf /etc/rezora /etc/ssh/sshd_config.d/50-rezora.conf
        
        systemctl daemon-reload
        print_success "🗑️  حذف کامل شد!"
    else
        print_warning "لغو شد"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# 8️⃣ بک‌آپ کانفیگ
# ═══════════════════════════════════════════════════════════════════════════════
backup_config() {
    logo
    print_info "بک‌آپ کانفیگ..."
    BACKUP_FILE="/root/rezora-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$BACKUP_FILE" /etc/rezora /etc/systemd/system/rezora* 2>/dev/null || true
    print_success "✅ بک‌آپ: $BACKUP_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 🚀 حلقه اصلی
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    while true; do
        check_root
        main_menu
        
        case $choice in
            1) install_remote ;;
            2) install_client ;;
            3) status_services ;;
            4) view_logs ;;
            5) test_connection ;;
            6) restart_all ;;
            7) uninstall_all ;;
            8) backup_config ;;
            0|q|Q) print_success "خروج... 👋"; exit 0 ;;
            *) print_error "انتخاب نامعتبر! [0-8]" ;;
        esac
        
        echo
        print_info "⏎ Enter برای ادامه..."
        read -r
    done
}

# 🔥 اجرا
main "$@"
