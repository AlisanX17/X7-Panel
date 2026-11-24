#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run: sudo bash update.sh"; exit 1; }
[[ -f app/main.py && -f app/index.html ]] || { echo "Run this script from the X7-Panel repository folder."; exit 1; }
[[ -f /etc/x7-panel.env ]] || { echo "Existing X7 Panel installation was not found."; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || { echo "Ubuntu is required."; exit 1; }

echo "X7 Panel: updating to username/password login + HTTPS"
read -r -p "Panel domain (example: panel.example.com): " DOMAIN
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || { echo "Invalid domain."; exit 1; }
read -r -p "Admin username: " ADMIN_USER
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || { echo "Username must be 3-32 chars: letters, numbers, dot, underscore, hyphen."; exit 1; }
read -rsp "Admin password (minimum 12 characters): " ADMIN_PASS; echo
[[ ${#ADMIN_PASS} -ge 12 ]] || { echo "Password is too short."; exit 1; }
read -rsp "Repeat admin password: " ADMIN_PASS2; echo
[[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] || { echo "Passwords do not match."; exit 1; }
read -r -p "Email for Let's Encrypt certificate notices: " EMAIL
[[ "$EMAIL" == *@*.* ]] || { echo "A valid email is required for certificate setup."; exit 1; }

echo "Checking DNS for $DOMAIN ..."
if ! getent ahostsv4 "$DOMAIN" >/dev/null; then
  echo "Domain does not resolve yet. Create an A record in Cloudflare pointing to this VPS, wait for DNS, then rerun."
  exit 1
fi
echo "DNS resolves. Ensure the A record points to this VPS and ports TCP 80/443 are open."
echo "For first certificate issuance, set the Cloudflare record to DNS only (grey cloud)."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx python3 python3-venv python3-pip wireguard-tools qrencode iptables iproute2
install -d -m 700 /opt/x7-panel /var/lib/x7-panel
cp -a app /opt/x7-panel/
if [[ ! -x /opt/x7-panel/venv/bin/python ]]; then python3 -m venv /opt/x7-panel/venv; fi
/opt/x7-panel/venv/bin/pip install --disable-pip-version-check -r /opt/x7-panel/app/requirements.txt

HASH="$(python3 - "$ADMIN_PASS" <<'PY'
import hashlib, os, sys
salt=os.urandom(16)
digest=hashlib.pbkdf2_hmac("sha256",sys.argv[1].encode(),salt,310000).hex()
print(salt.hex()+"$"+digest)
PY
)"
unset ADMIN_PASS ADMIN_PASS2
TMP_ENV="$(mktemp)"
if [[ -f /etc/x7-panel.env ]]; then
  grep -v -E '^X7_(ADMIN_USER|ADMIN_PASSWORD_HASH|DOMAIN|ADMIN_TOKEN)=' /etc/x7-panel.env >"$TMP_ENV" || true
fi
{
  echo "X7_ADMIN_USER=$ADMIN_USER"
  echo "X7_ADMIN_PASSWORD_HASH=$HASH"
  echo "X7_DOMAIN=$DOMAIN"
} >>"$TMP_ENV"
install -m 600 "$TMP_ENV" /etc/x7-panel.env
rm -f "$TMP_ENV"

cat >"/etc/nginx/sites-available/x7-panel" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 2m;
    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sfn /etc/nginx/sites-available/x7-panel /etc/nginx/sites-enabled/x7-panel
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl restart x7-panel
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
systemctl reload nginx
echo
echo "Update complete."
echo "Panel: https://$DOMAIN"
echo "Admin username: $ADMIN_USER"
echo "Password: the one you entered (not saved in plaintext)."
echo "The old admin token is no longer used by the updated app."
echo "Ensure Cloudflare DNS A record points to this VPS; if proxied, set SSL/TLS mode to Full (strict)."
