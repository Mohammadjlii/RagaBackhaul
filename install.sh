#!/bin/bash

# === Colors & Symbols ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[1;35m'
BLUE_BG='\033[1;44m'
NC='\033[0m'

CHECKMARK="\xE2\x9C\x94"
CROSS="\xE2\x9D\x8C"
ARROW="➜"
LINE="========================================"

clear

# === Logo RAGA ===
echo -e "${BLUE_BG}${CYAN}  ██████╗  █████╗  ██████╗  █████╗  ${NC}"
echo -e "${BLUE_BG}${CYAN}  ██╔══██╗██╔══██╗██╔════╝ ██╔══██╗ ${NC}"
echo -e "${BLUE_BG}${CYAN}  ██████╔╝███████║██║  ███╗███████║ ${NC}"
echo -e "${BLUE_BG}${CYAN}  ██╔═══╝ ██╔══██║██║   ██║██╔══██║ ${NC}"
echo -e "${BLUE_BG}${CYAN}  ██║ ██║ ██║  ██║╚██████╔╝██║  ██║ ${NC}"
echo -e "${BLUE_BG}${CYAN}  ╚═╝ ╚═╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ${NC}"
echo -e "\n${MAGENTA}       🌩️  RagaCloud Backhaul Manager  🌩️${NC}\n"

