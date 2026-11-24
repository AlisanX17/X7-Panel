#!/usr/bin/env bash
set -Eeuo pipefail
BASE="https://raw.githubusercontent.com/AlisanX17/X7-Panel/main"
APP=/opt/x7-panel
ENV=/etc/x7-panel.env
DB=/var/lib/x7-panel
die(){ echo "[X7] ERROR: $*" >&2; exit 1; }
say(){ echo; echo "[X7] $*"; }
[[ $EUID -eq 0 ]] || die "Run: curl -fsSL $BASE/install.sh | sudo bash"
case "${1:-}" in
 --version) echo "X7 Panel 0.4.0"; exit 0;;
 --help) echo "Run install/update: curl -fsSL $BASE/install.sh | sudo bash"; echo "Check: sudo bash install.sh --check"; echo "Uninstall: curl -fsSL $BASE/uninstall.sh | sudo bash"; exit 0;;
 --uninstall) curl -fsSL "$BASE/uninstall.sh" -o /tmp/x7-uninstall.sh; exec bash /tmp/x7-uninstall.sh;;
 --check) systemctl --no-pager status x7-panel wg-quick@wg0 nginx 2>&1 || true; ss -lntup | grep -E ':(80|443|8787|51820)\b' || true; exit 0;;
esac
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die "Ubuntu 24.04 LTS required."
UPDATE=0; [[ -f "$ENV" ]] && UPDATE=1
if [[ $UPDATE == 0 ]]; then
 say "نصب اولیه X7 Panel - حالت تک سرور خارج"
 DEFAULT_IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
 read -r -p "WireGuard public IP/domain [$DEFAULT_IP]: " ENDPOINT
 ENDPOINT="${ENDPOINT:-$DEFAULT_IP}"
 [[ -n "$ENDPOINT" ]] || die "Public endpoint required."
 read -r -p "WireGuard UDP port [51820]: " WG_PORT; WG_PORT="${WG_PORT:-51820}"
 [[ "$WG_PORT" =~ ^[0-9]{1,5}$ ]] && ((WG_PORT>0 && WG_PORT<65536)) || die "Invalid UDP port."
 read -r -p "Panel domain (Enter for SSH-only): " DOMAIN
 read -r -p "Admin username [admin]: " ADMIN_USER; ADMIN_USER="${ADMIN_USER:-admin}"
 [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || die "Username must be 3-32 letters/numbers/._-"
 while :; do
  read -rsp "Admin password (12+ chars): " ADMIN_PASS; echo
  [[ ${#ADMIN_PASS} -ge 12 ]] || { echo "At least 12 characters."; continue; }
  read -rsp "Repeat password: " PASS2; echo
  [[ "$ADMIN_PASS" == "$PASS2" ]] && break
  echo "Passwords do not match."
 done
else
 say "نصب قبلی پیدا شد؛ دیتابیس و کلیدهای WireGuard حفظ می‌شوند."
 ENDPOINT="$(sed -n 's/^X7_ENDPOINT=//p' "$ENV" | tail -1)"
 WG_PORT="$(sed -n 's/^X7_WG_PORT=//p' "$ENV" | tail -1)"
 DOMAIN="$(sed -n 's/^X7_DOMAIN=//p' "$ENV" | tail -1)"
 PATH_SECRET="$(sed -n 's/^X7_PATH_SECRET=//p' "$ENV" | tail -1)"
 read -r -p "Panel domain [${DOMAIN:-none}]: " NEW_DOMAIN; DOMAIN="${NEW_DOMAIN:-$DOMAIN}"
 read -r -p "Admin username (Enter keeps current): " ADMIN_USER
 ADMIN_USER="${ADMIN_USER:-$(sed -n 's/^X7_ADMIN_USER=//p' "$ENV" | tail -1)}"
 [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || die "Invalid username."
 read -rsp "New admin password (Enter keeps current): " ADMIN_PASS; echo
 if [[ -z "$ADMIN_PASS" ]]; then HASH="$(sed -n 's/^X7_ADMIN_PASSWORD_HASH=//p' "$ENV" | tail -1)"
 else [[ ${#ADMIN_PASS} -ge 12 ]] || die "Password must be 12+ chars."; fi
fi
PATH_SECRET="${PATH_SECRET:-$(openssl rand -hex 20)}"
PANEL_PORT=9444
CF_TOKEN=""; EMAIL=""
if [[ -n "$DOMAIN" ]]; then
 if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${PANEL_PORT}$" && [[ ! -e /etc/nginx/sites-enabled/x7-panel-9444 ]]; then die "TCP port ${PANEL_PORT} is already in use."; fi
 [[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid panel domain."
 read -rsp "Cloudflare API Token for DNS-01 SSL (Enter = HTTP-01): " CF_TOKEN; echo
 read -r -p "Let's Encrypt email [admin@$DOMAIN]: " EMAIL; EMAIL="${EMAIL:-admin@$DOMAIN}"
fi
export DEBIAN_FRONTEND=noninteractive
say "Installing system packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates python3 python3-venv python3-pip wireguard-tools iptables iproute2 nginx certbot python3-certbot-nginx
if [[ -n "$CF_TOKEN" ]]; then apt-get install -y -qq python3-certbot-dns-cloudflare || true; fi
install -d -m 700 "$APP" "$DB" /etc/wireguard
say "Downloading latest X7 application"
for f in main.py index.html __init__.py requirements.txt; do curl -fLsS "$BASE/app/$f" -o "$APP/$f"; done
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install --disable-pip-version-check -q -r "$APP/requirements.txt"
if [[ $UPDATE == 0 ]]; then
 WAN="$(ip -4 route show default | awk 'NR==1{print $5}')"; [[ -n "$WAN" ]] || die "Cannot detect network interface."
 PRIV="$(wg genkey)"; PUB="$(printf '%s' "$PRIV" | wg pubkey)"
 cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = $WG_PORT
PrivateKey = $PRIV
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN -j MASQUERADE
EOF
 chmod 600 /etc/wireguard/wg0.conf
 HASH="$(ADMIN_PASS="$ADMIN_PASS" python3 - <<'PY'
import hashlib,os,secrets
s=secrets.token_bytes(16)
print(s.hex()+"$"+hashlib.pbkdf2_hmac("sha256",os.environ["ADMIN_PASS"].encode(),s,310000).hex())
PY
)"
else
 PUB="$(wg show wg0 public-key 2>/dev/null || true)"
 if [[ -n "$ADMIN_PASS" ]]; then
  HASH="$(ADMIN_PASS="$ADMIN_PASS" python3 - <<'PY'
import hashlib,os,secrets
s=secrets.token_bytes(16)
print(s.hex()+"$"+hashlib.pbkdf2_hmac("sha256",os.environ["ADMIN_PASS"].encode(),s,310000).hex())
PY
)"
 fi
fi
unset ADMIN_PASS PASS2
TMP="$(mktemp)"
if [[ $UPDATE == 1 ]]; then grep -v -E '^X7_(ADMIN_USER|ADMIN_PASSWORD_HASH|DOMAIN|PATH_SECRET|PANEL_PORT)=' "$ENV" >"$TMP" || true; fi
{
 echo "X7_DB=$DB/panel.db"
 echo "X7_INTERFACE=wg0"
 echo "X7_WG_PORT=$WG_PORT"
 echo "X7_ENDPOINT=$ENDPOINT"
 echo "X7_SERVER_ADDRESS=10.77.0.1/24"
 echo "X7_MODE=standalone"
 echo "X7_PANEL_PORT=$PANEL_PORT"
 echo "X7_PATH_SECRET=$PATH_SECRET"
 echo "X7_ADMIN_USER=$ADMIN_USER"
 echo "X7_ADMIN_PASSWORD_HASH=$HASH"
 [[ -n "$DOMAIN" ]] && echo "X7_DOMAIN=$DOMAIN" || true
} >>"$TMP"
install -m 600 "$TMP" "$ENV"; rm -f "$TMP"
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
ExecStart=/opt/x7-panel/venv/bin/uvicorn main:app --app-dir /opt/x7-panel --host 127.0.0.1 --port 8787
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
systemctl restart x7-panel
TLS=0
if [[ -n "$DOMAIN" ]]; then
 if ! getent ahostsv4 "$DOMAIN" >/dev/null; then
  echo "[X7] DNS does not resolve yet."
 elif [[ -n "$CF_TOKEN" ]] && dpkg -s python3-certbot-dns-cloudflare >/dev/null 2>&1; then
  install -d -m 700 /etc/letsencrypt
  printf 'dns_cloudflare_api_token = %s\\n' "$CF_TOKEN" >/etc/letsencrypt/cloudflare-x7.ini
  chmod 600 /etc/letsencrypt/cloudflare-x7.ini
  certbot certonly --non-interactive --agree-tos --email "$EMAIL" --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare-x7.ini -d "$DOMAIN" && TLS=1 || true
 else
  certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" && TLS=1 || true
 fi
 if [[ $TLS == 1 ]]; then
  cat >/etc/nginx/sites-available/x7-panel-9444 <<EOF
server {
 listen ${PANEL_PORT} ssl;
 server_name $DOMAIN;
 ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
 ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
 ssl_protocols TLSv1.2 TLSv1.3;
 add_header X-Frame-Options DENY always;
 add_header X-Content-Type-Options nosniff always;
 location = /$PATH_SECRET { return 301 /$PATH_SECRET/; }
 location ^~ /$PATH_SECRET/ {
  proxy_pass http://127.0.0.1:8787/;
  proxy_set_header Host \\$host;
  proxy_set_header X-Real-IP \\$remote_addr;
  proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto https;
 }
 location / { return 404; }
}
EOF
  ln -sfn /etc/nginx/sites-available/x7-panel-9444 /etc/nginx/sites-enabled/x7-panel-9444
  nginx -t && systemctl enable --now nginx && systemctl reload nginx
 else
  echo "[X7] SSL not issued. X7 remains SSH-only; check DNS/HTTP-01 reachability or Cloudflare token, then rerun installer."
 fi
fi
unset CF_TOKEN
say "X7 Panel install/update finished."
if [[ $TLS == 1 ]]; then echo "Panel: https://$DOMAIN:$PANEL_PORT/$PATH_SECRET/"; else echo "Panel: SSH-only at 127.0.0.1:8787"; echo "SSH: ssh -L 8787:127.0.0.1:8787 root@YOUR_SERVER_IP"; fi
echo "Admin username: $ADMIN_USER"
echo "WireGuard endpoint: $ENDPOINT:$WG_PORT"
echo "WireGuard public key: ${PUB:-$(wg show wg0 public-key 2>/dev/null || true)}"
echo "Update: curl -fsSL $BASE/install.sh | sudo bash"
echo "Remove: curl -fsSL $BASE/uninstall.sh | sudo bash"
echo "Open TCP $PANEL_PORT and UDP $WG_PORT at your VPS firewall. (TCP 80 is only needed for HTTP-01 certificate issuance.)"
