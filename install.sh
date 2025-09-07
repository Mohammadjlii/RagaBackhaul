#!/bin/bash

# === Colors & Symbols ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

CHECKMARK="\xE2\x9C\x94"
CROSS="\xE2\x9D\x8C"
ARROW="➜"
LINE="========================================"

clear
echo -e "${CYAN} $LINE"
echo -e "  🚀  ${GREEN}Backhaul Tunnel Setup Script${NC}"
echo -e " $LINE${NC}"

# Step 1: Prepare environment
echo -e "${YELLOW}${ARROW} Creating /root/backhaul and downloading binary...${NC}"
mkdir -p /root/backhaul
cd /root/backhaul || { echo -e "${RED}${CROSS} Failed to access /root/backhaul.${NC}"; exit 1; }

if [[ -f /root/backhaul/backhaul ]]; then
    echo -e "${YELLOW}${ARROW} Removing old Backhaul binary...${NC}"
    rm -f /root/backhaul/backhaul
fi

wget -q --show-progress https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_amd64.tar.gz
tar xvf backhaul_linux_amd64.tar.gz > /dev/null
rm backhaul_linux_amd64.tar.gz
chmod +x backhaul
echo -e "${GREEN}${CHECKMARK} Backhaul downloaded and ready.${NC}"

echo -e "\n$LINE"

# Step 2: Get user input
echo -e "${YELLOW}${ARROW} Select the tunnel protocol:${NC}"
select protocol in "tcp" "ws" "tcpmux" "wsmux" "wssmux"; do
    case $protocol in
        tcp|ws|tcpmux|wsmux|wssmux) break ;;
        *) echo -e "${RED}Invalid option. Choose again.${NC}" ;;
    esac
done

# Step 3: Detect role
public_ip=$(curl -s https://api.ipify.org || echo "0.0.0.0")
country=$(curl -s "http://ip-api.com/line/$public_ip?fields=countryCode" || echo "XX")

if [[ "$country" == "IR" ]]; then
    role="server"
    echo "Role = SERVER"
else
    role="client"
    echo "Role = CLIENT"
fi

echo -e "${CYAN}Public IP: ${GREEN}$public_ip${NC} | Country: ${GREEN}$country${NC} → Role: ${YELLOW}$role${NC}"

# Step 4: Create config file
if [[ "$role" == "client" ]]; then
    read -rp "Enter server address (e.g., 1.2.3.4): " target_address
    read -rp "Enter tunnel port (e.g., 5605): " tunnel_port
    read -rp "Enter local target port (e.g., 80): " target_port
else
    read -rp "Enter tunnel port to listen on (e.g., 5605): " tunnel_port
    read -rp "Enter destination port to forward (e.g., 2020): " target_port
    target_address="0.0.0.0"
fi

config_path="/root/backhaul/${protocol}.toml"
echo -e "${YELLOW}${ARROW} Generating config at ${CYAN}$config_path${NC}"

if [[ "$role" == "server" ]]; then
cat > "$config_path" <<EOF
[server]
bind_addr = "0.0.0.0:$tunnel_port"
transport = "$protocol"
token = "Ragacloud"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
mux_con = 16
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
sniffer_log = "/root/backhaul.json"
log_level = "info"
ports = ["$target_port"]
EOF
else
cat > "$config_path" <<EOF
[client]
remote_addr = "$target_address:$tunnel_port"
edge_ip = ""
transport = "$protocol"
token = "Ragacloud"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
nodelay = true
retry_interval = 3
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
sniffer_log = "/root/backhaul.json"
log_level = "info"
EOF
fi

echo -e "${GREEN}${CHECKMARK} Config created successfully.${NC}"

# Step 5: Remove old service if exists
service_path="/etc/systemd/system/${protocol}.service"
if systemctl list-units --full -all | grep -q "${protocol}.service"; then
    echo -e "${YELLOW}${ARROW} Found existing ${protocol}.service – stopping and removing...${NC}"
    systemctl stop "${protocol}.service"
    systemctl disable "${protocol}.service"
    rm -f "$service_path"
fi

# Step 6: Create new systemd service
echo -e "${YELLOW}${ARROW} Creating systemd service: ${CYAN}${protocol}.service${NC}"

cat > "$service_path" <<EOF
[Unit]
Description=Backhaul $protocol Reverse Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/root/backhaul/backhaul -c /root/backhaul/${protocol}.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Step 7: Enable and start service
echo -e "${YELLOW}${ARROW} Enabling and starting service...${NC}"
systemctl daemon-reexec
systemctl enable --now "${protocol}.service"

if systemctl is-active --quiet "${protocol}.service"; then
    echo -e "${GREEN}${CHECKMARK} Service ${protocol}.service is active!${NC}"
else
    echo -e "${RED}${CROSS} Failed to start service. Use 'journalctl -xe' for logs.${NC}"
fi

# Step 8: Create monitor script
monitor_script="/usr/local/bin/${protocol}_monitor.sh"
LOG_FILE="/var/log/${protocol}_monitor.log"

# پاک کردن مانیتورهای قبلی
echo -e "${YELLOW}${ARROW} Removing old monitor scripts...${NC}"
rm -f /usr/local/bin/*_monitor.sh

# ساخت مانیتور جدید
cat > "$monitor_script" <<EOF
#!/bin/bash
SERVICE_NAME="${protocol}.service"
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

# Step 9: Create systemd monitor service
monitor_service="/etc/systemd/system/${protocol}-monitor.service"
monitor_timer="/etc/systemd/system/${protocol}-monitor.timer"

cat > "$monitor_service" <<EOF
[Unit]
Description=Monitor for Backhaul ${protocol} Service
After=network.target

[Service]
Type=oneshot
ExecStart=$monitor_script
EOF

cat > "$monitor_timer" <<EOF
[Unit]
Description=Run ${protocol}-monitor every 2 minutes

[Timer]
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

# فعال‌سازی سرویس و تایمر
systemctl daemon-reexec
systemctl enable --now "${protocol}-monitor.timer"

echo -e "${GREEN}${CHECKMARK} Monitor service and timer created for ${protocol}.${NC}"


# Step 10: Save role
echo "$role" > /root/backhaul/role.txt

