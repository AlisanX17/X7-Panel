# Two-node tunnel deployment

X7's tunnel profile is deliberately explicit: a two-node WireGuard site-to-site tunnel needs correct public endpoints, tunnel IPs, routed prefixes and firewall policy. Never assume a VPS's private/public interface names or default routes.

## Install roles

Run the installer on both Ubuntu 24.04 servers:

- Iran-side VPS: `sudo bash install.sh iran-node`
- Foreign-side VPS: `sudo bash install.sh foreign-node`

Each node gets its own `wg0` interface and admin token. Exchange only public keys. Keep private keys and admin tokens on their own machines.

## Values to agree before configuring the peer

- Iran public endpoint and UDP listen port
- Foreign public endpoint and UDP listen port
- Distinct tunnel addresses, for example `10.88.0.1/30` and `10.88.0.2/30`
- The exact LAN/client prefixes that should route through the tunnel
- Provider firewall rules permitting the selected UDP port

## Configure the peer

On each node, add the other node's public key as a peer with the other node's public endpoint and only the required `AllowedIPs`. Use `PersistentKeepalive = 25` on the side behind NAT. Then persist the peer with `wg-quick save wg0`.

Do not use overlapping AllowedIPs. Do not replace a server's default route unless you have out-of-band console access and a tested rollback plan. Configure nftables/iptables forwarding and NAT only after confirming the intended route topology.

The current web UI manages client peers on the local WireGuard interface. The paired-node orchestration wizard and automatic firewall policy are planned follow-up work; this document is not claiming that the two-node tunnel is automatically provisioned yet.
