#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run: sudo bash install.sh"; exit 1; }
[[ -r /etc/os-release ]] || { echo "Unsupported Linux"; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || { echo "This installer targets Ubuntu 24.04 LTS."; exit 1; }
if [[ -f /etc/x7-panel.env ]]; then
  echo "An X7 Panel installation already exists. Use: sudo bash update.sh"
  exit 1
fi
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  echo "Select deployment mode:"
  select MODE in standalone iran-node foreign-node; do [[ -n "$MODE" ]] && break; done
fi
case "$MODE" in standalone|iran-node|foreign-node) ;; *) echo "Mode must be standalone, iran-node, or foreign-node"; exit 2;; esac
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip wireguard-tools qrencode iptables iproute2
install -d -m 700 /etc/wireguard /var/lib/x7-panel /opt/x7-panel
python3 -m venv /opt/x7-panel/venv
cp -a app /opt/x7-panel/
/opt/x7-panel/venv/bin/pip install --disable-pip-version-check -r /opt/x7-panel/app/requirements.txt
PORT="${X7_WG_PORT:-51820}"
ADDR="${X7_SERVER_ADDRESS:-10.77.0.1/24}"
WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || { echo "Could not detect the default IPv4 network interface."; exit 1; }
ENDPOINT="${X7_ENDPOINT:-}"
if [[ -z "$ENDPOINT" ]]; then
  read -r -p "Public IP or DNS name for WireGuard clients: " ENDPOINT
fi
WG_PRIV="$(wg genkey)"
WG_PUB="$(printf '%s' "$WG_PRIV" | wg pubkey)"
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $ADDR
ListenPort = $PORT
PrivateKey = $WG_PRIV
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE
EOF
chmod 600 /etc/wireguard/wg0.conf
cat >/etc/x7-panel.env <<EOF
X7_DB=/var/lib/x7-panel/panel.db
X7_INTERFACE=wg0
X7_WG_PORT=$PORT
X7_ENDPOINT=$ENDPOINT
X7_SERVER_ADDRESS=$ADDR
X7_MODE=$MODE
EOF
chmod 600 /etc/x7-panel.env
echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-x7-panel.conf
sysctl --system >/dev/null
cat >/etc/systemd/system/x7-panel.service <<'EOF'
[Unit]
Description=X7 Panel
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/x7-panel
EnvironmentFile=/etc/x7-panel.env
ExecStart=/opt/x7-panel/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8787
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/x7-panel /etc/wireguard
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wg-quick@wg0
systemctl enable --now x7-panel
echo
echo "WireGuard base setup complete. Now configuring your domain, HTTPS, and admin login..."
bash update.sh
echo
echo "X7 Panel: https://$(grep '^X7_DOMAIN=' /etc/x7-panel.env | cut -d= -f2)"
echo "WireGuard public key: $WG_PUB"
echo "WireGuard endpoint: $ENDPOINT:$PORT"
echo "Allow TCP 80/443 and UDP $PORT in your VPS firewall/security group."
