#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ================================
# Raga Backhaul Installer / Uninstaller
# ================================

# Default settings
: "${BACKHAUL_REPO:=Musixal/Backhaul}"
: "${BACKHAUL_VERSION:=v0.7.2}"
: "${PLATFORM:=linux}"
: "${DESTDIR:=/root/backhaul}"
: "${TLS_CERT:=/root/cert.crt}"
: "${TLS_KEY:=/root/private.key}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
RESET='\033[0m'
ARROW='=>'
CHECKMARK='✔'

log() { printf "${GREEN}[+] %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}[!] %s${RESET}\n" "$1"; }
err() { printf "${RED}[ERROR] %s${RESET}\n" "$1"; exit 1; }

# ---------------------------
# Utility functions
# ---------------------------

detect_arch() {
    local raw_arch
    raw_arch="$(uname -m)"
    case "$raw_arch" in
      x86_64|amd64) echo "amd64" ;;
      aarch64|arm64) echo "arm64" ;;
      armv7l|armv7) echo "armv7" ;;
      i386|i686) echo "386" ;;
      *) read -rp "Enter release arch (amd64, arm64, 386): " arch; echo "${arch:-amd64}" ;;
    esac
}

download_backhaul() {
    local arch="$1"
    local tmpd="$2"
    local release_filename="backhaul_${PLATFORM}_${arch}.tar.gz"
    local release_url="https://github.com/${BACKHAUL_REPO}/releases/download/${BACKHAUL_VERSION}/${release_filename}"
    log "Downloading backhaul: $release_url"
    curl -fL --progress-bar -o "$tmpd/$release_filename" "$release_url" || err "Download failed"
    tar -xzf "$tmpd/$release_filename" -C "$tmpd"
    [[ -f "$tmpd/backhaul" ]] || err "'backhaul' binary not found"
    mkdir -p "$DESTDIR"
    mv "$tmpd/backhaul" "$DESTDIR/backhaul"
    chmod +x "$DESTDIR/backhaul"
}

get_role() {
    local ip country
    ip="$(curl -s https://api.ipify.org || echo "0.0.0.0")"
    country="$(curl -s "http://ip-api.com/line/$ip?fields=countryCode" || echo "XX")"
    [[ "${country^^}" == "IR" ]] && echo "server" || echo "client"
}

prompt_protocol() {
    local protocols=(tcp tcpmux ws wss wsmux wssmux udp)
    PS3="Select transport protocol: "
    select proto in "${protocols[@]}"; do
        [[ -n "$proto" ]] && { echo "$proto"; break; } || warn "Invalid selection."
    done
}

prompt_ports_server() {
    read -rp "Enter Tunnel port [default 3080]: " tunnel_port
    tunnel_port="${tunnel_port:-3080}"
    read -rp "Enter User port [default 443]: " user_port
    user_port="${user_port:-443}"
    echo "$tunnel_port $user_port"
}

prompt_mux() {
    read -rp "Enter MUX concurrency [default 8]: " mux
    echo "${mux:-8}"
}

generate_config() {
    local role="$1" proto="$2" tunnel_port="$3" user_port="$4" mux_con="$5" config_file="$6"
    cat > "$config_file" <<EOF
# Auto-generated Backhaul config
EOF

    if [[ "$role" == "server" ]]; then
        cat >> "$config_file" <<EOF
[server]
bind_addr = "0.0.0.0:${tunnel_port}"
transport = "${proto}"
accept_udp = false
token = "Ragacloud"
keepalive_period = 75
nodelay = true
channel_size = 2048
heartbeat = 40
sniffer = false
web_port = 2060
sniffer_log = "/root/backhaul.json"
log_level = "info"
skip_optz = true
mss = 1360
so_rcvbuf = 4194304
so_sndbuf = 1048576
ports = ["${user_port}"]
EOF
        [[ -n "$mux_con" ]] && echo -e "mux_con = $mux_con\nmux_version = 1" >> "$config_file"
        [[ "$proto" == "wss" || "$proto" == "wssmux" ]] && echo -e "tls_cert = \"${TLS_CERT}\"\ntls_key = \"${TLS_KEY}\"" >> "$config_file"
    else
        cat >> "$config_file" <<EOF
[client]
remote_addr = "0.0.0.0:${tunnel_port}"
transport = "${proto}"
edge_ip = ""
token = "Ragacloud"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
sniffer = false
web_port = 2060
sniffer_log = "/root/backhaul.json"
log_level = "info"
skip_optz = true
mss = 1360
so_rcvbuf = 1048576
so_sndbuf = 4194304
EOF
        [[ -n "$mux_con" ]] && echo -e "mux_version = 1\nmux_con = $mux_con" >> "$config_file"
    fi
}