# === Main Menu ===
while true; do
    echo -e "${LINE}"
    echo -e "${YELLOW}[1]${NC} Install Backhaul"
    echo -e "${YELLOW}[2]${NC} Uninstall Backhaul (light)"
    echo -e "${YELLOW}[0]${NC} Exit"
    echo -e "${LINE}"
    read -rp "Select an option: " choice

    case $choice in
        1)
            # ============================
            # Install Backhaul (full script)
            # ============================
            # Call the install routine as a function to keep clean
            install_backhaul() {
                clear
                echo -e "${CYAN} $LINE"
                echo -e "  🚀  ${GREEN}Backhaul Tunnel Setup Script${NC}"
                echo -e " $LINE${NC}"

                # === Step 1: Prepare environment ===
                echo -e "${YELLOW}${ARROW} Preparing Backhaul environment...${NC}"
                mkdir -p /root/backhaul
                cd /root/backhaul || { echo -e "${RED}${CROSS} Failed to access /root/backhaul.${NC}"; exit 1; }

                # Check if Backhaul already exists
                if [[ -x "/root/backhaul/backhaul" ]]; then
                    echo -e "${GREEN}${CHECKMARK} Existing Backhaul binary detected – skipping download.${NC}"
                else
                    echo -e "${YELLOW}${ARROW} Downloading Backhaul binary for your architecture...${NC}"
                    arch=$(uname -m)
                    case "$arch" in
                        x86_64) file_name="backhaul_linux_amd64.tar.gz" ;;
                        aarch64) file_name="backhaul_linux_arm64.tar.gz" ;;
                        armv7l) file_name="backhaul_linux_armv7.tar.gz" ;;
                        *) echo -e "${RED}${CROSS} Unsupported architecture: $arch${NC}"; exit 1 ;;
                    esac
                    url="https://github.com/Musixal/Backhaul/releases/download/v0.7.2/$file_name"
                    wget -q --show-progress "$url" -O "$file_name" || { echo -e "${RED}${CROSS} Download failed.${NC}"; exit 1; }
                    tar xvf "$file_name" > /dev/null
                    mv backhaul_linux_* backhaul 2>/dev/null || true
                    rm "$file_name"
                    chmod +x backhaul
                    echo -e "${GREEN}${CHECKMARK} Backhaul downloaded and ready.${NC}"
                fi

                # === Step 2: Protocol selection ===
                echo -e "${YELLOW}${ARROW} Select the tunnel protocol:${NC}"
                select protocol in "tcp" "ws" "tcpmux" "wsmux" "wssmux"; do
                    case $protocol in
                        tcp|ws|tcpmux|wsmux|wssmux) break ;;
                        *) echo -e "${RED}Invalid option. Choose again.${NC}" ;;
                    esac
                done

                # === Step 3: Detect role ===
                public_ip=$(curl -s https://api.ipify.org || echo "0.0.0.0")
                country=$(curl -s "http://ip-api.com/line/$public_ip?fields=countryCode" || echo "XX")
                if [[ "$country" == "IR" ]]; then role="server"; else role="client"; fi
                echo -e "${CYAN}Public IP: ${GREEN}$public_ip${NC} | Country: ${GREEN}$country${NC} → Role: ${YELLOW}$role${NC}"

                # === Step 4: Create config file ===
                config_path="/root/backhaul/${protocol}.toml"
                token="RagaCloud"
                tls_cert="/root/cert.crt"
                tls_key="/root/private.key"
                web_port=0

                if [[ "$role" == "server" ]]; then
                    read -rp "Enter tunnel port to listen on (e.g., 3080): " tunnel_port
                    read -rp "Enter destination port to forward (e.g., 2020): " target_port
                    cat > "$config_path" <<EOF
[server]
bind_addr = "0.0.0.0:$tunnel_port"
transport = "$protocol"
accept_udp = false
token = "$token"
keepalive_period = 75
nodelay = false
channel_size = 2048
heartbeat = 40
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = $web_port
sniffer_log = "/root/log.json"
log_level = "info"
skip_optz = true
mss = 1360
so_rcvbuf = 4194304
so_sndbuf = 1048576
EOF
                    if [[ "$protocol" == "wss" || "$protocol" == "wssmux" ]]; then
                        echo "tls_cert = \"$tls_cert\"" >> "$config_path"
                        echo "tls_key = \"$tls_key\"" >> "$config_path"
                    fi
                    echo -e "\nports = [\"$target_port\"]" >> "$config_path"
                else
                    read -rp "Enter server address (e.g., 1.2.3.4): " target_address
                    read -rp "Enter tunnel port (e.g., 3080): " tunnel_port
                    cat > "$config_path" <<EOF
[client]
remote_addr = "$target_address:$tunnel_port"
edge_ip = ""
transport = "$protocol"
token = "$token"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
nodelay = false
retry_interval = 3
dial_timeout = 10
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = $web_port
sniffer_log = "/root/log.json"
log_level = "info"
skip_optz = true
mss = 1360
so_rcvbuf = 1048576
so_sndbuf = 4194304
EOF
                fi
                echo -e "${GREEN}${CHECKMARK} Config created successfully.${NC}"

                # === Step 5 & 6: Service name & systemd ===
                base_name="backhaul.${protocol}"
                service_path="/etc/systemd/system/${base_name}.service"
                config_base="/root/backhaul/${base_name}.toml"
                counter=1
                while [[ -f "/etc/systemd/system/${base_name}.service" ]]; do
                    counter=$((counter + 1))
                    base_name="backhaul.${protocol}${counter}"
                    service_path="/etc/systemd/system/${base_name}.service"
                    config_base="/root/backhaul/${base_name}.toml"
                done
                mv "/root/backhaul/${protocol}.toml" "$config_base" 2>/dev/null || true
                echo -e "${YELLOW}${ARROW} Using service name: ${CYAN}${base_name}${NC}"

                if systemctl list-units --full -all | grep -q "${base_name}.service"; then
                    echo -e "${YELLOW}${ARROW} Found existing ${base_name}.service – stopping and removing...${NC}"
                    systemctl stop "${base_name}.service"
                    systemctl disable "${base_name}.service"
                    rm -f "$service_path"
                fi

                cat > "$service_path" <<EOF
[Unit]
Description=Backhaul ${protocol} Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/root/backhaul/backhaul -c $config_base
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

                # === Step 7: Enable & start ===
                echo -e "${YELLOW}${ARROW} Enabling and starting service...${NC}"
                systemctl daemon-reload
                systemctl enable --now "${base_name}.service"
                systemctl daemon-reexec
                if systemctl is-active --quiet "${base_name}.service"; then
                    echo -e "${GREEN}${CHECKMARK} Service ${base_name}.service is active!${NC}"
                else
                    echo -e "${RED}${CROSS} Failed to start service. Use 'journalctl -xe' for logs.${NC}"
                fi

                # === Step 8: Monitor script ===
                monitor_script="/usr/local/bin/${base_name}_monitor.sh"
                LOG_FILE="/var/log/${base_name}_monitor.log"
                rm -f "$monitor_script"
                cat > "$monitor_script" <<EOF
#!/bin/bash
SERVICE_NAME="${base_name}.service"
LOG_FILE="$LOG_FILE"
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

                # === Step 9: Monitor service & timer ===
                monitor_service="/etc/systemd/system/${base_name}-monitor.service"
                monitor_timer="/etc/systemd/system/${base_name}-monitor.timer"

                cat > "$monitor_service" <<EOF
[Unit]
Description=Monitor for ${base_name} Service
After=network.target

[Service]
Type=oneshot
ExecStart=$monitor_script
EOF

                cat > "$monitor_timer" <<EOF
[Unit]
Description=Run ${base_name}-monitor every 2 minutes

[Timer]
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

                systemctl daemon-reload
                systemctl enable --now "${base_name}-monitor.timer"

                echo -e "${GREEN}${CHECKMARK} Monitor and timer created for ${base_name}.${NC}"
                echo -e "${GREEN}🎉 Installation completed successfully!${NC}"
            }

            install_backhaul
            break
            ;;
