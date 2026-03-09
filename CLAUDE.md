# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NixOS flake for a Raspberry Pi 5 homelab. Manages three hosts: `pirateship` (media stack), `rivendell` (Home Assistant, NPM, secondary DNS, UPS monitoring), and `mirkwood` (primary DNS, Homepage). A NAS will be added in future, at which point media storage (currently on local disk under `/var/lib/media/`) will move there along with backup configuration.

Uses `nixos-raspberrypi` for Pi-specific hardware support, `disko` for declarative disk partitioning, `sops-nix` for secrets management, and `home-manager` (via the dotfiles flake) for user environment configuration.

## Common Commands

```bash
# Check the flake for errors (also runs automatically as a pre-commit hook)
nix flake check --no-build

# Update flake inputs (nixpkgs, etc.)
nix flake update

# Deploy to a Pi (run from dev machine using the deploy shell function)
deploy pirateship
deploy rivendell
deploy mirkwood

# Full nixos-rebuild form (what `deploy` wraps):
nixos-rebuild switch --flake .#pirateship --target-host brian@pirateship --build-host brian@pirateship --sudo
nixos-rebuild switch --flake .#rivendell --target-host brian@rivendell --build-host brian@rivendell --sudo
nixos-rebuild switch --flake .#mirkwood --target-host brian@mirkwood --build-host brian@mirkwood --sudo

# Initial install via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- --flake .#pirateship root@<ip>

# Edit encrypted secrets
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
```

## Hosts

| Host | Hardware | Status | Role |
|---|---|---|---|
| `pirateship` | Raspberry Pi 5 | Live on NixOS | Media stack (arr apps, Jellyfin, VPN) |
| `rivendell` | Raspberry Pi 5, 8GB | Live on NixOS | Home Assistant, Matter Server, Nginx Proxy Manager, Technitium (secondary DNS), NUT (UPS), Glances |
| `mirkwood` | Raspberry Pi 5, 4GB | Live on NixOS | Technitium (primary DNS), Homepage, Glances |

## Architecture

### Module Structure

- `flake.nix` — entry point; defines NixOS configurations for all three hosts; includes home-manager and dotfiles as inputs
- `hosts/{pirateship,rivendell,mirkwood}.nix` — machine-specific config: hostname, disk layout (disko), networking, SOPS secret declarations, and home-manager user config
- `modules/base.nix` — shared config for all devices: user accounts, SSH, firewall, Podman setup, auto-upgrade, common packages
- `modules/arr-stack.nix` — pirateship media stack containers; recyclarr config is declared inline as a Nix derivation
- `modules/dns.nix` — Technitium DNS container (rivendell + mirkwood)
- `modules/homeassistant.nix` — Home Assistant + Matter Server containers (rivendell)
- `modules/proxy.nix` — Nginx Proxy Manager container (rivendell)
- `modules/homepage.nix` — Homepage dashboard as native NixOS service via `services.homepage-dashboard` (mirkwood)
- `modules/monitoring.nix` — Glances system monitor as native NixOS service (all three hosts)
- `modules/nut.nix` — Network UPS Tools monitoring Tripp Lite SMC15002URM via USB (rivendell); exposes port 3493 for Home Assistant
- `scripts/configure-technitium.sh` — post-install API script to configure Technitium (blocklists, zones, zone sync, query logging)

### Home Manager

User dotfiles are managed via the `home-manager` NixOS module, pulling from the `github:bcrescimanno/dotfiles` flake. Each host imports its machine config:

- `pirateship` → `machines/pirateship.nix` (common + dev-tools + headless)
- `rivendell` → `machines/rivendell.nix` (common + headless)
- `mirkwood` → `machines/mirkwood.nix` (common + headless)

Home Manager runs automatically as part of `nixos-rebuild switch` — no separate `hm` invocation needed on these hosts.

> **Note:** `flake.nix` includes a `nixpkgs.overlays` patch to inject `neovimUtils.makeVimPackageInfo` from the dotfiles nixpkgs. This works around `nixos-raspberrypi` pinning an older nixpkgs that predates the function. Remove once `nixos-raspberrypi` updates its pin past Feb 2026.

### Container Stack (arr-stack.nix)

All arr containers (`transmission`, `radarr`, `sonarr`, `prowlarr`, `lidarr`, `recyclarr`) share gluetun's network namespace (`--network=container:gluetun`). This means gluetun acts as a VPN kill switch — if the VPN drops, all dependent containers lose internet access.

- **gluetun**: ProtonVPN WireGuard gateway; holds all exposed ports for the arr containers
- **transmission**: torrent client (port 9091 via gluetun)
- **radarr/sonarr/prowlarr/lidarr**: media managers (ports 7878/8989/9696/8686 via gluetun)
- **recyclarr**: syncs TRaSH quality profiles to radarr/sonarr; config declared in `arr-stack.nix` via `pkgs.writeText`
- **jellyfin**: media server (port 8096, direct — not through VPN)
- **portainer-agent**: connects to a Portainer instance elsewhere (port 9001, direct)

A systemd service (`qbittorrent-port-sync`) reads the gluetun forwarded port file and updates Transmission's peer port automatically every 5 minutes.

### Secrets

Secrets use `sops-nix` with age encryption. The `.sops.yaml` defines age recipients for each host and `liquidark` (dev machine). Secrets are rendered at runtime to `/run/secrets/`.

**pirateship** (`secrets/pirateship.yaml`):
- `vpn_env` — WireGuard credentials for gluetun (referenced as `--env-file`)
- `qbt_credentials` — `TRANSMISSION_USERNAME`/`TRANSMISSION_PASSWORD` for port sync service

**rivendell** (`secrets/rivendell.yaml`):
- `technitium_env` — Technitium admin credentials
- `nut_upsmon_password` — internal upsmon user password for NUT
- `nut_ha_password` — Home Assistant NUT integration password (username: `homeassistant`)

**mirkwood** (`secrets/mirkwood.yaml`):
- `technitium_env` — Technitium admin credentials

### Auto-Upgrade

The system pulls and applies updates from `github:bcrescimanno/homelab-nix` daily at 4am. Changes pushed to the repo's main branch will be deployed automatically on the next upgrade cycle. This includes home-manager configuration changes from the dotfiles flake.

### Media Storage Layout

All media and config live under `/var/lib/`:
- `/var/lib/media/{movies,tv,music,torrents}` — shared media volumes
- `/var/lib/<service>/config` — per-service config directories

Directories are declared via `systemd.tmpfiles.rules` to ensure they exist with correct ownership (`brian:users`) on first boot.
