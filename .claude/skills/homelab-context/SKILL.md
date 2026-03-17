---
name: homelab-context
description: This skill should be used whenever the user asks about homelab hosts, NixOS configuration, services, deployments, secrets, DNS, VPN, media stack, networking, home-manager, dotfiles, or anything related to the bcrescimanno homelab-nix or dotfiles repositories. Provides full context about machines, architecture, conventions, and known quirks.
version: 1.0.0
---

# Homelab NixOS Context

This skill provides full situational awareness for the `homelab-nix` NixOS flake repository managing a Raspberry Pi 5 homelab.

## Repositories

- **Homelab**: `github:bcrescimanno/homelab-nix` (working dir: `/home/brian/code/homelab-nix`)
  - **Flake entry**: `flake.nix` — defines all NixOS host configs and `deploy-rs` nodes
  - **Deployment**: `deploy-rs` with magic rollback + auto rollback; `remoteBuild = true` (builds on Pi, not x86_64)
- **Dotfiles**: `github:bcrescimanno/dotfiles`
  - Home Manager configuration for all users; consumed as a flake input in `homelab-nix` and applied automatically on every deployment via the `home-manager` NixOS module
  - Active on all homelab hosts (`pirateship`, `rivendell`, `mirkwood`) and on local machines where Claude Code is run — assume the dotfiles repo state is available in the current environment
  - Machine-specific Home Manager configs live at `machines/{pirateship,rivendell,mirkwood}.nix` within the dotfiles repo
  - The `deploy` shell function is defined in `home/common.nix` in the dotfiles repo. It is a zsh function and is only available in interactive zsh sessions — not in subprocesses or non-interactive shells. The exact equivalent command to use in scripts or agents is: `nix run github:serokell/deploy-rs -- ~/code/homelab-nix#<hostname>`. The flake has `remoteBuild = true` so the build runs on the target Pi (aarch64), not locally (x86_64) — no extra flags needed.

## Hosts

| Host | IP | Hardware | Role |
|---|---|---|---|
| `pirateship` | — | Raspberry Pi 5 | Media stack: arr apps, Jellyfin, SABnzbd, gluetun VPN, Glances |
| `rivendell` | 10.0.1.9 | Raspberry Pi 5 8GB | Home Assistant, Matter Server, Caddy (reverse proxy + TLS), Blocky+Unbound DNS (secondary), NUT (UPS), ntfy, Gatus, Glances |
| `mirkwood` | — | Raspberry Pi 5 4GB | Blocky+Unbound DNS (primary), Homepage, Prometheus, Grafana, Glances |
| `erebor` | 10.0.1.22 | UniFi UNAS Pro 4 | NAS — 4×12TB RAID 6 (~24TB usable); NFS shares to pirateship; restic backup target |

## Module → Host Map

| Module | Host(s) | Key ports |
|---|---|---|
| `modules/arr-stack.nix` | pirateship | gluetun VPN kill switch; qbt 9091, radarr 7878, sonarr 8989, prowlarr 9696, lidarr 8686, sabnzbd 8080 (all via gluetun netns); jellyfin 8096 direct |
| `modules/caddy.nix` | rivendell | Wildcard TLS via Cloudflare DNS-01; all `*.theshire.io` vhosts |
| `modules/dns.nix` | rivendell + mirkwood | Blocky port 53 + 4000 (DoH/metrics); Unbound port 5335 localhost |
| `modules/gatus.nix` | rivendell | Port 8080; declarative health monitors + ntfy alerts |
| `modules/grafana.nix` | mirkwood | Prometheus 9090, Grafana 3001; scrapes Blocky metrics from both DNS hosts |
| `modules/homeassistant.nix` | rivendell | HA + Matter Server containers; `--privileged` + host networking for mDNS/USB |
| `modules/homepage.nix` | mirkwood | Port 3000; `services.homepage-dashboard` native NixOS module |
| `modules/monitoring.nix` | all hosts | Glances port 61208; native NixOS service |
| `modules/ntfy.nix` | rivendell | Port 2586 LAN; OCI container proxied via Caddy |
| `modules/nut.nix` | rivendell | Tripp Lite SMC15002URM via USB; port 3493; vendorid=09AE productid=3015 |
| `modules/backup.nix` | all hosts | restic → erebor NFS (local) + Cloudflare R2 (offsite); paths per-host via `homelab.backup.paths` |
| `modules/base.nix` | all hosts | Shared: user accounts, SSH, firewall, Podman, auto-upgrade at 4am, ntfy upgrade notifications |

## Key Conventions

### Guiding Principle: Prefer Declarative Services

Always reach for `services.foo` NixOS modules before OCI containers. If a container is unavoidable, keep as much config as possible in the Nix declaration. Secrets must always go through sops-nix — never hardcode credentials (world-readable in `/nix/store` and in git history).