2)
    # ============================
    # Uninstall (interactive light, full cleanup)
    # ============================
    echo -e "${YELLOW}${ARROW} Interactive Uninstall: Select services to remove${NC}"
    while true; do
        # گرفتن لیست سرویس‌ها
        mapfile -t services < <(systemctl list-units --full -all | grep 'backhaul\.' | awk '{print $1}')
        if [[ ${#services[@]} -eq 0 ]]; then
            echo -e "${GREEN}No Backhaul services found.${NC}"
            break
        fi

        echo -e "${LINE}"
        echo -e "${CYAN}Available Backhaul Services:${NC}"
        for i in "${!services[@]}"; do
            printf "[%d] %s\n" "$((i+1))" "${services[i]}"
        done
        echo -e "[0] Exit Uninstall"
        echo -e "${LINE}"

        read -rp "Select a service to remove (number): " sel
        if [[ "$sel" == "0" ]]; then
            echo -e "${CYAN}Exiting uninstall...${NC}"
            break
        elif [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#services[@]} )); then
            svc="${services[$((sel-1))]}"
            echo -e "${RED}${ARROW} Stopping and removing $svc ...${NC}"

            # توقف و حذف سرویس اصلی
            systemctl stop "$svc"
            systemctl disable "$svc"
            rm -f "/etc/systemd/system/$svc"

            # حذف مانیتور مربوطه
            monitor="/usr/local/bin/$(basename "$svc" .service)_monitor.sh"
            [[ -f "$monitor" ]] && rm -f "$monitor"

            # حذف سرویس و تایمر مانیتور مربوطه
            monitor_service="/etc/systemd/system/$(basename "$svc" .service)-monitor.service"
            monitor_timer="/etc/systemd/system/$(basename "$svc" .service)-monitor.timer"
            [[ -f "$monitor_service" ]] && rm -f "$monitor_service"
            [[ -f "$monitor_timer" ]] && rm -f "$monitor_timer"

            systemctl daemon-reload
            echo -e "${GREEN}${CHECKMARK} $svc and its monitor/timer removed.${NC}"
        else
            echo -e "${RED}Invalid selection. Try again.${NC}"
        fi
    done
    break
    ;;
        0)
            echo -e "${CYAN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option, choose again.${NC}"
            ;;
    esac
done