create_service() {
    local svc_name="$1" config_file="$2"
    cat > "/etc/systemd/system/$svc_name" <<EOF
[Unit]
Description=Backhaul Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${DESTDIR}
ExecStart=${DESTDIR}/backhaul -c ${config_file}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$svc_name"
}

create_monitor() {
    local proto="$1" svc_name="$2"
    local monitor_script="/usr/local/bin/${proto}_monitor.sh"
    local monitor_log="/var/log/${proto}_monitor.log"
    rm -f /usr/local/bin/*_monitor.sh
    cat > "$monitor_script" <<EOF
#!/bin/bash
SERVICE_NAME="${svc_name}"
LOG_FILE="$monitor_log"
MATCH_WORDS="error|fail|broken|timeout|warning"
LOG=\$(journalctl -u "\$SERVICE_NAME" --since "2 minutes ago" --no-pager -o cat)
if echo "\$LOG" | grep -iE "\$MATCH_WORDS" >/dev/null 2>&1; then
    echo "\$(date): Log issue detected – restarting \$SERVICE_NAME" >> "\$LOG_FILE"
    if systemctl restart "\$SERVICE_NAME"; then
        echo "\$(date): \$SERVICE_NAME successfully restarted." >> "\$LOG_FILE"
    else
        echo "\$(date): Failed to restart \$SERVICE_NAME!" >> "\$LOG_FILE"
    fi
fi
EOF
    chmod +x "$monitor_script"
    cat > "/etc/systemd/system/${proto}-monitor.service" <<EOF
[Unit]
Description=Monitor for Backhaul ${proto} Service
After=network.target

[Service]
Type=oneshot
ExecStart=$monitor_script
EOF
    cat > "/etc/systemd/system/${proto}-monitor.timer" <<EOF
[Unit]
Description=Run ${proto}-monitor every 2 minutes

[Timer]
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reexec
    systemctl enable --now "${proto}-monitor.timer"
}

install_flow() {
    clear
    echo -e "${BLUE}${BOLD}===== Raga Backhaul Installer =====${RESET}"
    arch=$(detect_arch)
    tmpd=$(mktemp -d)
    trap "rm -rf $tmpd" EXIT
    download_backhaul "$arch" "$tmpd"
    role=$(get_role)
    proto=$(prompt_protocol)
    if [[ "$role" == "server" ]]; then
        read -r tunnel_port user_port <<< "$(prompt_ports_server)"
    else
        read -r tunnel_port <<< "$(prompt_ports_server)"
        user_port=""
    fi
    [[ "$proto" =~ mux ]] && mux_con=$(prompt_mux) || mux_con=""
    # config & service name with counter
    base_name="$proto"
    config_file="$DESTDIR/$base_name.toml"
    svc_name="backhaul.$proto.service"
    counter=1
    while [[ -f "$config_file" || -f "/etc/systemd/system/$svc_name" ]]; do
        counter=$((counter+1))
        config_file="$DESTDIR/${base_name}${counter}.toml"
        svc_name="backhaul.${proto}${counter}.service"
    done
    generate_config "$role" "$proto" "$tunnel_port" "$user_port" "$mux_con" "$config_file"
    create_service "$svc_name" "$config_file"
    create_monitor "$proto" "$svc_name"
    log "Raga Backhaul installed with protocol $proto on tunnel port $tunnel_port and user port $user_port"
}

list_services() {
    systemctl list-units --type=service | grep "backhaul"
}

uninstall_flow() {
    clear
    echo -e "${RED}${BOLD}===== Raga Backhaul Uninstaller =====${RESET}"
    list_services
    read -rp "Enter exact service name to remove: " svc
    systemctl stop "$svc"
    systemctl disable "$svc"
    rm -f "/etc/systemd/system/$svc"
    rm -f "/usr/local/bin/${svc#backhaul.}_monitor.sh"
    rm -f "/etc/systemd/system/${svc#backhaul.}-monitor.service"
    rm -f "/etc/systemd/system/${svc#backhaul.}-monitor.timer"
    systemctl daemon-reload
    log "Service $svc removed"
}

# =====================
# Main menu
# =====================
while true; do
    clear
    echo -e "${BLUE}${BOLD}===== Raga Backhaul Installer / Uninstaller =====${RESET}"
    echo -e "${YELLOW}1) Install Backhaul${RESET}"
    echo -e "${RED}2) Uninstall Backhaul${RESET}"
    echo -e "${BOLD}3) Exit${RESET}"
    read -rp "Enter choice [1-3]: " choice
    case "$choice" in
        1) install_flow ;;
        2) uninstall_flow ;;
        3) exit 0 ;;
        *) warn "Invalid choice" ;;
    esac
    read -rp "Press enter to continue..." dummy
done
