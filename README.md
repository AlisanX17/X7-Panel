# X7 Panel

A self-hosted WireGuard management panel for Ubuntu 24.04 LTS.

## Current release scope

- Single-server WireGuard provisioning and peer lifecycle.
- Admin-token protected API and Persian RTL dashboard.
- Peer configuration download and QR display.
- Live interface status and per-peer transfer counters.
- systemd installer, persistent WireGuard configuration, backup command.
- Tunnel mode is a guided two-node deployment profile. Both nodes are installed independently; the site-to-site peer and routing values must be supplied explicitly. The installer does not guess routes or overwrite firewall policy.

> This is an early release. Test on disposable VPS instances first. No VPN can be guaranteed to work on every ISP or network. Before public deployment, put the panel behind HTTPS and restrict management access with a firewall.

## Install

```bash
git clone https://github.com/AlisanX17/X7-Panel.git
cd X7-Panel
sudo bash install.sh
```

Installer asks for `standalone`, `iran-node`, or `foreign-node`, creates a WireGuard interface, enables forwarding only for tunnel node modes, and prints a random admin token once.

Panel binds to `127.0.0.1:8787` by default. Recommended first access:

```bash
ssh -L 8787:127.0.0.1:8787 root@YOUR_SERVER_IP
```

Then open http://127.0.0.1:8787.

## Important

- Keep `/etc/x7-panel.env`, `/etc/wireguard/`, and `/var/lib/x7-panel/` private.
- Never share a client private key or admin token.
- For two-node tunnel mode, configure the two nodes' public endpoints, tunnel addresses, AllowedIPs and forwarding/firewall rules to match your VPS provider's network. See `docs/TUNNEL.md`.
- `wg-quick` and `wireguard-tools` must be installed by the installer.
