# X7 Panel

Self-hosted WireGuard management panel for Ubuntu 24.04 LTS.

## Features

- Persian RTL dashboard
- Username/password administrator login (password stored as PBKDF2-HMAC-SHA256 hash)
- Custom panel domain with Nginx reverse proxy and Let's Encrypt HTTPS
- WireGuard peer create/delete, client config download and QR code
- Live interface status and peer transfer counters
- Interactive uninstaller

## Cloudflare DNS before installation

1. Add an **A** record for the panel hostname (for example panel.example.com) pointing to the public IPv4 address of this VPS.
2. For initial certificate issuance, set the record to **DNS only** (grey cloud).
3. Allow inbound TCP 80 and 443, plus UDP 51820 (or your chosen WireGuard port) in the VPS provider firewall.
4. The installer obtains a trusted Let's Encrypt certificate. After HTTPS works, you may enable Cloudflare proxy if desired and set Cloudflare SSL/TLS mode to **Full (strict)**.

Cloudflare proxy status controls whether web traffic goes through Cloudflare or directly to the origin; DNS-only records resolve directly to the origin. See [Cloudflare proxy status documentation](https://developers.cloudflare.com/dns/proxy-status/). Certbot's Nginx integration configures TLS for the hostname; see [Ubuntu TLS certificate documentation](https://ubuntu.com/server/docs/how-to/security/obtain-tls-certificates/).

## Fresh installation

```bash
git clone https://github.com/AlisanX17/X7-Panel.git
cd X7-Panel
sudo bash install.sh
```

Select standalone for one foreign VPS. The installer then asks for the WireGuard endpoint, panel domain, admin username, admin password, and certificate email. The password is not stored in plaintext.

Open the panel at https://your-panel-domain.

## Upgrade an existing installation

```bash
cd ~/X7-Panel
git pull
sudo bash update.sh
```

The update script asks for the panel domain and new admin credentials, updates the app, configures Nginx, and requests/renews HTTPS. It does not reset WireGuard keys or delete the peer database.

## Uninstall

```bash
cd ~/X7-Panel
sudo bash uninstall.sh
```

The uninstaller removes the panel app and Nginx site. It asks whether WireGuard configuration and saved peers should also be deleted. By default, WireGuard is preserved. Nginx, Certbot, and WireGuard packages are not removed because other services may use them.

## Important limitations

- The current standalone mode manages one WireGuard server. Automatic Iran-to-foreign two-node pairing and route orchestration are not implemented.
- Test on a disposable VPS before production use. ISP filtering, routing, provider firewalls, and local network policies can affect connectivity.
- Keep /etc/x7-panel.env, /etc/wireguard/wg0.conf, and /var/lib/x7-panel/ private. Never share administrator credentials or client private keys.
- The panel listens only on 127.0.0.1:8787; Nginx exposes it through HTTPS.
