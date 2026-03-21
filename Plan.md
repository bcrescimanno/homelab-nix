# Homelab Plan

> Status markers: [ ] todo · [x] done · [~] in progress · [!] blocked

---

## Current State (as of 2026-03-15)

All three hosts are live on NixOS. Migration from Docker/Technitium/NPM is complete.

| Host | OS | Services |
|---|---|---|
| `pirateship` | NixOS | gluetun VPN, qbittorrent, radarr, sonarr, prowlarr, lidarr, recyclarr, sabnzbd, jellyfin, Glances |
| `rivendell` | NixOS | Home Assistant, Matter Server, Caddy (reverse proxy + TLS), Blocky+Unbound DNS (secondary), NUT (UPS), ntfy, Gatus, Glances |
| `mirkwood` | NixOS | Blocky+Unbound DNS (primary), Homepage, Prometheus, Grafana, Glances |
| `erebor` | UniFi OS | NAS (UNAS Pro 4, 4×12TB RAID 6 ~24TB usable); NFS shares for pirateship media + backups |

### Deploy
```bash
deploy           # all hosts via deploy-rs (magic rollback)
deploy <host>    # specific host
```
Shell function in dotfiles `home/common.nix`. deploy-rs config in `flake.nix` under `deploy.nodes`.

---

## Known Issues & Technical Debt

### Cleanup

- [ ] **home-manager nixpkgs overlay** (`flake.nix` piModules): patches `neovimUtils.makeVimPackageInfo` from dotfiles nixpkgs. Remove once `nixos-raspberrypi` updates its pin past Feb 2026. At that point: remove the overlay, restore `inputs.nixpkgs.follows = "nixpkgs"` to the home-manager input, drop the dotfiles-follows approach.

### Fragility

- **Hardcoded IPs**: UDM Pro (`10.0.1.1`) in `dns.nix`, erebor (`10.0.1.22`) in `dns.nix`, mirkwood (`10.0.1.8`) in `homepage.nix` allowedHosts. Set DHCP reservations in UniFi for all Pi IPs + erebor 10G MAC to prevent drift.
- **Caddy plugin hash** (`caddy.nix`): pinned to caddy 2.10.2 from rivendell's nixpkgs. Must be updated if nixpkgs upgrades Caddy on rivendell.
- **Homepage `allowedHosts` IP** (`homepage.nix:16`): `10.0.1.8` (mirkwood) is hardcoded. If the IP changes, homepage becomes unreachable from that address. Mitigated by DHCP reservation.

---

## Open Tasks

### High Priority

- [ ] **Backup restore dry run**: test restoring from restic snapshots — both local (erebor) and offsite (R2). Validate paths, passwords, and snapshot contents are correct.

### NAS (erebor) — Remaining Work

erebor is online (10G SFP+ at 10.0.1.22, 1G ethernet at 10.0.1.21 for management).

- [ ] **Monthly Btrfs scrub**: SSH into erebor and add `btrfs scrub start /` to crontab. Btrfs has no scheduled scrub in the UniFi Drive GUI.
- [ ] **Backup coverage**: verify R2 restic snapshots include erebor-resident data after media migration.

### DNS / Monitoring

- [ ] **Grafana DNS dashboard (Pi-hole-style panels)**: `blocky_query_total` has only `client` and `type` (DNS record type) labels — no per-client blocked-domain breakdown. Option A (Prometheus-only) cannot deliver this. **Option B (Loki)** is required for top blocked domains + per-client breakdowns:
  - Loki on rivendell (8GB RAM), 7-day retention
  - Promtail on both rivendell + mirkwood shipping `/var/log/blocky/*.csv` to `rivendell.local:3100`
  - `services.loki` + `services.promtail` NixOS modules
  - Add Loki datasource to Grafana on mirkwood
  - Build LogQL panels for top clients, top blocked domains, per-client breakdown

### Home Assistant / IoT

- [x] **Wake-on-LAN across IoT VLAN** — rivendell has `eth0.4` (VLAN 4, 10.0.12.2/22) tagged subinterface on its existing port (UniFi "Allow All" was already set). HA sends WoL broadcasts to `10.0.15.255` (IoT /22 broadcast); no UDM Pro changes required.
- [ ] **Thread border router (ZBT-2)** — Home Assistant Connect ZBT-2 USB dongle ordered. When it arrives: add OTBR (OpenThread Border Router) container to `modules/homeassistant.nix` alongside HA and Matter Server (`--privileged` + host networking), then wire HA's Thread integration to it. The ZBT-2 will be auto-accessible inside privileged containers.

