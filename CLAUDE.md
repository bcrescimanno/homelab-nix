# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NixOS flake for a Raspberry Pi 5 homelab. Manages three hosts: `pirateship` (media stack), `rivendell` (Home Assistant, Caddy reverse proxy, secondary DNS, UPS monitoring), and `mirkwood` (primary DNS, Homepage, Grafana). Media storage is on `erebor` (UniFi UNAS Pro 4 NAS) via NFS mounts on pirateship.

Uses `nixos-raspberrypi` for Pi-specific hardware support, `disko` for declarative disk partitioning, `sops-nix` for secrets management, `deploy-rs` for deployments with magic rollback, and `home-manager` (via the dotfiles flake) for user environment configuration.

## Guiding Principle: Prefer Declarative Services

**Always prefer software that can be fully configured via NixOS modules over software that requires imperative setup (web UI, API calls, restore scripts).** Concretely:

- Use native NixOS services (`services.foo`) over OCI containers where a good module exists
- When evaluating new services for the homelab, check nixpkgs for a `services.*` module first
- Avoid services whose configuration lives entirely in a database or web UI with no config-file equivalent (e.g., the reason Uptime Kuma was replaced by Gatus)
- If a container is unavoidable, keep as much config as possible in the Nix declaration (environment variables, volume mounts, inline config files via `pkgs.writeText`)
- Secrets must always go through sops-nix — never hardcode credentials in Nix files (they end up world-readable in `/nix/store` and in the public git history)

## Common Commands

```bash
# Check the flake for errors (also runs automatically as a pre-commit hook)
nix flake check --no-build

# Update flake inputs (nixpkgs, etc.)
nix flake update

# Deploy to a Pi via deploy-rs (magic rollback + auto rollback, builds on Pi)
deploy pirateship
deploy rivendell
deploy mirkwood
deploy              # all hosts

# Fallback raw form if deploy-rs is unavailable:
nixos-rebuild switch --flake .#<host> --target-host brian@<host> --build-host brian@<host> --sudo

# Initial install via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- --flake .#pirateship root@<ip>

# Edit encrypted secrets
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
```

## Hosts

| Host | Hardware | Role |
|---|---|---|
| `pirateship` | Raspberry Pi 5 | Media stack (arr apps, Jellyfin, SABnzbd, gluetun VPN), Glances |
| `rivendell` | Raspberry Pi 5, 8GB | Home Assistant, Matter Server, Caddy (reverse proxy + TLS), Blocky+Unbound DNS (secondary), NUT (UPS), ntfy, Gatus, Glances |
| `mirkwood` | Raspberry Pi 5, 4GB | Blocky+Unbound DNS (primary), Homepage, Prometheus, Grafana, Glances |
| `erebor` | UniFi UNAS Pro 4 | NAS — 4×12TB RAID 6 (~24TB usable); NFS shares for pirateship media + restic backups |

## Architecture

### Module Structure

- `flake.nix` — entry point; defines NixOS configurations and deploy-rs nodes for all three hosts
- `hosts/{pirateship,rivendell,mirkwood}.nix` — machine-specific config: hostname, disk layout (disko), networking, SOPS secret declarations, home-manager user config, backup paths
- `modules/base.nix` — shared config for all devices: user accounts, SSH, firewall, Podman, auto-upgrade, ntfy upgrade notifications, common packages
- `modules/arr-stack.nix` — pirateship media stack containers (gluetun VPN kill switch, qbittorrent, radarr, sonarr, prowlarr, lidarr, recyclarr, sabnzbd, jellyfin); `qbittorrent-port-sync` systemd service syncs the gluetun forwarded port to qBittorrent
- `modules/backup.nix` — restic backups to erebor NFS (local) and Cloudflare R2 (offsite); paths declared per-host via `homelab.backup.paths`
- `modules/caddy.nix` — Caddy reverse proxy on rivendell; wildcard TLS via Cloudflare DNS-01; proxies all `*.theshire.io` vhosts
- `modules/dns.nix` — Blocky (port 53 + port 4000 DoH/metrics) + Unbound (port 5335, localhost) on both rivendell and mirkwood; fully declarative, replaces Technitium
- `modules/gatus.nix` — Gatus service health monitor on rivendell (native NixOS service, port 8080); all monitors declared in Nix, alerts via ntfy
- `modules/grafana.nix` — Prometheus (port 9090) + Grafana (port 3001) on mirkwood; scrapes Blocky metrics from both DNS hosts
- `modules/homeassistant.nix` — Home Assistant + Matter Server containers on rivendell (host networking for mDNS); both containers use `--privileged` so USB dongles (Zigbee, Thread) are auto-accessible
- `modules/homepage.nix` — Homepage dashboard as native NixOS service via `services.homepage-dashboard` (mirkwood, port 3000)
- `modules/monitoring.nix` — Glances system monitor as native NixOS service (all three hosts, port 61208)
- `modules/ntfy.nix` — ntfy push notification server container on rivendell (port 2586 LAN, proxied via Caddy)
- `modules/nut.nix` — Network UPS Tools monitoring Tripp Lite SMC15002URM via USB (rivendell); exposes port 3493 for Home Assistant

