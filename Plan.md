# Migration Plan: rivendell & mirkwood → NixOS

> Status markers: [ ] todo · [x] done · [~] in progress · [!] blocked

---

## Current State (as of 2026-03-08)

Migration complete. All three hosts are live on NixOS.

| Host | OS | Services |
|---|---|---|
| pirateship | NixOS | arr stack, Jellyfin, Transmission, gluetun VPN, Glances |
| rivendell | NixOS | Home Assistant, Matter Server, Nginx Proxy Manager, Technitium DNS (secondary), NUT (UPS), Glances |
| mirkwood | NixOS | Technitium DNS (primary), Homepage, Glances |

## Key Migration Decisions

- **Pi-hole + Unbound + Redis + Nebula-Sync → Technitium DNS** on each device. Technitium has built-in recursive resolution (no separate Unbound needed), built-in zone sync between instances, and a clean web UI.
- **Watchtower → Renovate** (already in use for pirateship; auto-upgrade handles NixOS updates).
- **Docker → Podman** (consistent with pirateship, already wired in `base.nix`).
- **Portainer dropped entirely** — declarative NixOS config makes it redundant; Glances + SSH covers observability needs.

---

## Migration Order & Rationale

**Migrate rivendell first, then mirkwood.**

Rationale:
- mirkwood is the **primary DNS** for the whole network. Taking it down first would disrupt name resolution everywhere.
- rivendell going down is less catastrophic: Home Assistant and secondary DNS are temporarily unavailable, but the network keeps working (mirkwood is still up).
- After rivendell is on NixOS with Technitium configured, we temporarily promote rivendell's Technitium to primary (router DHCP change), freeing mirkwood to be wiped and reinstalled.

---

## Phase 0: Pre-Migration Preparation

These steps happen on your dev machine **before touching either Pi**.

### 0.1 — Back up Home Assistant data [x]

SSH into rivendell and copy the HA config volume somewhere safe:

```bash
# On dev machine:
ssh brian@rivendell
# Find the HA config volume path (usually one of these):
docker inspect homeassistant | grep -i source
# Then from dev machine:
rsync -av brian@rivendell:/path/to/ha-config/ ~/homelab-backups/rivendell/ha-config/
```

Include: `configuration.yaml`, `automations.yaml`, `scenes.yaml`, `scripts.yaml`, the `.storage/` directory (contains entity history, dashboards, etc.), and any custom components.

### 0.2 — Back up Nginx Proxy Manager data [x]

```bash
rsync -av brian@rivendell:/path/to/npm-data/ ~/homelab-backups/rivendell/npm-data/
# Also grab the letsencrypt certs if any
rsync -av brian@rivendell:/path/to/npm-letsencrypt/ ~/homelab-backups/rivendell/npm-letsencrypt/
```

### 0.3 — Document DNS configuration

[x] Checked Pi-hole custom.list — **no local DNS records were ever configured.**
Technitium starts with a clean slate; no records to re-enter.

### 0.4 — Verify age keys

The `.sops.yaml` already defines age keys for both rivendell and mirkwood. Verify you have the corresponding private keys stored somewhere safe on liquidark (your dev machine):

```bash
# The key file used for dev machine operations:
ls ~/.config/sops/age/keys.txt
```

When we run nixos-anywhere, we'll inject the device's age private key during installation so sops-nix can decrypt secrets at boot. **We need the private keys for rivendell and mirkwood.**

If the private keys were generated elsewhere and only the public keys are in `.sops.yaml`, find or regenerate them. If generating new private keys, we'll need to re-encrypt the secrets files after updating `.sops.yaml`.

> **Check:** Do you have `/home/brian/.config/sops/age/rivendell.txt` and `mirkwood.txt` (or similar) on liquidark?

### 0.5 — Verify USB installer still works

Boot the USB drive on a spare device or confirm it's a standard NixOS aarch64 installer. The Pi 5 requires:
- NixOS aarch64-linux installer
- The `nixos-raspberrypi` project recommends booting a standard NixOS aarch64 image; nixos-anywhere then takes over via SSH.

Alternatively, we can boot Raspberry Pi OS Lite from the USB and run nixos-anywhere against that (nixos-anywhere works with any Linux that has SSH + bash + either `nix` or network access to bootstrap).

### 0.6 — Implement all NixOS modules (see Phase 1)

All module files currently have placeholder stubs. Complete them before running installations.

### 0.7 — Flake check

```bash
nix flake check --no-build
```

Ensure both `rivendell` and `mirkwood` configurations evaluate cleanly before touching any hardware.

---

## Phase 1: Implement NixOS Modules