### Future Services

- [ ] **Immich** — self-hosted photo library (Google Photos replacement). Mobile backup app, face recognition, albums, map. Host on pirateship; storage on erebor NFS. High value.
- [ ] **Tailscale** — mesh VPN for remote homelab access without port forwarding. Add `modules/tailscale.nix` or extend `base.nix` for all hosts. Consider Headscale (self-hosted control plane) once comfortable.
- [ ] **Navidrome** — lightweight Subsonic-compatible music server. Pairs with Lidarr, streams to Symfonium on iOS. Host on pirateship, music library on erebor.
- [ ] **Paperless-ngx** — document management with OCR. Tax docs, warranties, receipts. Host on pirateship.
- [ ] **SSO (Authelia)** — plan complete, implementation deferred. See `memory/sso-plan.md`.
- [ ] **Node-RED** — visual flow editor for HA automations. More powerful than HA's built-in engine for complex logic. Container on rivendell alongside HA.
- [ ] **HomeKit migration** — inventory all HomeKit-only devices; migrate to HomeKit-through-HA (HA as HomeKit bridge). Goal: single automation pane in HA while keeping Siri usable.

---

## Personal Machines — NixOS Migration

### Hardware

| Machine | Role | CPU / GPU | OS |
|---|---|---|---|
| ROG Zephyrus G14 2024 | Laptop (trial first) | AMD Ryzen AI 9 HX 370 · Radeon 890M iGPU · RTX 4060/4070 dGPU | Arch Linux |
| Desktop | Primary workstation | RTX 5090 (Blackwell GB202) | Arch Linux |
| terra (living room) | TV-connected gaming | AMD Ryzen 7 5700X3D · RTX 5070 Ti (GB203) | Arch Linux |

### Why consider it
- Declarative config already familiar from homelab work
- Atomic rollbacks: reboot into previous generation if an update breaks GPU/compositor
- `nix develop` / direnv for per-project dev environments replaces pyenv/nvm/rustup
- dotfiles flake `machines/` pattern already established; adding machines is the same pattern

### Key risks / friction points
- AUR has broader coverage than nixpkgs for obscure/proprietary tools
- Non-FHS binaries (pre-compiled tarballs, some AppImages) need `nix-ld` or `buildFHSEnv`
- `nixos-rebuild switch` is slower than `pacman -Syu`
- Debugging requires understanding Nix module evaluation, not just reading logs

### Laptop (G14 2024) — path forward

1. Check `nixos-hardware` for `asus/rog-zephyrus/g14/2024` — likely handles most hardware quirks
2. `services.asusd` (fan curves, keyboard backlight) + `services.supergfxd` (GPU switching)
3. `hardware.nvidia.prime` **offload mode** — AMD iGPU for daily use, NVIDIA launched per-app
4. MUX switch as escape hatch — if PRIME is troublesome, set BIOS to AMD-only and flip for gaming
5. Add `machines/g14.nix` in dotfiles flake, following existing pattern

### Desktop (RTX 5090) — wait

- Requires NVIDIA driver ≥ 570.x (Blackwell). Verify `nvidiaPackages.stable` covers the 5090 before attempting.
- No hybrid GPU complexity but no fallback if driver is broken.
- Let the G14 experiment run for a month or two first; don't disrupt the primary workstation.

### terra (living room) — evaluate NixOS vs Bazzite

Use case is a couch gaming system, likely running Steam Big Picture full-time. Two options:

- **Bazzite** — Fedora-based immutable gaming distro, rpm-ostree atomic updates (same rollback guarantees as NixOS), Steam Big Picture pre-configured, first-class controller + Bluetooth support baked in. Essentially SteamOS 3.x for any PC. Better fit if the goal is a seamless couch experience with minimal maintenance.
- **NixOS** — consistent with the rest of the fleet; `programs.steam.enable = true` works well; full Bluetooth controller support available.

Decision factors: seamless couch experience → Bazzite. Fleet consistency → NixOS.
