# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NixOS flake for a Raspberry Pi 5 homelab. Manages three hosts: `pirateship` (media stack), `rivendell` (Home Assistant, NPM, secondary DNS), and `mirkwood` (primary DNS, Homepage). A NAS will be added in future, at which point media storage (currently on local disk under `/var/lib/media/`) will move there along with backup configuration.

Uses `nixos-raspberrypi` for Pi-specific hardware support, `disko` for declarative disk partitioning, and `sops-nix` for secrets management.

## Common Commands

```bash
# Check the flake for errors (also runs automatically as a pre-commit hook)
nix flake check --no-build

# Update flake inputs (nixpkgs, etc.)
nix flake update

# Deploy to a Pi (run from dev machine)
# --build-host required when deploying from x86_64 to aarch64 — builds on the Pi itself
nixos-rebuild switch --flake .#pirateship --target-host brian@pirateship --build-host brian@pirateship --sudo
nixos-rebuild switch --flake .#rivendell --target-host brian@rivendell --build-host brian@rivendell --sudo
nixos-rebuild switch --flake .#mirkwood --target-host brian@mirkwood --build-host brian@mirkwood --sudo

# Initial install via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- --flake .#pirateship root@<ip>

# Edit encrypted secrets
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
```

## Hosts

| Host | Hardware | Status | Role |
|---|---|---|---|
| `pirateship` | Raspberry Pi 5 | Live on NixOS | Media stack (arr apps, Jellyfin, VPN) |
| `rivendell` | Raspberry Pi 5, 8GB | Live on NixOS | Home Assistant, Matter Server, Nginx Proxy Manager, Technitium (secondary DNS), Glances |
| `mirkwood` | Raspberry Pi 5, 4GB | Live on NixOS | Technitium (primary DNS), Homepage, Glances |

## Architecture

### Module Structure

- `flake.nix` — entry point; defines NixOS configurations for all three hosts
- `hosts/{pirateship,rivendell,mirkwood}.nix` — machine-specific config: hostname, disk layout (disko), networking, and SOPS secret declarations
- `modules/base.nix` — shared config for all devices: user accounts, SSH, firewall, Podman setup, auto-upgrade, common packages
- `modules/arr-stack.nix` — pirateship media stack containers
- `modules/dns.nix` — Technitium DNS container (rivendell + mirkwood)
- `modules/homeassistant.nix` — Home Assistant + Matter Server containers (rivendell)
- `modules/proxy.nix` — Nginx Proxy Manager container (rivendell)
- `modules/homepage.nix` — Homepage dashboard container with Nix-managed config (mirkwood)
- `modules/monitoring.nix` — Glances system monitor as native NixOS service (all three hosts)
- `scripts/configure-technitium.sh` — post-install API script to configure Technitium (blocklists, zones, zone sync)

### Container Stack (arr-stack.nix)

All arr containers (`transmission`, `radarr`, `sonarr`, `prowlarr`, `lidarr`, `recyclarr`) share gluetun's network namespace (`--network=container:gluetun`). This means gluetun acts as a VPN kill switch — if the VPN drops, all dependent containers lose internet access.

- **gluetun**: ProtonVPN WireGuard gateway; holds all exposed ports for the arr containers
- **transmission**: torrent client (port 9091 via gluetun)
- **radarr/sonarr/prowlarr/lidarr**: media managers (ports 7878/8989/9696/8686 via gluetun)
- **recyclarr**: syncs quality profiles to radarr/sonarr
- **jellyfin**: media server (port 8096, direct — not through VPN)
- **portainer-agent**: connects to a Portainer instance elsewhere (port 9001, direct)

A systemd service (`qbittorrent-port-sync`) reads the gluetun forwarded port file and updates Transmission's peer port automatically every 5 minutes.

### Secrets

Secrets use `sops-nix` with age encryption. The `.sops.yaml` defines two age recipients: `pirateship` (the server's key at `/var/lib/sops-nix/key.txt`) and `liquidark` (a dev machine key). Secrets are rendered at runtime to `/run/secrets/`.

- `vpn_env` — WireGuard credentials for gluetun (referenced as `--env-file`)
- `qbt_credentials` — `TRANSMISSION_USERNAME`/`TRANSMISSION_PASSWORD` for port sync service

### Auto-Upgrade

The system pulls and applies updates from `github:bcrescimanno/homelab-nix` daily at 4am. Changes pushed to the repo's main branch will be deployed automatically on the next upgrade cycle.

### Media Storage Layout

All media and config live under `/var/lib/`:
- `/var/lib/media/{movies,tv,music,torrents}` — shared media volumes
- `/var/lib/<service>/config` — per-service config directories

Directories are declared via `systemd.tmpfiles.rules` to ensure they exist with correct ownership (`brian:users`) on first boot.
