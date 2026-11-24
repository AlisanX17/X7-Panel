#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run: sudo bash uninstall.sh"; exit 1; }
echo "This removes the X7 Panel web application and its Nginx site."
read -r -p "Also remove WireGuard itself, its server key/config, and saved peers? [y/N]: " REMOVE_WG
systemctl disable --now x7-panel 2>/dev/null || true
rm -f /etc/systemd/system/x7-panel.service
systemctl daemon-reload
rm -f /etc/nginx/sites-enabled/x7-panel /etc/nginx/sites-available/x7-panel
if command -v nginx >/dev/null 2>&1; then nginx -t && systemctl reload nginx || true; fi
rm -rf /opt/x7-panel
rm -f /etc/x7-panel.env /root/x7-panel-credentials.txt
if [[ "$REMOVE_WG" =~ ^[Yy]$ ]]; then
  systemctl disable --now wg-quick@wg0 2>/dev/null || true
  rm -f /etc/wireguard/wg0.conf /etc/sysctl.d/99-x7-panel.conf
  rm -rf /var/lib/x7-panel
  sysctl --system >/dev/null 2>&1 || true
  echo "WireGuard config and peer database removed."
else
  echo "WireGuard server config and peer database were preserved."
  echo "If you want to remove WireGuard later, remove /etc/wireguard/wg0.conf and stop wg-quick@wg0 yourself."
fi
echo "X7 Panel has been uninstalled. Nginx, Certbot, and WireGuard packages were not removed because other services may use them."