### Deploy (deploy-rs)

`deploy-rs` is configured in `flake.nix` under `deploy.nodes`. The `deploy` shell function in dotfiles (`home/common.nix`) wraps it. All profiles use:
- `remoteBuild = true` — builds on the Pi (avoids x86_64 → aarch64 cross-compilation)
- `sshUser = "brian"`, `user = "root"`
- `magicRollback = true` — rolls back if SSH is lost during activation
- `autoRollback = true` — rolls back if the activation script exits non-zero

### Home Manager

User dotfiles are managed via the `home-manager` NixOS module, pulling from the `github:bcrescimanno/dotfiles` flake. Each host imports its machine config (`machines/{pirateship,rivendell,mirkwood}.nix`). Home Manager runs automatically as part of deployment — no separate `hm` invocation needed.

> **Note:** `flake.nix` includes a `nixpkgs.overlays` patch to inject `neovimUtils.makeVimPackageInfo` from the dotfiles nixpkgs. Workaround for `nixos-raspberrypi` pinning an older nixpkgs. Remove once `nixos-raspberrypi` updates its pin past Feb 2026.

### Container Stack (arr-stack.nix)

All arr containers share gluetun's network namespace (`--network=container:gluetun`). If the VPN drops, all dependent containers lose internet access — this is the kill switch.

- **gluetun**: ProtonVPN WireGuard gateway; holds all exposed ports for the arr containers
- **qbittorrent**: torrent client (port 9091 via gluetun); image `lscr.io/linuxserver/qbittorrent:libtorrentv1`; `dl.theshire.io` via Caddy
- **sabnzbd**: Usenet client (port 8080 via gluetun)
- **radarr/sonarr/prowlarr/lidarr**: media managers (ports 7878/8989/9696/8686 via gluetun)
- **recyclarr**: syncs TRaSH quality profiles to radarr/sonarr; API keys via sops secret `recyclarr_env`
- **jellyfin**: media server (port 8096, direct — not through VPN)

#### qBittorrent + gluetun: how it works

qBittorrent (libtorrent-rasterbar) requires careful setup to work in gluetun's network namespace. The `podman-qbittorrent` systemd service has a `preStart` hook (in `arr-stack.nix`) that:

