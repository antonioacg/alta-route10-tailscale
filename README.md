# Alta Labs Route 10 + Tailscale

Mesh VPN with subnet routing and exit node support on the Alta Labs Route 10 router using [Tailscale](https://tailscale.com).

## What This Does

- **Subnet router** — access LAN devices (192.168.1.x) from anywhere via Tailscale
- **Exit node** — route all traffic through your home internet connection
- **Both** — subnet routing + exit node at the same time
- Self-healing: survives reboots, re-creates init scripts, cleans stale routing rules
- Safe: automatically reverts all changes if setup breaks your internet
- Auto-updates weekly via cron

## Prerequisites

- Alta Labs Route 10 router
- [Tailscale](https://tailscale.com) account (free for personal use)
- SSH access to the router (add your key at [manage.alta.inc](https://manage.alta.inc) > Settings > System > SSH Keys)

## Quick Start

SSH into your router:
```sh
ssh root@192.168.1.1
```

Then download and run the installer:
```sh
wget -O /tmp/setup.sh https://raw.githubusercontent.com/antonioacg/alta-route10-tailscale/main/setup.sh
# Self-hosted Headscale (this fork): prefix with your control-plane URL:
#   LOGIN_SERVER=https://vpn.example.com sh /tmp/setup.sh
sh /tmp/setup.sh
```

If `wget` fails (can happen if DNS hasn't initialized yet after a reboot), transfer the file from your computer instead:
```sh
# Run this on your PC, not the router:
scp setup.sh root@192.168.1.1:/tmp/setup.sh

# Then on the router:
sh /tmp/setup.sh
```

The installer will:
1. Check your router is compatible (TUN support, storage space, internet)
2. Ask you to pick a mode (subnet router, exit node, or both)
3. Download and install Tailscale binaries
4. Open a browser login URL to authenticate with Tailscale
5. Add firewall rules for traffic forwarding
6. Verify everything works (with automatic rollback if internet breaks)
7. Set up boot persistence and weekly auto-updates

## Modes

### Subnet Router (mode 1)
Access your LAN devices from any Tailscale device. Your phone on cell data can reach your Plex server, printer, cameras, etc. Remote devices still use their own internet.

### Exit Node (mode 2)
Route all traffic from a remote Tailscale device through your home internet. Appears as if you're browsing from home. Useful for ad blocking or accessing geo-restricted content.

### Both (mode 3)
Combines subnet routing and exit node. Remote devices can access your LAN AND route all traffic through your home connection.

## Commands

All commands use the same `setup.sh` script:

```sh
sh setup.sh             # Run the installer
sh setup.sh status      # Check Tailscale status
sh setup.sh recover     # Fix broken internet after a failed setup
sh setup.sh uninstall   # Remove everything completely
```

## After Setup

1. In the [Tailscale admin console](https://login.tailscale.com/admin/machines), find your router and approve:
   - The subnet route (e.g. 192.168.1.0/24) for subnet router mode
   - The exit node for exit node mode
2. On remote devices, enable "Use subnet routes" or "Use exit node" in Tailscale settings

**Important:** Devices already on your LAN subnet should NOT accept subnet routes — they'll lose direct LAN access. Only remote devices should accept routes.

## What Gets Installed

| File | Purpose |
|---|---|
| `/cfg/tailscale.env` | Version, mode, subnet config |
| `/a/tailscale/tailscale` | Tailscale CLI binary (~27MB) |
| `/a/tailscale/tailscaled` | Tailscale daemon binary (~27MB) |
| `/cfg/tailscaled.state` | Auth state (survives reboots) |
| `/etc/init.d/tailscale` | procd init script (autostart, recreated on boot) |
| `/cfg/tailscale-post-cfg.sh` | Boot script (re-creates init, adds firewall rules) |
| `/cfg/tailscale-update.sh` | Weekly auto-update script |

Binaries live on the `/a` partition (~880MB free) because Tailscale's static build (~54MB) doesn't fit on the smaller `/cfg` partition (~26MB).

## How It Works

### Firewall Rules

The installer adds iptables rules directly (not via uci, which doesn't work with tailscale0 on this firmware):

```
iptables -I INPUT -i tailscale0 -j ACCEPT
iptables -I FORWARD -o tailscale0 -j ACCEPT
iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -t nat -I POSTROUTING -s 100.64.0.0/10 -o br-lan -j MASQUERADE
```

For exit node mode, an additional MASQUERADE rule is added for the WAN interface.

### mwan3 Compatibility

The Alta Route 10 runs mwan3 (Multi-WAN Manager) which uses fwmark range `0x100/0x3f00`. Tailscale 1.82.0+ uses a different range (`0x80000/0xff0000`) that doesn't collide. The boot script also cleans up stale rules from older Tailscale versions that did collide.

### Boot Persistence

`/etc/init.d/` is on a RAM-based filesystem and gets wiped on reboot. The boot script (`tailscale-post-cfg.sh`) runs on every boot and:
1. Re-creates the init script
2. Cleans up stale ip routing rules
3. Re-applies iptables firewall rules
4. Starts tailscaled
5. Verifies internet is still working (reverts all changes if broken)

### Safety Net

- **During install**: If internet breaks after authentication, the installer automatically kills tailscaled, removes all iptables rules, and waits for internet to recover
- **On boot**: If tailscaled breaks internet after a reboot, the boot script reverts all changes
- **Recovery command**: `sh setup.sh recover` manually cleans up everything if the router gets into a bad state

## Firmware Updates

Firmware updates may wipe `/etc/init.d/` and `/cfg/`. After updating:

```sh
# Re-run the installer (will re-authenticate if state was wiped)
wget -O /tmp/setup.sh https://raw.githubusercontent.com/antonioacg/alta-route10-tailscale/main/setup.sh
# Self-hosted Headscale (this fork): prefix with your control-plane URL:
#   LOGIN_SERVER=https://vpn.example.com sh /tmp/setup.sh
sh /tmp/setup.sh
```

## Troubleshooting

**Internet broke after installing Tailscale**
The installer has automatic rollback — this shouldn't happen. If it does, run `sh setup.sh recover` or reboot the router.

**Can't reach LAN devices from phone**
- Make sure "Use subnet routes" is enabled in your phone's Tailscale app
- Approve the subnet route in the Tailscale admin console
- Try turning Tailscale off and back on on your phone

**Tailscale status shows "stopped"**
tailscaled may not be running. Check with `pidof tailscaled` and try `/etc/init.d/tailscale restart`.

**Device on same LAN can't reach router after setup**
That device may be accepting the subnet route through Tailscale instead of going direct. Run `tailscale set --accept-routes=false` on that device.

## Credits

- [Tailscale](https://tailscale.com) — WireGuard-based mesh VPN
- [Alta Labs](https://alta.inc) — Route 10 router

## License

MIT
