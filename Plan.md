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
- [ ] **Paperless-ngx** — document management with OCR. Tax docs, warranties, receipts. Host on pirateship.
- [ ] **SSO (Authelia)** — plan complete, implementation deferred. See `memory/sso-plan.md`.
- [ ] **Node-RED** — visual flow editor for HA automations. More powerful than HA's built-in engine for complex logic. Container on rivendell alongside HA.
- [ ] **HomeKit migration** — inventory all HomeKit-only devices; migrate to HomeKit-through-HA (HA as HomeKit bridge). Goal: single automation pane in HA while keeping Siri usable.

---

## Orthanc: Power Optimization + Service Migration

The goal is two-fold: minimize Orthanc's idle power draw (it's already always-on), and
right-size the service placement across the fleet — moving workloads that benefit from
Orthanc's x86_64/5950X/RX550 hardware away from the Pis.

**Power context**: Orthanc at idle draws ~40–65W (CPU + mobo + RAM + NVMe). Three Pis
together draw ~15–25W. With tuning, Orthanc's idle can drop to the low end (~40–50W).
Services that would hammer a Pi at 100% CPU run at <10% on the 5950X, so the overall
system power under load is often *lower* with the migration than without.

**GPU context**: RX 550 (Polaris, 2GB VRAM) supports VAAPI H.264 + HEVC decode/encode.
Tone mapping (HDR→SDR) falls back to CPU on Polaris (ROCm dropped GFX8). On a 5950X
this is a minor CPU cost — decode and encode still run in hardware. Mesa `rusticl` OpenCL
may enable GPU tone mapping — worth testing after Jellyfin is running.

### Phase 1 — Power optimization [ ]

**Status**: Config written (`hosts/orthanc.nix`), needs deploy.

Changes applied:
- `boot.kernelParams = [ "amd_pstate=active" ]` — enables AMD P-State EPP driver (replaces acpi-cpufreq)
- `hardware.cpu.amd.updateMicrocode = true` — apply latest CPU microcode on boot
- `services.auto-cpufreq` — powersave governor + `balance_power` EPP + `turbo = auto`

Deploy:
```bash
deploy orthanc
```

After deploying, verify with:
```bash
ssh brian@orthanc cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
# should output: amd-pstate-epp
ssh brian@orthanc cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
# should output: balance_power
```

If idle power is still high, consider setting `turbo = "never"` — the 5950X boost clocks
draw significant power even for brief bursts; disabling boost eliminates those spikes at
the cost of burst performance (remote builds will be slower).

### Phase 2 — Jellyfin → Orthanc [ ]

**Depends on**: Phase 1 deployed and stable.

Jellyfin is the highest-value migration. Pi 5 has no working HW transcode path in Jellyfin;
the 5950X + RX 550 gives full VAAPI hardware H.264 + HEVC encode/decode.

Steps:
1. Add erebor NFS mount to `hosts/orthanc.nix` (same `fileSystems` block as pirateship, just `/var/lib/media`)
2. Create `modules/jellyfin.nix` (or add inline to `hosts/orthanc.nix`):
   - `services.jellyfin.enable = true`
   - `users.users.jellyfin.extraGroups = [ "video" "render" ]`
   - `hardware.graphics.enable = true` + `extraPackages = [ libva-mesa-driver mesa ]`
3. Add Caddy vhost on rivendell pointing jellyfin.theshire.io → `orthanc.local:8096`
4. Deploy orthanc, then rivendell
5. In Jellyfin admin UI: enable VAAPI, set render device to `/dev/dri/renderD128`
6. Test HDR tone mapping — if broken, it falls back to CPU automatically (acceptable)
7. Optionally test Mesa `rusticl` OpenCL for GPU tone mapping: add `mesa` with OpenCL support
8. Disable jellyfin in `modules/arr-stack.nix` (pirateship) after verifying orthanc instance

Note: Jellyfin config/metadata lives at `/var/lib/jellyfin` — a fresh Jellyfin on orthanc will
re-scan the library. Metadata can be migrated manually if desired (copy `/var/lib/jellyfin`
from pirateship → orthanc via rsync before first start) but a clean scan is also fine.

### Phase 3 — Arr stack + SABnzbd + qBittorrent + gluetun → Orthanc [ ]

**Depends on**: Phase 2 complete and stable. erebor NFS mount already in place from Phase 2.

The VPN kill switch (gluetun network namespace) and container pattern from `arr-stack.nix`
work identically on x86_64. This is a near-copy of the existing module.

Steps:
1. Extract `modules/arr-stack.nix` logic into a form that can target orthanc — or simply
   import the module from `hosts/orthanc.nix` (it's already OS-agnostic)
2. Copy sops secrets: `vpn_env`, `qbt_credentials`, `recyclarr_env` → `secrets/orthanc.yaml`
3. Add those secrets to the orthanc sops config in `hosts/orthanc.nix`
4. Deploy orthanc; verify gluetun comes up, confirm tun0 IP, verify qBittorrent preStart
5. Update Caddy vhosts on rivendell: dl/nzb/movies/tv/prowlarr/music now point to orthanc instead of pirateship
6. Switch arr apps' download clients from Transmission → qBittorrent (localhost:9091) — this was already a pending task
7. Disable arr-stack on pirateship after confirming orthanc stack is healthy

### Phase 4 — Retire pirateship [ ]

**Depends on**: Phases 2 and 3 complete and stable (Jellyfin + arr stack fully running on orthanc).

After migration, pirateship runs nothing except Glances + backups — not worth keeping on.

Steps:
1. Remove pirateship from `flake.nix` deploy nodes (or mark as disabled)
2. Remove pirateship-related Caddy vhosts from `caddy.nix`
3. Remove pirateship-stats Caddy vhost and Glances config
4. Remove pirateship from Gatus monitors in `gatus.nix`
5. Remove pirateship from Prometheus scrape targets in `grafana.nix`
6. Remove pirateship from Homepage widgets in `homepage.nix`
7. Update `CLAUDE.md` host table
8. Physically unplug; repurpose Pi 5 for experiments or keep as a spare

Net change: ~5–8W saved (one Pi off), two fewer hosts to maintain.

Note: any future services that were targeted at pirateship (Immich, Paperless-ngx, Navidrome)
should now target orthanc instead.

### Phase 5 — Attic binary cache → Orthanc [ ]

**Depends on**: Phase 4 complete. Lower priority — mirkwood handles Attic fine today.

Orthanc is already the remote builder. Co-locating Attic here means post-build hooks push to
localhost (fast) instead of over the network (slow). Also frees mirkwood's NVMe for other use.

Steps:
1. Migrate Attic NVMe data: rsync `/var/lib/attic` from mirkwood → orthanc (with atticd stopped on both)
2. Move `modules/attic.nix` import from `hosts/mirkwood.nix` → `hosts/orthanc.nix`
3. Update Caddy on rivendell: `cache.theshire.io` → orthanc instead of mirkwood
4. Update post-build hook in `modules/base.nix` — URL stays the same (`cache.theshire.io`),
   no change needed if DNS resolves through Caddy
5. Verify cache hits after a clean build on any Pi

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
