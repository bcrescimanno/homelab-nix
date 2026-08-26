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
| `pirateship` | Raspberry Pi 5 | Media stack (arr apps, Jellyfin, SABnzbd, Navidrome, gluetun VPN), Glances |
| `rivendell` | Raspberry Pi 5, 8GB | Home Assistant, Matter Server, Caddy (reverse proxy + TLS), Blocky+Unbound DNS (secondary), NUT (UPS), ntfy, Gatus, Glances |
| `mirkwood` | Raspberry Pi 5, 4GB | Blocky+Unbound DNS (primary), Homepage, Prometheus, Grafana, Glances |
| `erebor` | UniFi UNAS Pro 4 | NAS — 4×12TB RAID 6 (~24TB usable); NFS shares for pirateship media + restic backups |

## Architecture

### Module Structure

- `flake.nix` — entry point; defines NixOS configurations and deploy-rs nodes for all three hosts
- `hosts/{pirateship,rivendell,mirkwood}.nix` — machine-specific config: hostname, disk layout (disko), networking, SOPS secret declarations, home-manager user config, backup paths
- `modules/base.nix` — shared config for all devices: user accounts, SSH, firewall, Podman, auto-upgrade, ntfy upgrade notifications, common packages
- `modules/arr-stack.nix` — pirateship media stack containers (gluetun VPN kill switch, qbittorrent, radarr, sonarr, prowlarr, lidarr, recyclarr, sabnzbd, jellyfin); `qbittorrent-port-sync` systemd service syncs the gluetun forwarded port to qBittorrent
- `modules/lidarr-formats.nix` — declarative Lidarr custom formats + profile scores, synced to the API by the `lidarr-format-sync` oneshot (`modules/lidarr-format-sync.py`). Lidarr has **no TRaSH guide and no Recyclarr support**, so this is the stand-in; scoring is tuned to Redacted's release-title format. See the comment block in the module before changing scores.
- `modules/navidrome.nix` — Navidrome music streaming server on pirateship (native NixOS service, port 4533); Subsonic-compatible API for WiiM/Symfonium clients; music library at `/var/lib/media/music`
- `modules/backup.nix` — restic backups to erebor NFS (local) and Cloudflare R2 (offsite); paths declared per-host via `homelab.backup.paths`
- `pkgs/materialious.nix` / `pkgs/caddy-cloudflare.nix` — the two pins no Renovate manager can see (a `fetchFromGitHub` tag and an FOD hash over the Go module graph). Exposed as flake outputs (`.#materialious`, `.#caddy-cloudflare`) so `scripts/refresh-pins` can update them with `nix-update` and a `lib.fakeHash` rebuild; `.github/workflows/refresh-pins.yml` runs it weekly and opens a PR. Read `pkgs/materialious.nix`'s header before merging a version bump — its build workarounds are upstream-behaviour-dependent.
- `modules/caddy.nix` — Caddy reverse proxy on rivendell; wildcard TLS via Cloudflare DNS-01; proxies all `*.theshire.io` vhosts
- `modules/dns.nix` — Blocky (port 53 + port 4000 DoH/metrics) + Unbound (port 5335, localhost) on both rivendell and mirkwood; fully declarative, replaces Technitium
- `modules/flake-freshness.nix` — daily on rivendell (09:00): alerts when the inputs **this system was built from** fall >10 days behind upstream. Revisions are read from `flake.lock` at eval time and baked in, so it measures what is RUNNING, not what is on main. Only alarms when the locked rev *differs* from upstream's head — `disko` sat 77 days old and perfectly current. A fetch failure is reported, never treated as an all-clear.
- `modules/gatus.nix` — Gatus service health monitor on rivendell (native NixOS service, port 8080); all monitors declared in Nix, alerts via ntfy
- `modules/grafana.nix` — Prometheus (port 9090) + Grafana (port 3001) on mirkwood; scrapes Blocky metrics from both DNS hosts
- `modules/homeassistant.nix` — Home Assistant (native `services.home-assistant`), Matter Server (container) and OTBR (native `services.openthread-border-router`) on rivendell. HA reuses the container-era config dir via `configDir = /var/lib/homeassistant/config`, so `.storage` — every UI-created integration, device and dashboard — carries over untouched and the UI stays fully usable; only `configuration.yaml` becomes a read-only store symlink. **`extraComponents` is load-bearing**: integrations added through the UI live in `.storage`, which the module cannot see, so each one's domain must be listed or its Python deps are missing at runtime. Regenerate with the jq command in the module header. Matter Server is deliberately still a container — see the comment block before retrying `services.matter-server`
- `modules/ha-window-notifications.nix` — passive-cooling window prompts on rivendell (close above 66°F in the morning, open below 72°F in the evening, both suppressed by a sub-75°F forecast high in favour of one 08:00 "windows open day" message). The close threshold is 66 rather than 68 as **margin for the met.no fallback, which publishes whole degrees hourly** — a strict `above: 68` silently fired nothing on a 96°F day because the sensor read exactly 68.0. Raise it back toward 68 once the Eve Weather is paired. Declared as a **Home Assistant package** under `services.home-assistant.config.homeassistant.packages.windows`, which merges additively with the UI-authored `automations.yaml` — a package is used rather than a bare automation include because it can also declare the two `template:` sensors. The automations read `sensor.outdoor_temperature`, never the hardware entity, so swapping the source is a one-line change. See the comment block in the module before touching the thresholds or the fallback behaviour.
- `scripts/check-overlays` / `.github/workflows/check-overlays.yml` — weekly probe asking whether each temporary overlay in `flake.nix` can be deleted, by building the package **unpatched** against the current lock. The list lives in `flake.nix` as `overlayWorkarounds` — **add an entry whenever you add an overlay.** Runs on rivendell because three of the four failures only reproduce on aarch64. Replaced `modules/nixpkgs-watch.nix`, which never worked: it fetched a 302 URL with `curl -sf` and no `-L`, got an empty body, and its own `[ -z "$REV" ] && exit 0` guard swallowed it while the unit reported success.
- `modules/homepage.nix` — Homepage dashboard as native NixOS service via `services.homepage-dashboard` (mirkwood, port 3000)
- `modules/monitoring.nix` — Glances system monitor as native NixOS service (all three hosts, port 61208)
- `modules/music-sync.nix` — keeps Lidarr, Navidrome and Music Assistant in step with `/var/lib/media/music`. **Every filesystem watcher on that share is inert** (NFS + a remote writer, same root cause as Jellyfin/Bazarr), so `music-sync.timer` polls the ~278 *directory* mtimes every 2 min (0.2–1s), debounces one interval so a half-copied album is never scanned, then issues a targeted `RefreshArtist` per changed artist plus `music/sync` to Music Assistant. `music-library-audit.timer` runs daily: it repoints Lidarr artists whose folder drifted from disk and ntfy's about folders needing a manual Library Import. Runs on the pirateship **host**, not in gluetun's netns — see the module comment.
- `modules/qbittorrent-seed-policy.nix` — seeding policy on pirateship, reconciled every 5 min by `modules/qbittorrent-seed-policy.py`. Keyed on each torrent's **`private` flag**, never the tracker hostname (the `tracker` field reports whichever tracker last answered and rotates). Private → ratio `-1`, action `Stop`, upload uncapped (seed forever). Public → ratio `1.0`, action `RemoveWithContent`, upload capped. Global ratio limit stays **off** and the global action stays **Stop**, so anything unclassified defaults to seeding forever rather than being deleted. See the module comment before changing any of it.
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