All placeholders in `modules/` need real configuration. Do this work **in the repo** on a branch before installation day.

### 1.1 — `modules/dns.nix` — Technitium DNS

Technitium runs as a single OCI container. Key config:
- Image: `docker.io/technitium/dns-server:latest`
- Port: 53/tcp+udp (DNS), 5380/tcp (web UI)
- Volume: `/var/lib/technitium/config` → `/etc/dns`
- Environment: set admin password via sops secret
- Network: direct (not VPN)

mirkwood will be primary, rivendell will be secondary. Sync is configured in Technitium's web UI after both are up (not in NixOS config).

**Sops secrets needed** (`secrets/mirkwood.yaml`, `secrets/rivendell.yaml`): Technitium admin password.

### 1.2 — `modules/homeassistant.nix` — Home Assistant + Matter Server

Two containers on rivendell:

**Home Assistant:**
- Image: `ghcr.io/home-assistant/home-assistant:stable`
- Port: 8123/tcp
- Volume: `/var/lib/homeassistant/config` → `/config`
- Network mode: `host` (required for mDNS/discovery to work)
- Privileged: yes (for USB device access if using Zigbee/Z-Wave sticks)

**Matter Server:**
- Image: `ghcr.io/home-assistant/matter-server:stable`
- Port: 5580/tcp (HA connects to this internally)
- Volume: `/var/lib/matter-server/data` → `/data`
- Network: same as HA (host mode or a shared network)
- Requires Bluetooth and IPv6 consideration for Matter

**Tmpfiles:** Create `/var/lib/homeassistant/config` and `/var/lib/matter-server/data` with correct ownership.

**Restore plan:** After first boot, copy the backed-up HA config into `/var/lib/homeassistant/config/` and restart the container.

### 1.3 — `modules/proxy.nix` — Nginx Proxy Manager

Single container:
- Image: `docker.io/jc21/nginx-proxy-manager:latest`
- Ports: 80/tcp, 443/tcp, 81/tcp (admin UI)
- Volumes: `/var/lib/npm/data`, `/var/lib/npm/letsencrypt`
- Network: direct

**Firewall ports:** 80, 443, 81 (open in `rivendell.nix`).

**Restore plan:** After first boot, copy backed-up NPM data into place and restart.

### 1.4 — `modules/monitoring.nix` — Glances

Runs on both rivendell and mirkwood. Single container or nix package:
- Native NixOS option: `services.glances` (if available in nixpkgs, avoids a container)
- Or container: `docker.io/nicolargo/glances:latest`
- Port: 61208/tcp
- Privileged: yes (for full system visibility)

Check nixpkgs for a native `glances` service first.

### 1.5 — `modules/homepage.nix` — Homepage dashboard

Runs on mirkwood only:
- Image: `ghcr.io/gethomepage/homepage:latest`
- Port: 3000/tcp
- Volumes: `/var/lib/homepage/config` → `/app/config`
- Environment: set service URLs

Config files (services.yaml, bookmarks.yaml, settings.yaml, widgets.yaml) can be committed as Nix-managed files via `environment.etc` or managed as a volume.

**Firewall port:** 3000/tcp (or proxy behind NPM on rivendell).

### 1.6 — SOPS secrets files

The `secrets/rivendell.yaml` and `secrets/mirkwood.yaml` files exist but may be empty. Populate them with at minimum:
- Technitium admin password

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
```

---

## Phase 2: Install & Migrate rivendell

### 2.1 — Snapshot current state

- Verify Home Assistant and NPM backups are complete (from Phase 0)
- Take note of all currently running Docker containers: `ssh brian@rivendell docker ps`

### 2.2 — Boot rivendell from USB

1. Safely shut down rivendell: `ssh brian@rivendell sudo shutdown now`
2. Insert USB installer, power on
3. Boot into the NixOS (or Raspberry Pi OS Lite) installer from USB
4. Note the IP address assigned by DHCP: check your router's DHCP leases

### 2.3 — Prepare age key injection

nixos-anywhere supports injecting extra files into the new system before first boot via `--extra-files`. We use this to put the rivendell age private key at `/var/lib/sops-nix/key.txt`:

```bash
# Create a temp dir with the key file at the correct path
mkdir -p /tmp/rivendell-extra/var/lib/sops-nix
cp ~/.config/sops/age/rivendell-key.txt /tmp/rivendell-extra/var/lib/sops-nix/key.txt
chmod 600 /tmp/rivendell-extra/var/lib/sops-nix/key.txt
```

### 2.4 — Run nixos-anywhere for rivendell

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#rivendell \
  --extra-files /tmp/rivendell-extra \
  root@<rivendell-usb-ip>
```

