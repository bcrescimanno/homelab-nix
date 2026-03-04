# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NixOS flake for a Raspberry Pi 5 homelab. Currently manages one host (`pirateship`) running a media stack via Podman containers. Two other Raspberry Pi 5 devices exist on the network running Raspberry Pi OS (Trixie) with Docker Compose stacks — they will be migrated to NixOS and added to this flake in the future. A NAS will also be added, at which point media storage (currently on local disk under `/var/lib/media/`) will move there along with backup configuration.

Uses `nixos-raspberrypi` for Pi-specific hardware support, `disko` for declarative disk partitioning, and `sops-nix` for secrets management.

## Common Commands

```bash
# Check the flake for errors (also runs automatically as a pre-commit hook)
nix flake check --no-build

# Update flake inputs (nixpkgs, etc.)
nix flake update

# Deploy to the Pi (run from dev machine)
nixos-rebuild switch --flake .#pirateship --target-host brian@pirateship --use-remote-sudo

# Initial install via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- --flake .#pirateship root@<ip>

# Edit encrypted secrets
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
```

## Hosts

| Host | Hardware | Status | Role |
|---|---|---|---|
| `pirateship` | Raspberry Pi 5 | Live on NixOS | Media stack (arr apps, Jellyfin, VPN) |
| `rivendell` | Raspberry Pi 5, 8GB | Planned migration from Raspberry Pi OS (Trixie) | Home Assistant, Matter Server, Nginx Proxy Manager, Portainer CE, Technitium (secondary DNS) |
| `mirkwood` | Raspberry Pi 5, 4GB | Planned migration from Raspberry Pi OS (Trixie) | Technitium (primary DNS), Homepage, Portainer Agent |

`rivendell` and `mirkwood` currently run Docker Compose stacks (source in `~/code/homelab`). They will be migrated to NixOS and added to this flake. Key migration decisions:
- Pi-hole + Unbound + Redis + Nebula-Sync → replaced by Technitium DNS (one container per device, built-in sync and recursive resolution)
- Watchtower → replaced by Renovate (already in use for pirateship)
- Jellyfin on rivendell → retired once NAS is added; pirateship becomes the sole Jellyfin instance
- Docker → Podman (consistent with pirateship)
- A NAS will be added in future; at that point all media storage moves off pirateship's local disk

## Architecture

### Module Structure

- `flake.nix` — entry point; defines the single `pirateship` NixOS configuration, wiring together all inputs and modules
- `hosts/pirateship.nix` — machine-specific config: hostname, disk layout (disko), networking, and SOPS secret declarations
- `modules/base.nix` — shared config for all devices: user accounts, SSH, firewall, Podman setup, auto-upgrade, common packages
- `modules/arr-stack.nix` — all OCI containers managed via `virtualisation.oci-containers`

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