### Container Stack (arr-stack.nix)

All arr containers share gluetun's network namespace (`--network=container:gluetun`). If the VPN drops, all dependent containers lose internet access — this is the kill switch.

- **gluetun**: ProtonVPN WireGuard gateway; holds all exposed ports for the arr containers
- **qbittorrent**: torrent client (port 9091 via gluetun); image `lscr.io/linuxserver/qbittorrent:libtorrentv1`; `dl.theshire.io` via Caddy
- **sabnzbd**: Usenet client (port 8080 via gluetun)
- **radarr/sonarr/prowlarr/lidarr**: media managers (ports 7878/8989/9696/8686 via gluetun)
- **recyclarr**: native NixOS service (not a container), daily, syncs TRaSH quality profiles + custom formats to radarr/sonarr; API keys via sops secrets `recyclarr_radarr_api_key`/`recyclarr_sonarr_api_key`. Exactly **one guide "(Combined)" profile per app** — Radarr `Remux 2160p (Combined)`, Sonarr `WEB-2160p (Combined)`. See the comment block in `arr-stack.nix` for why single-resolution profiles were dropped.
- **jellyfin**: media server (port 8096, direct — not through VPN)
- **navidrome**: music streaming server (port 4533, native NixOS service — not a container, not through VPN); declared in `modules/navidrome.nix`

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