nixos-anywhere will:
1. SSH into the USB-booted system as root
2. Partition the NVMe using disko (`/dev/nvme0n1`)
3. Install NixOS
4. First boot into NixOS

### 2.5 — Verify rivendell boot

```bash
ssh brian@rivendell
systemctl status  # check for failed units
podman ps         # check containers started
journalctl -u podman-*.service  # check any container errors
```

Check Technitium web UI: `http://rivendell:5380`
Check HA: `http://rivendell:8123` (will be empty config — restore next)
Check NPM: `http://rivendell:81`

### 2.6 — Restore Home Assistant config

```bash
# Copy backup onto rivendell
rsync -av ~/homelab-backups/rivendell/ha-config/ brian@rivendell:/var/lib/homeassistant/config/
# Restart the HA container
ssh brian@rivendell sudo systemctl restart podman-homeassistant.service
```

Verify HA loads, automations are present, integrations reconnect.

### 2.7 — Restore Nginx Proxy Manager config

```bash
rsync -av ~/homelab-backups/rivendell/npm-data/ brian@rivendell:/var/lib/npm/data/
rsync -av ~/homelab-backups/rivendell/npm-letsencrypt/ brian@rivendell:/var/lib/npm/letsencrypt/
ssh brian@rivendell sudo systemctl restart podman-npm.service
```

Verify proxy rules and SSL certs are intact.

### 2.8 — Configure Technitium on rivendell (secondary)