1. **Resolves tun0's IP and sets `Session\Interface=<IP>`** — This is the critical one. Three approaches were tried and only one works:
   - `Interface=tun0` (name): libtorrent 5.x fails to bind to TUN devices by name → zero UDP sockets, DHT dead.
   - `Interface=""` (any): libtorrent enumerates physical interfaces only, creating sockets on eth0 (10.88.0.12). gluetun policy rule 100 routes `from 10.88.0.12 → table 200 → eth0`, which iptables then DROPs for external destinations. DHT still dead.
   - `Interface=10.2.0.2` (tun0's IP, resolved each restart via `podman exec gluetun ip addr show tun0`): libtorrent binds sockets to that IP. Traffic from 10.2.0.2 hits policy rule 101 (non-fwmark → table 51820 → default dev tun0) and routes correctly through the VPN. **This works.**
   - Fallback IP source: parses `WIREGUARD_ADDRESSES` from `/run/secrets/vpn_env` if `podman exec gluetun` fails.
   - Note: qBittorrent 5.x saves `Session\Interface` on graceful shutdown, re-writing the value. The preStart strips it and re-adds the fresh IP on every restart — this is required.
2. **Generates a PBKDF2-SHA512 password hash** from `QBT_PASSWORD` in `qbt_credentials` and writes it to `qBittorrent.conf` — prevents the linuxserver init from regenerating an unknown default password on every start.
3. **Sets `WebUI\LocalHostAuth=false`** — prevents arr apps (connecting via localhost inside gluetun's netns) from triggering IP bans.
4. **Clears `WebUI\BanList`** on every restart — prevents ban-loop from stale login attempts persisting across restarts.
5. **Waits up to 90s for `/var/lib/gluetun/tmp/forwarded_port`** — ensures tun0 is up and port forwarding is active before qBittorrent initializes libtorrent.

The `qbittorrent-port-sync` systemd service (runs continuously, `Restart=always`) keeps the forwarded port synced into qBittorrent via the API every 5 minutes. It reads credentials from the `qbt_credentials` sops secret.

The `qbt_credentials` sops secret must contain `QBT_USERNAME` and `QBT_PASSWORD`. After changing the WebUI password, update the secret and redeploy.

**gluetun's routing for reference:**
- Policy rule 98: traffic to 10.88.0.0/16 → main table (container bridge, direct)
- Policy rule 100: traffic from 10.88.0.12 (gluetun itself) → table 200 → eth0 (for WireGuard UDP)
- Policy rule 101: all other traffic without fwmark 0xca6c → table 51820 → default dev tun0 (VPN)
- iptables OUTPUT: allows tun0 (all), blocks eth0 (except bridge + WireGuard UDP to VPN server)

### IoT VLAN — Wake-on-LAN (hosts/rivendell.nix)

rivendell has a `eth0.4` tagged VLAN subinterface (VLAN ID 4, `10.0.12.2/22`) on its existing ethernet port. This gives Home Assistant the ability to send WoL magic packet broadcasts directly onto the IoT VLAN (broadcast address `10.0.15.255`) without rivendell being a member of the IoT network. The UniFi switch port uses "Allow All" tagged VLANs, so no controller changes were required. The NixOS firewall default-drops inbound on `eth0.4`, preventing IoT devices from reaching rivendell's services.

HA WoL integrations targeting IoT VLAN devices must set `broadcast_address: 10.0.15.255` (not `255.255.255.255`, which stays on the main VLAN).

**Pending — Thread border router**: Home Assistant Connect ZBT-2 USB dongle ordered. When it arrives, add an OTBR (OpenThread Border Router) container to `modules/homeassistant.nix` (`--privileged` + host networking, same as HA/Matter Server), then configure HA's Thread integration to point at it.

### DNS (dns.nix)

Blocky handles ad blocking, conditional forwarding (`.theshire.io` → UDM Pro at 10.0.1.1), DoH, and Prometheus metrics. Unbound handles recursive resolution to root servers.

### Reverse Proxy (caddy.nix)

Caddy runs on rivendell with the Cloudflare DNS plugin for DNS-01 ACME. All `*.theshire.io` services are proxied with automatic TLS. Key vhosts:
- Local backends (`127.0.0.1`): ha, ntfy, monitor, doh, rivendell-stats
- mirkwood backends: home, grafana, mirkwood-stats
- pirateship backends: jellyfin, dl, nzb, movies, tv, prowlarr, music, pirateship-stats

### Secrets

Secrets use `sops-nix` with age encryption. Rendered at runtime to `/run/secrets/`.

**pirateship** (`secrets/pirateship.yaml`):
- `vpn_env` — WireGuard credentials for gluetun
- `qbt_credentials` — `QBT_USERNAME`/`QBT_PASSWORD` (used by preStart to generate PBKDF2 hash and by qbittorrent-port-sync)
- `recyclarr_env` — `SONARR_API_KEY`/`RADARR_API_KEY`

**rivendell** (`secrets/rivendell.yaml`):
- `caddy_cloudflare_env` — `CLOUDFLARE_API_TOKEN` for DNS-01 ACME
- `nut_upsmon_password` — internal upsmon user password
- `nut_ha_password` — Home Assistant NUT integration password

**mirkwood** (`secrets/mirkwood.yaml`):
- `grafana_env` — `GF_SECURITY_ADMIN_PASSWORD`

### Auto-Upgrade

All hosts pull and apply updates from `github:bcrescimanno/homelab-nix` daily at 4am. ntfy notifications are sent on success or failure (`http://rivendell:2586/homelab`).

### Media Storage

Media lives on erebor NFS shares, mounted on pirateship via `fileSystems` in `pirateship.nix`:
- `/var/lib/media/{movies,tv,music,torrents,usenet}` — NFS mounts from erebor
- `/var/lib/<service>/config` — per-service config directories (local, declared via `systemd.tmpfiles.rules`)