**Thread border router**: Home Assistant Connect ZBT-2 runs via native `services.openthread-border-router` in `modules/homeassistant.nix` (migrated off the container 2026-08-01); ZBT-2 at `/dev/ttyACM0` (Thread RCP firmware); OTBR REST API at `localhost:8081`. The container's NAT64/DOCKER-disabled workaround is gone and must not be reintroduced — it existed only because the `openthread/otbr` image shells out to iptables-legacy, which fails on NixOS; the native module runs otbr-firewall with the host's own `networking.firewall.package` instead.

### DNS (dns.nix)

Blocky handles ad blocking, conditional forwarding (`.theshire.io` → UDM Pro at 10.0.1.1), DoH, and Prometheus metrics. Unbound handles recursive resolution to root servers.

### Reverse Proxy (caddy.nix)

Caddy runs on rivendell with the Cloudflare DNS plugin for DNS-01 ACME. All `*.theshire.io` services are proxied with automatic TLS. Key vhosts:
- Local backends (`127.0.0.1`): ha, ntfy, monitor, doh, rivendell-stats
- mirkwood backends: homepage, grafana, mirkwood-stats
- pirateship backends: jellyfin, dl, nzb, movies, tv, prowlarr, music, listen, pirateship-stats

### Secrets

Secrets use `sops-nix` with age encryption. Rendered at runtime to `/run/secrets/`.

**pirateship** (`secrets/pirateship.yaml`):
- `vpn_env` — WireGuard credentials for gluetun
- `qbt_credentials` — `QBT_USERNAME`/`QBT_PASSWORD` (used by preStart to generate PBKDF2 hash and by qbittorrent-port-sync)
- `recyclarr_radarr_api_key` / `recyclarr_sonarr_api_key` — API keys for the recyclarr sync
- `jellyfin_api_key` — used by `jellyfin-notify-sync` to configure the library-update push in radarr/sonarr/bazarr
- `ma_token` — long-lived Music Assistant API token, used by `music-sync` to trigger `music/sync` on rivendell

**rivendell** (`secrets/rivendell.yaml`):
- `caddy_cloudflare_env` — `CLOUDFLARE_API_TOKEN` for DNS-01 ACME
- `nut_upsmon_password` — internal upsmon user password
- `nut_ha_password` — Home Assistant NUT integration password
- `github_runner_token` — registration credential for the aarch64 CI runner
- `gatus_github_token` — `GATUS_GITHUB_TOKEN=<fine-grained PAT>`; read-only (Administration: Read) token Gatus uses to check both self-hosted runners are online

**mirkwood** (`secrets/mirkwood.yaml`):
- `grafana_env` — `GF_SECURITY_ADMIN_PASSWORD`

### Auto-Upgrade

All hosts pull and apply updates from `github:bcrescimanno/homelab-nix` daily at 4am. ntfy notifications are sent on success or failure (`http://rivendell:2586/homelab`).

### Media Storage

Media lives on a single erebor NFS share, mounted on pirateship via `fileSystems` in `pirateship.nix`:
- `/var/lib/media` — single NFS mount from erebor (`/var/nfs/shared/media`); contains subdirectories `movies/`, `tv/`, `music/`, `torrents/`, `usenet/`
- `/var/lib/<service>/config` — per-service config directories (local, declared via `systemd.tmpfiles.rules`)

All subdirectories share the same filesystem, enabling hardlinks between them. **Radarr and Sonarr** have `copyUsingHardlinks = true` — imports from `torrents/` are hardlinked into the library at zero additional disk cost, so qBittorrent keeps seeding the original (94.8 of 96.7 GiB of video under `torrents/` is shared inodes).

**Lidarr deliberately has `copyUsingHardlinks = false` — do not "fix" this.** It runs `writeAudioTags = "newFiles"` with `embedCoverArt = true`, so it rewrites tags on import; through a hardlink that would rewrite the file qBittorrent is seeding and fail the torrent's hash check. Music therefore costs a real second copy (19.8 GiB today) and that is the price of seeding Redacted forever.