In Technitium web UI on rivendell:
1. Set upstream forwarders (e.g., 1.1.1.1, 9.9.9.9, or your ISP's resolvers)
2. No local DNS records to migrate — Pi-hole had none configured
3. Do NOT configure zone sync yet — mirkwood isn't on Technitium yet

Rivendell's Technitium is temporarily standalone (not yet syncing from mirkwood).

---

## Phase 3: Install & Migrate mirkwood

### 3.1 — Promote rivendell Technitium to temporary primary DNS

Update your router's DHCP config to serve rivendell's IP as DNS server #1 (and optionally a public DNS like 1.1.1.1 as #2). This ensures the network keeps working while mirkwood is down.

Allow existing DHCP leases to expire or force-renew on critical devices.

### 3.2 — Snapshot mirkwood current state

```bash
ssh brian@mirkwood docker ps
# Note any persistent data that needs backup (Homepage config, etc.)
rsync -av brian@mirkwood:/path/to/homepage/config/ ~/homelab-backups/mirkwood/homepage-config/
```

### 3.3 — Boot mirkwood from USB

1. Safely shut down: `ssh brian@mirkwood sudo shutdown now`
2. Insert USB, power on, note new IP

### 3.4 — Prepare age key injection

```bash
mkdir -p /tmp/mirkwood-extra/var/lib/sops-nix
cp ~/.config/sops/age/mirkwood-key.txt /tmp/mirkwood-extra/var/lib/sops-nix/key.txt
chmod 600 /tmp/mirkwood-extra/var/lib/sops-nix/key.txt
```

### 3.5 — Run nixos-anywhere for mirkwood

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#mirkwood \
  --extra-files /tmp/mirkwood-extra \
  root@<mirkwood-usb-ip>
```

### 3.6 — Verify mirkwood boot

```bash
ssh brian@mirkwood
systemctl status
podman ps
```

Check Technitium: `http://mirkwood:5380`
Check Homepage: `http://mirkwood:3000`

### 3.7 — Configure Technitium on mirkwood (primary)

In Technitium web UI on mirkwood:
1. Set upstream forwarders
2. No local DNS records to migrate
3. Configure any blocklists

### 3.8 — Configure Technitium zone sync between mirkwood and rivendell

In Technitium on **mirkwood** (primary): enable zone transfer / NOTIFY to rivendell.
In Technitium on **rivendell** (secondary): set mirkwood as zone master.

Verify rivendell's Technitium picks up the zone data from mirkwood.

### 3.9 — Restore router DNS to mirkwood

Update router DHCP: set mirkwood back as DNS #1, rivendell as DNS #2.

### 3.10 — Restore Homepage config

```bash
rsync -av ~/homelab-backups/mirkwood/homepage-config/ brian@mirkwood:/var/lib/homepage/config/
ssh brian@mirkwood sudo systemctl restart podman-homepage.service
```

---

## Phase 4: Post-Migration Cleanup & Validation

### 4.1 — Full service validation checklist

- [ ] Technitium mirkwood web UI accessible
- [ ] Technitium rivendell web UI accessible
- [ ] Zone sync working (records on mirkwood appear on rivendell)
- [ ] DNS resolution working from a client (nslookup/dig tests)
- [ ] Home Assistant accessible at `http://rivendell:8123`
- [ ] HA automations running, devices connected
- [ ] Matter Server connected to HA
- [ ] Nginx Proxy Manager accessible at `http://rivendell:81`
- [ ] All proxy rules and SSL certs working
- [ ] Homepage accessible at `http://mirkwood:3000`
- [ ] Glances accessible on both rivendell and mirkwood
- [ ] `system.autoUpgrade` working (check `systemctl status nixos-upgrade.timer`)

### 4.2 — Update CLAUDE.md

Update the hosts table status from "Planned migration" to "Live on NixOS".

### 4.3 — Remove Docker Compose sources

Once everything is validated, the old `~/code/homelab` Docker Compose stacks on (now wiped) rivendell and mirkwood are gone. If the source lives on your dev machine, archive or delete `~/code/homelab` once confident.

### 4.4 — Update Renovate config

Ensure Renovate is watching container image digests/tags in the new module files (dns.nix, homeassistant.nix, proxy.nix, monitoring.nix, homepage.nix).

---

## Open Questions / Risks

| Item | Notes |
|---|---|
| HA USB devices (Zigbee/Z-Wave dongles) | Will need to be passed through to container; check device path in NixOS |
| Matter Server Bluetooth access | Needs Bluetooth configured in NixOS; `bluetooth` module is in piModules already |
| Technitium declarative Nix config | Investigate replacing `scripts/configure-technitium.sh` with a Nix-native solution. Check for a NixOS module or nixpkgs package that can manage Technitium configuration declaratively. If nothing exists yet, watch for community efforts — this is a natural fit for a NixOS module. |
| Technitium DNSSEC + local DNS | DNSSEC validation is disabled globally (Option A) so `.local` forwarding works via conditional forwarder to 10.0.1.1. Future Option B: migrate DHCP to Technitium's built-in DHCP server — it auto-creates DNS records for every lease/reservation, enabling full hostname support AND DNSSEC validation for public domains. |
| SSO | Investigate SSO for the homelab. Options include Authelia or Authentik (both integrate well with NPM). Would allow single login across all proxied services and remove per-app auth for internal tools. |
| ~~UniFi custom DNS entries for rivendell~~ | ~~Done~~ — stale hostnames cleaned up. |
| ~~NPM proxy configuration~~ | ~~Done~~ — all services proxied with SSL. |
| ~~GitHub branch protection~~ | ~~Done~~ — branch protection enabled on main. |
| ~~Jellyfin file sync~~ | ~~Done~~ |
| home-manager nixpkgs overlay cleanup | `flake.nix` piModules contains an overlay that patches `neovimUtils.makeVimPackageInfo` from the dotfiles nixpkgs into the system nixpkgs. This works around `nixos-raspberrypi` pinning a nixpkgs version that predates the function. Once `nixos-raspberrypi` updates its pin past Feb 2026, remove the overlay and drop the dotfiles-follows approach. |
| Apple device DNS storms | HomePods generate a burst of ~1500 DNS requests on startup/network change while discovering each other. Traffic drops off once devices establish connections. Confirmed no blocked domains — normal behavior. Monitor if sustained high traffic appears outside of startup windows. |
| Device inventory & HomeKit migration | Inventory all smart home devices currently controlled via HomeKit-only and migrate them to HomeKit-through-Home-Assistant (exposing HA as a HomeKit bridge). Goal: single pane of glass in HA with automations, while keeping HomeKit/Siri usable. |
| Node-RED for automations | Evaluate Node-RED as the automation engine for Home Assistant. Node-RED offers a visual flow editor and is more powerful than HA's built-in automations for complex logic. Would run as a container on rivendell alongside HA. |
| NAS + backups | Once NAS is added: move `/var/lib/media/` to NAS, configure backup solution for host state and HA data. |
| ~~Network UPS Tools (NUT)~~ | ~~Done~~ — `modules/nut.nix` live on rivendell, HA integration configured. |
| ~~Glances on pirateship~~ | ~~Done~~ — `modules/monitoring.nix` included on all three hosts. |
| ~~Technitium query logging~~ | ~~Done~~ — query logging enabled via `configure-technitium.sh`. |
| ~~Recyclarr quality profiles~~ | ~~Done~~ — config made declarative in `arr-stack.nix`; WEB-1080p + WEB-2160p (Sonarr) and UHD Bluray+WEB (Radarr) profiles correct. |
| ~~Home Manager integration~~ | ~~Done~~ — dotfiles integrated via `home-manager` NixOS module on all hosts. |