### Secrets (sops-nix)

Secrets are encrypted with age, rendered at runtime to `/run/secrets/`. Edit with:
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/<host>.yaml
```

| File | Keys |
|---|---|
| `secrets/pirateship.yaml` | `vpn_env`, `qbt_credentials` (QBT_USERNAME/QBT_PASSWORD), `recyclarr_env` (SONARR_API_KEY/RADARR_API_KEY) |
| `secrets/rivendell.yaml` | `caddy_cloudflare_env` (CLOUDFLARE_API_TOKEN), `nut_upsmon_password`, `nut_ha_password` |
| `secrets/mirkwood.yaml` | `grafana_env` (GF_SECURITY_ADMIN_PASSWORD) |

### Deploy

```bash
deploy              # all hosts
deploy pirateship   # specific host
# fallback:
nixos-rebuild switch --flake .#<host> --target-host brian@<host> --build-host brian@<host> --sudo
```

### Flake Check

```bash
nix flake check --no-build   # also runs as pre-commit hook
```

## Known Quirks and Hard-Won Lessons

### qBittorrent in gluetun's network namespace

**Use `Session\Interface=<tun0_IP>`, not `"tun0"` (name) or `""` (any).**

- `Interface=tun0` (name): libtorrent 5.x fails to bind to TUN devices by name → zero UDP sockets, DHT dead.
- `Interface=""` (any): libtorrent binds to eth0 (10.88.0.12); gluetun policy rule 100 routes that traffic out eth0, then iptables DROPs it. DHT dead.
- `Interface=10.2.0.2` (tun0's actual IP): works. libtorrent binds sockets to the VPN IP; traffic hits policy rule 101 → table 51820 → tun0.

The `preStart` hook in `arr-stack.nix` resolves tun0's IP dynamically via `podman exec gluetun ip addr show tun0` on every restart. It also strips and re-adds `Session\Interface` because qBittorrent 5.x overwrites it on graceful shutdown.

### Caddy on rivendell

- Use `127.0.0.1` (not `localhost`) for local backends — HA's `trusted_proxies` uses IPv4 and `localhost` resolves to `::1`.
- `tls { dns cloudflare ... resolvers 1.1.1.1 8.8.8.8 }` must be **per-vhost** in Caddy 2.10.x, not global. `resolvers` requires the dns provider block in the same `tls {}` block.
- Caddy plugin hash is pinned to rivendell's nixpkgs version (caddy 2.10.2), not the local dev machine's nixpkgs.

### DNS split-horizon

Blocky conditionally forwards `.theshire.io` to the UDM Pro at 10.0.1.1, which holds the authoritative records. `.local` has been eliminated from the homelab.

### IoT VLAN — Wake-on-LAN

rivendell has `eth0.4` (VLAN 4, `10.0.12.2/22`). HA WoL integrations targeting IoT devices must use `broadcast_address: 10.0.15.255` — not `255.255.255.255`, which stays on the main VLAN.

### Home Manager overlay

`flake.nix` patches `neovimUtils.makeVimPackageInfo` from the dotfiles nixpkgs into system nixpkgs. Workaround for `nixos-raspberrypi` pinning an older nixpkgs. Remove once nixos-raspberrypi updates its pin past Feb 2026; also restore `inputs.nixpkgs.follows = "nixpkgs"` to the home-manager input.

### Homepage `allowedHosts`

Must include every hostname/IP used to reach it — easy to miss when adding a new Caddy vhost.

### Auto-upgrade

All hosts pull and apply from `github:bcrescimanno/homelab-nix` daily at 4am. ntfy notifications sent to `http://rivendell:2586/homelab` on success or failure.

## Open / Pending Work

- **arr apps**: Radarr, Sonarr, Prowlarr, Lidarr download clients need switching from Transmission → qBittorrent (host: localhost, port: 9091, creds from `qbt_credentials` sops secret)
- **Thread border router**: Home Assistant Connect ZBT-2 ordered. When it arrives: add OTBR container to `modules/homeassistant.nix` (`--privileged` + host networking), configure HA Thread integration.
- **Loki (deferred)**: Blocky Prometheus metrics lack per-client response labels. Per-client blocked/successful breakdown requires Loki + Promtail ingesting `/var/log/blocky/*.log`. Plan: Loki on rivendell (8GB), Promtail on rivendell+mirkwood, 7-day retention, Loki datasource in Grafana on mirkwood.
- **SSO (Authelia)**: plan complete, implementation deferred — see `memory/sso-plan.md`
- **Backup restore dry run**: test restic restores from both erebor NFS and Cloudflare R2
- **NixOS personal machines**: trial on G14 2024 laptop first (AMD + RTX 4060/4070, currently Arch); also desktop (RTX 5090, Arch) and terra (living room, Ryzen 7 5700X3D + RTX 5070 Ti, needs full BT controller support)
