# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NixOS flake for a homelab of three Raspberry Pi 5s and one x86_64 tower. Manages four hosts: `pirateship` (media stack), `rivendell` (Home Assistant, Caddy reverse proxy, secondary DNS, UPS monitoring, Vaultwarden, Music Assistant), `mirkwood` (primary DNS, Homepage, Prometheus/Grafana), and `orthanc` (Jellyfin, Minecraft, attic binary cache, Invidious, x86_64 CI runner). Media storage is on `erebor` (UniFi UNAS Pro 4 NAS) via NFS mounts on pirateship and orthanc.

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

# Deploy via deploy-rs (magic rollback + auto rollback; Pis build on the Pi,
# orthanc builds locally — same arch as the deploy machine)
deploy pirateship
deploy rivendell
deploy mirkwood
deploy orthanc
deploy              # all hosts, in a safe order: orthanc (warms the cache),
                    # then mirkwood, then rivendell + pirateship in parallel

# Fallback raw form if deploy-rs is unavailable:
nixos-rebuild switch --flake .#<host> --target-host brian@<host> --build-host brian@<host> --sudo

# Initial install via nixos-anywhere
nix run github:nix-community/nixos-anywhere -- --flake .#pirateship root@<ip>

# Edit encrypted secrets
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/orthanc.yaml
```

## Hosts

| Host | Hardware | Role |
|---|---|---|
| `pirateship` | Raspberry Pi 5, 4GB | Media stack (arr apps, SABnzbd, gluetun VPN), Bazarr, Navidrome, Glances |
| `rivendell` | Raspberry Pi 5, 8GB | Home Assistant, Matter Server, OTBR (Thread), Caddy (reverse proxy + TLS), Blocky+Unbound DNS (secondary), NUT (UPS), ntfy, Gatus, Vaultwarden, Music Assistant, aarch64 CI runner, Glances |
| `mirkwood` | Raspberry Pi 5, 4GB | Blocky+Unbound DNS (primary), Homepage, Prometheus, Grafana, Glances |
| `orthanc` | x86_64 tower — Ryzen 9 5950X, 32GB, RX 550, NVMe | Jellyfin (VAAPI transcoding), Minecraft servers, attic binary cache, Invidious + companion, Cloudflare Tunnel, x86_64 CI runner / remote builder, Glances |
| `erebor` | UniFi UNAS Pro 4 | NAS — 4×12TB RAID 6 (~24TB usable); NFS shares for media + restic backups |

**orthanc is the only x86_64 host**, and the only one with `homelab.reboot.auto = true`. It builds its own closure locally on deploy (`remoteBuild = false`) and serves as the remote builder for the Pis.

## Architecture

### Module Structure

- `flake.nix` — entry point; defines NixOS configurations and deploy-rs nodes for all four hosts, plus the `orthanc-installer` ISO and the `overlayWorkarounds` data consumed by `scripts/check-overlays`. The Pis are built via `nixos-raspberrypi.lib.nixosSystem` and share `piModules`; orthanc uses plain `nixpkgs.lib.nixosSystem`
- `hosts/{pirateship,rivendell,mirkwood,orthanc}.nix` — machine-specific config: hostname, disk layout (disko), networking, SOPS secret declarations, home-manager user config, backup paths
- `lib/homelab.nix` — one helper: `(import ../lib/homelab.nix "name")` declares a static user+group for a `DynamicUser = true` service, because sops-nix resolves secret ownership at eval time and a DynamicUser service exposes no group to resolve against
- `modules/base.nix` — shared config for all devices: user accounts, SSH, firewall, Podman, auto-upgrade, ntfy upgrade notifications, common packages. Imports `attic-push.nix`, `post-upgrade-check.nix`, `reboot-policy.nix` and `tailscale.nix`, so every host gets those four
- `modules/arr-stack.nix` — pirateship media stack containers (gluetun VPN kill switch, qbittorrent, radarr, sonarr, prowlarr, lidarr, sabnzbd) plus the native recyclarr service; `qbittorrent-port-sync` systemd service syncs the gluetun forwarded port to qBittorrent. **Jellyfin is not here** — it runs natively on orthanc (`modules/jellyfin.nix`)
- `modules/bazarr.nix` — Bazarr subtitle manager on pirateship (port 6767, `subtitles.theshire.io`), running as `brian` (uid 1000) to match the arr containers' PUID on the erebor NFS mount. Bazarr rewrites its own `config.yaml` + SQLite at runtime, so **none of its config can be expressed in Nix** — the module header documents the settings that matter so they are recoverable
- `modules/jellyfin.nix` — Jellyfin on **orthanc** (native service, port 8096, `jellyfin.theshire.io`/`media.theshire.io`). VAAPI H.264/HEVC transcoding via radeonsi on the RX 550; HDR→SDR tone mapping falls back to CPU (ROCm dropped GFX8). Hardware acceleration is switched on in the Jellyfin UI, not in Nix — see the module header for the one-time setup and the Infuse direct-play settings
- `modules/jellyfin-notify.nix` — pushes targeted library updates into Jellyfin on import, reconciled over each app's API (same pattern as `lidarr-formats.nix`). Exists because **inotify does not deliver events across NFS clients**: the arr apps on pirateship write the files, Jellyfin watches them from orthanc, and `EnableRealtimeMonitor` therefore never fires — 42 stale entries had accumulated when it was written
- `modules/lidarr-formats.nix` — declarative Lidarr custom formats + profile scores, synced to the API by the `lidarr-format-sync` oneshot (`modules/lidarr-format-sync.py`). Lidarr has **no TRaSH guide and no Recyclarr support**, so this is the stand-in; scoring is tuned to Redacted's release-title format. See the comment block in the module before changing scores.
- `modules/navidrome.nix` — Navidrome music streaming server on pirateship (native NixOS service, port 4533); music library at `/var/lib/media/music`. **Remote/mobile listening only** — OpenSubsonic API, iOS client is Amperfy, reached publicly at `stream.theshire.io` through orthanc's tunnel. Local whole-home playback is Music Assistant's job, and WiiM devices do not use Navidrome
- `modules/backup.nix` — restic backups to erebor NFS (local) and Cloudflare R2 (offsite); paths declared per-host via `homelab.backup.paths`
- `pkgs/materialious.nix` / `pkgs/caddy-cloudflare.nix` — the two pins no Renovate manager can see (a `fetchFromGitHub` tag and an FOD hash over the Go module graph). Exposed as flake outputs (`.#materialious`, `.#caddy-cloudflare`) so `scripts/refresh-pins` can update them with `nix-update` and a `lib.fakeHash` rebuild; `.github/workflows/refresh-pins.yml` runs it weekly and opens a PR. Read `pkgs/materialious.nix`'s header before merging a version bump — its build workarounds are upstream-behaviour-dependent.
- `modules/caddy.nix` — Caddy reverse proxy on rivendell; wildcard TLS via Cloudflare DNS-01; proxies all `*.theshire.io` vhosts
- `modules/dns.nix` — Blocky (port 53 + port 4000 DoH/metrics) + Unbound (port 5335, localhost) on both rivendell and mirkwood; fully declarative, replaces Technitium
- `modules/flake-freshness.nix` — daily on rivendell (09:00): alerts when the inputs **this system was built from** fall >10 days behind upstream. Revisions are read from `flake.lock` at eval time and baked in, so it measures what is RUNNING, not what is on main. Only alarms when the locked rev *differs* from upstream's head — `disko` sat 77 days old and perfectly current. A fetch failure is reported, never treated as an all-clear.
- `modules/gatus.nix` — Gatus service health monitor on rivendell (native NixOS service, port 8080); all monitors declared in Nix, alerts via ntfy. The `Gaming` group is **deliberately empty**: probing the Minecraft ports would defeat autopause (see `modules/minecraft.nix`). Gatus cannot check anything that needs a Prometheus query either, since 9090 is closed to the LAN — those checks belong in `grafana.nix` as alert rules
- `modules/grafana.nix` — Prometheus (port 9090) + Alertmanager + Grafana (port 3001) on mirkwood. Scrape jobs: `blocky` (both DNS hosts), `node`, `systemd` and `smartctl` (all four hosts), `nut` (rivendell). **Prometheus itself is deliberately not exposed to the LAN** — only Grafana's 3001 is open, so nothing off-host can query 9090. All alert rules live here and route to the existing ntfy topic through alertmanager-ntfy, so there is one notification channel. Grafana dashboards are JSON-only
- `modules/homeassistant.nix` — Home Assistant (native `services.home-assistant`), Matter Server (container) and OTBR (native `services.openthread-border-router`) on rivendell. HA reuses the container-era config dir via `configDir = /var/lib/homeassistant/config`, so `.storage` — every UI-created integration, device and dashboard — carries over untouched and the UI stays fully usable; only `configuration.yaml` becomes a read-only store symlink. **`extraComponents` is load-bearing**: integrations added through the UI live in `.storage`, which the module cannot see, so each one's domain must be listed or its Python deps are missing at runtime. Regenerate with the jq command in the module header. Matter Server is deliberately still a container — see the comment block before retrying `services.matter-server`. **HomeKit Bridge is declared here, one bridge per room**, because HAP has no room attribute and accessories land in the bridge's room. YAML overwrites the matching config entry (by name OR port) on every start, so UI filter edits are reverted; keep port+name stable or the pairing is orphaned. Matching **only sees `source: import` entries** — a UI-created bridge on the same port is silently skipped, so never add a bridge through the UI
- `modules/ha-window-notifications.nix` — passive-cooling window prompts on rivendell (close above 66°F in the morning, open below 72°F in the evening, both suppressed by a sub-75°F forecast high in favour of one 08:00 "windows open day" message). The close threshold is 66 rather than 68 as **margin for the met.no fallback, which publishes whole degrees hourly** — a strict `above: 68` silently fired nothing on a 96°F day because the sensor read exactly 68.0. Raise it back toward 68 once the Eve Weather is paired. Declared as a **Home Assistant package** under `services.home-assistant.config.homeassistant.packages.windows`, which merges additively with the UI-authored `automations.yaml` — a package is used rather than a bare automation include because it can also declare the two `template:` sensors. The automations read `sensor.outdoor_temperature`, never the hardware entity, so swapping the source is a one-line change. See the comment block in the module before touching the thresholds or the fallback behaviour.
- `modules/ha-dashboard.nix` — the **Home** Lovelace dashboard, declared via `services.home-assistant.lovelaceConfig` (YAML mode, dashboard `nixos-lovelace`, **read-only in the HA UI** — edit the Nix). Stock cards only, sections views (Home glance, Upstairs, Downstairs; one section per room). It is also forced to be the **system default dashboard**: an HA `preStart` snippet writes `core.default_panel` into `.storage/frontend.system_data`, so "Set as default" in the UI is reverted on restart. A per-user default (profile page) still wins over it. Entity choices are verified against the recorder — read the header before swapping an `_2` entity for its unsuffixed twin. **TVs are deliberately disabled in Music Assistant** and controlled via their native HA integrations.
- `modules/ha-bathroom-lights.nix` — Boys Bathroom lights auto-off, **gated on the door** (HA package `boys_bathroom_lights`, read-only in the UI). The door is the room's occupancy proxy: `binary_sensor.boys_bathroom_door` (Matter Eve Door & Window, node 10, `device_class: door`, so **`on` = open**). Four automations: (1) door closed→open **while the light is already on** → 30s grace, re-check both, off; (2) light on **and** door open, both continuously for 5 min → off; (3) light on for 60 min behind a **closed** door → off; (4) sensor `unavailable` for 30 min → one ntfy infra alert. **Nothing ever turns the light on** — manual only. **The 15-minute timer and the 19:00–20:30 shower window are gone and must not come back**: a shower means a closed door, and rule 2 already blocks every fast path, so an hour-long backstop is the only thing that fires behind one. Rule 1 checks the light **before** its delay, not after — a `for`-style trigger plus a later light condition kills the light of someone who walked in and switched it on mid-grace (door opens while the light is off). `unavailable` is neither open nor closed, so every condition names its state explicitly and a dark sensor turns nothing off (fails safe, and rule 4 makes it visible). Rules 2 and 3 are **`mode: parallel`**, not queued: their `homeassistant: start` re-check sleeps for the rule's own duration (up to 60 min) and must never block a real trigger behind it; `light.turn_off` is idempotent. Rule 1 is `mode: restart` so a close/re-open starts a fresh grace period, and deliberately has **no start trigger** (a restart cannot tell you an open-edge happened). Durations are YAML mappings (`{ minutes = 5; }`), never `"00:05:00"` strings.
- `modules/ha-hood-light.nix` — turns `light.hood_light` on when the kitchen hood fan (`switch.hood_power`) turns on (HA package `hood_light`, read-only in the UI). Never turns it off. The trigger is **`from: off` → `to: on` on purpose**: the hood is a Home Connect cloud appliance that flaps `unavailable` several times a day, and a reconnect mid-cook would otherwise re-light a light someone switched off.
- `modules/ha-hvac-openings.nix` — pauses `climate.main_floor` while the house is open (HA package `hvac_openings`, read-only in the UI). **Any** sensor in `openings` open for 60s → save the mode to `input_text.hvac_openings_saved_mode`, set `off`, push to both phones. **All** sensors reporting `off` → restore immediately, silently. `unavailable` is not closed: a dark sensor never pauses and blocks resume (infra alert after 30 min). A manual change to heat/cool/heat_cool while paused abandons the pause. A fifth automation pushes **"close it"** to both phones when the outdoor temperature is outside 40–72°F (or unavailable) and anything has been open 30+ min, naming what is open and repeating every 30 min; it is independent of the thermostat's state. Kitchen and office doors today — **adding window sensors is adding `entity = "Label";` to `openings`**; the header holds the expansion plan (per-sensor delays, multi-zone, dead-sensor escape hatch).
- `scripts/check-overlays` / `.github/workflows/check-overlays.yml` — weekly probe asking whether each temporary overlay in `flake.nix` can be deleted, by building the package **unpatched** against the current lock. The list lives in `flake.nix` as `overlayWorkarounds` — **add an entry whenever you add an overlay**, with both `arch` and `flaky` set explicitly (a missing field is an error, never a default). `flaky = true` marks a **timing-dependent** failure: those must build clean on several forced rebuilds before the probe calls them droppable, because one green run of a race proves only that the race was won once. Runs on rivendell because three of the four failures only reproduce on aarch64. Replaced `modules/nixpkgs-watch.nix`, which never worked: it fetched a 302 URL with `curl -sf` and no `-L`, got an empty body, and its own `[ -z "$REV" ] && exit 0` guard swallowed it while the unit reported success.
- `modules/homepage.nix` — Homepage dashboard as native NixOS service via `services.homepage-dashboard` (mirkwood, port 3000)
- `modules/monitoring.nix` — Glances (port 61208) plus the Prometheus node (9100), systemd (9558) and smartctl (9633) exporters, on **all four hosts**. node_exporter's textfile collector reads `/var/lib/prometheus-textfiles`, which is how `attic-push` and other scripts publish counters
- `modules/attic.nix` — atticd self-hosted Nix binary cache on orthanc (port 8080), served as `cache.theshire.io` through Caddy on rivendell. SQLite + NAR storage on orthanc's NVMe; GC evicts entries not accessed within `default-retention-period`, which is set in that module and stated nowhere else. `attic_env` holds the JWT RS256 signing key — see the module header for the generation recipe
- `modules/attic-push.nix` — Nix post-build hook pushing store paths to attic, imported by `base.nix` for every host. Reads `/run/secrets/attic_push_token` and exits gracefully when the token is absent, so a host without one still builds
- `modules/minecraft.nix` — two modded Minecraft servers on orthanc as itzg containers (Prominence II on 25565, Abyssal Ascent on 25566); kept as containers because the `AUTO_CURSEFORGE` modpack automation is the whole value. Both **autopause**: the JVM is SIGSTOPped after 20 idle minutes and knockd resumes it on connect. Two things follow from that and are easy to undo by accident — the containers need `--cap-add=NET_RAW` (knockd carries `cap_net_raw=ep`, and without it in the bounding set the *exec* fails with EPERM), and **nothing may probe 25565/25566**, because any TCP connect is the knock. Liveness is the `MinecraftServerDown` Prometheus alert, not a Gatus check
- `modules/invidious.nix` — Invidious on orthanc (`invidious.theshire.io`): native invidious + native PostgreSQL + an **invidious-companion container** (not in nixpkgs). Promoted 2026-08-25 when Piped was retired; the stock Invidious UI is deliberately kept as the diagnostic control for Materialious
- `modules/materialious.nix` — Materialious at `yt.theshire.io`, the YouTube frontend actually used. A **client-side SvelteKit SPA**, Nix-built and served as a static site by Caddy on rivendell — no container, no server. It talks to the Invidious API from the browser, so `invidious.nix` is unaffected by it
- `modules/music-assistant.nix` — Music Assistant on rivendell (port 8095, `listen.theshire.io`), reading `/var/lib/media/music` over NFS. **Does not replace Navidrome** — the two run side by side: Music Assistant drives local multi-room playback to WiiM/HomePods, Navidrome serves remote/mobile over OpenSubsonic. The NixOS module uses `DynamicUser`, so the export must allow reads from an ephemeral UID
- `modules/post-upgrade-check.nix` — runs after `homelab-upgrade.service` succeeds, verifies every unit named in `homelab.postUpgradeCheck.services` is active, and **rolls the host back to the exact prior system** if any is not. Modules opt in by appending to that list; entries from all imported modules merge. The unattended path is `nixos-rebuild switch`, not deploy-rs, so it has none of deploy-rs's rollback safety — this is the replacement
- `modules/reboot-policy.nix` — reboots after an upgrade that changed the **kernel**; see the Auto-Upgrade section below
- `modules/tailscale.nix` — tailnet membership on **all four hosts** (imported by `base.nix`); the replacement for the UDM Pro's WireGuard server. Three things in it are load-bearing and fail silently if changed. (1) **It opens no ports on purpose** — NixOS emits its top-level `allowedTCPPorts` rules with no `-i` match, so the tailnet already sees exactly the LAN-open surface and nothing else, which is why mirkwood's 9090 stays closed for free; **never** add `tailscale0` to `trustedInterfaces`, which would publish it. (2) `extraUpFlags` applies **only at first authentication** (`tailscaled-autoconnect` runs `tailscale up` only from `NeedsLogin`/`Stopped`), while `extraSetFlags` reconciles on every activation — routes and the exit node belong in the latter. (3) `--accept-dns=false` on the hosts: client devices *should* accept tailnet DNS so Blocky follows the phone, but a host that does makes all its name resolution — including the nightly flake fetch — depend on tailscaled. rivendell and mirkwood both advertise `10.0.1.0/24` (subnet-router redundancy mirroring the DNS pair); orthanc advertises an exit node; pirateship stays `useRoutingFeatures = "none"` so reverse-path filtering is not loosened on the kill-switch host. The IoT VLAN is deliberately not advertised. ACL policy lives in `tailscale/policy.hujson`
- `modules/pr-automerge-watch.nix` — alerts on rivendell when a Renovate PR with automerge armed is wedged rather than in flight. Every dependency PR here opens with automerge on, so an open one is ambiguous; before this, a blocked lock PR sat unnoticed while the nightly upgrade deployed the old lock on all four hosts
- `modules/vpn-killswitch.nix` — leak detector and hard latch for the arr stack. gluetun already *is* the kill switch (OUTPUT policy DROP); what was missing was **detection** — every pre-existing check was blind to the tunnel, including Gatus's `pirateship:8000` probe, which stays green with tun0 completely down
- `modules/vpn-port-reachability.nix` — detects and heals a forwarded port that exists but is unreachable from the internet. Fills the gap where three separate checks all stayed green through a full day of the tracker being unable to connect: the port file was present and non-zero, qBittorrent's `listen_port` matched it, and nothing was escaping the tunnel
- `modules/music-sync.nix` — keeps Lidarr, Navidrome and Music Assistant in step with `/var/lib/media/music`. **Every filesystem watcher on that share is inert** (NFS + a remote writer, same root cause as Jellyfin/Bazarr), so `music-sync.timer` polls the ~278 *directory* mtimes every 2 min (0.2–1s), debounces one interval so a half-copied album is never scanned, then issues a targeted `RefreshArtist` per changed artist plus `music/sync` to Music Assistant. `music-library-audit.timer` runs daily: it repoints Lidarr artists whose folder drifted from disk and ntfy's about folders needing a manual Library Import. Runs on the pirateship **host**, not in gluetun's netns — see the module comment.
- `modules/qbittorrent-seed-policy.nix` — seeding policy on pirateship, reconciled every 5 min by `modules/qbittorrent-seed-policy.py`. Keyed on each torrent's **`private` flag**, never the tracker hostname (the `tracker` field reports whichever tracker last answered and rotates). Private → ratio `-1`, action `Stop`, upload uncapped (seed forever). Public → ratio `1.0`, action `RemoveWithContent`, upload capped. Global ratio limit stays **off** and the global action stays **Stop**, so anything unclassified defaults to seeding forever rather than being deleted. See the module comment before changing any of it.
- `modules/vaultwarden.nix` — Vaultwarden (native `services.vaultwarden`, port 8222, `vault.theshire.io`) on rivendell, replacing 1Password; clients are the official Bitwarden apps. Single user; **signups closed** (no SMTP, so nothing can register) and **no admin page on purpose** — `ADMIN_TOKEN` is unset, because `/admin` writes `config.json`, which overrides the Nix-generated env. The vault vhost in `caddy.nix` sets `X-Real-IP` (from `CF-Connecting-IP` for traffic arriving from orthanc's tunnel, the peer address otherwise) and Vaultwarden keys its login rate limit on it — never switch it to `X-Forwarded-For`, whose leftmost entry is client-supplied through Cloudflare. iOS push goes through Bitwarden's relay (`vaultwarden_env` secret); a phone logged in before push was enabled must log out/in once. SSH keys/agent and iOS CXP import are gated behind `EXPERIMENTAL_CLIENT_FEATURE_FLAGS`. restic backs up the `backup-vaultwarden` SQLite snapshot in `/var/backup/vaultwarden` (02:30, ahead of restic's 03:00), never the live DB.
- `modules/ntfy.nix` — ntfy push notification server on rivendell via native `services.ntfy-sh` (port 2586 on the LAN, proxied via Caddy). `upstream-base-url` is what makes iOS background push work. Every other host publishes to `http://rivendell:2586/homelab`
- `modules/nut.nix` — Network UPS Tools monitoring Tripp Lite SMC15002URM via USB (rivendell); exposes port 3493 for Home Assistant

### Deploy (deploy-rs)

`deploy-rs` is configured in `flake.nix` under `deploy.nodes`. `scripts/deploy` wraps it (the `deploy` command on PATH comes from dotfiles, `home/common.nix`). All profiles use:
- `sshUser = "brian"`, `user = "root"`
- `magicRollback = true` — rolls back if SSH is lost during activation
- `autoRollback = true` — rolls back if the activation script exits non-zero
- `remoteBuild = true` on the three Pis — builds on the Pi, avoiding x86_64 → aarch64 cross-compilation. **orthanc sets `remoteBuild = false`**: it is the same architecture as the deploy machine, so it builds locally and pushes the result

`deploy` with no argument deploys everything in a deliberate order — orthanc first (it is the x86_64 builder and warms attic), then mirkwood (whose closure primes the cache for the other Pis), then rivendell and pirateship in parallel. mirkwood finishing before rivendell starts is what preserves DNS redundancy. **For DNS changes the script's order is wrong** — deploy rivendell before mirkwood by hand.

Note deploy-rs exits 0 even when activation fails, so `scripts/deploy` greps its output for `[ERROR]` and fails the run itself.

### Home Manager

User dotfiles are managed via the `home-manager` NixOS module, pulling from the `github:bcrescimanno/dotfiles` flake. Each host imports its machine config (`machines/{pirateship,rivendell,mirkwood,orthanc}.nix`). Home Manager runs automatically as part of deployment — no separate `hm` invocation needed.

### Container Stack (arr-stack.nix)

All arr containers share gluetun's network namespace (`--network=container:gluetun`). If the VPN drops, all dependent containers lose internet access — this is the kill switch.

- **gluetun**: ProtonVPN WireGuard gateway; holds all exposed ports for the arr containers
- **qbittorrent**: torrent client (port 9091 via gluetun); image `lscr.io/linuxserver/qbittorrent:libtorrentv1`; `dl.theshire.io` via Caddy
- **sabnzbd**: Usenet client (port 8080 via gluetun)
- **radarr/sonarr/prowlarr/lidarr**: media managers (ports 7878/8989/9696/8686 via gluetun)
- **recyclarr**: native NixOS service (not a container), daily, syncs TRaSH quality profiles + custom formats to radarr/sonarr; API keys via sops secrets `recyclarr_radarr_api_key`/`recyclarr_sonarr_api_key`. Exactly **one guide "(Combined)" profile per app** — Radarr `Remux 2160p (Combined)`, Sonarr `WEB-2160p (Combined)`. See the comment block in `arr-stack.nix` for why single-resolution profiles were dropped.
- **navidrome**: music streaming server (port 4533, native NixOS service — not a container, not through VPN); declared in `modules/navidrome.nix`. Public at `stream.theshire.io` via orthanc's Cloudflare Tunnel
- **bazarr**: subtitles (port 6767, native, not through VPN); declared in `modules/bazarr.nix`

Jellyfin used to run here as a container and **now runs natively on orthanc** (`modules/jellyfin.nix`), which has a GPU for transcoding. It reads the same erebor NFS share.

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

Caddy runs on rivendell with the Cloudflare DNS plugin for DNS-01 ACME (built from `pkgs/caddy-cloudflare.nix`). All `*.theshire.io` services are proxied with automatic TLS. Key vhosts:
- Local backends (`127.0.0.1`): ha, ntfy, monitor, doh, vault, listen, rivendell-stats — plus `yt` (Materialious, served as static files by Caddy itself)
- mirkwood backends: homepage, grafana, mirkwood-stats
- pirateship backends: dl, nzb, movies/radar, tv/sonarr, prowlarr/trackers, music/lidarr, subtitles, stream, pirateship-stats
- orthanc backends: jellyfin/media, cache (attic), invidious

Several services answer on two names (`movies`/`radar`, `tv`/`sonarr`, `music`/`lidarr`, `prowlarr`/`trackers`, `jellyfin`/`media`).

External access does **not** go through Caddy's ports: `stream` and `vault` are published by the Cloudflare Tunnel on orthanc (`services.cloudflared` in `hosts/orthanc.nix`), with `vault` routed back through Caddy so the real client IP becomes `X-Real-IP`. The tunnel is still attribute-named `piped-api` and **that name is load-bearing** — nixpkgs writes it into `cloudflared.yml` and cloudflared matches it against the tunnel's real name in Cloudflare.

### Secrets

Secrets use `sops-nix` with age encryption. Rendered at runtime to `/run/secrets/`.

**Every host** (declared by `backup.nix` and `base.nix`, one copy per host's own yaml):
- `restic_password` — restic repository password (shared value across hosts)
- `restic_r2_env` — Cloudflare R2 credentials for the offsite repo
- `attic_push_token` — JWT push token for the attic post-build hook
- `tailscale_auth_key` — Tailscale OAuth **client secret** (`tskey-client-…`, `auth_keys` scope, scoped to `tag:homelab`), declared by `tailscale.nix`. Not a plain auth key: those expire within 90 days, and `authKeyParameters` is appended to it as a query string, which is the OAuth calling convention

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
- `vaultwarden_env` — `PUSH_INSTALLATION_ID=`/`PUSH_INSTALLATION_KEY=` from https://bitwarden.com/host/ (US region); Vaultwarden's mobile push relay credentials

**mirkwood** (`secrets/mirkwood.yaml`):
- `grafana_env` — `GF_SECURITY_ADMIN_PASSWORD`

**orthanc** (`secrets/orthanc.yaml`):
- `attic_env` — `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`, atticd's JWT signing key
- `cloudflared_piped_credentials` — Cloudflare Tunnel credentials JSON (the tunnel's name is historical; see the Reverse Proxy section)
- `github_runner_token` — registration credential for the x86_64 CI runner
- `minecraft_env` — `CF_API_KEY`, the CurseForge key shared by both server instances
- `invidious_companion_key` — shared key between invidious and its companion container

### Auto-Upgrade

All hosts pull and apply updates from `github:bcrescimanno/homelab-nix` daily at 4am. ntfy notifications are sent on success or failure (`http://rivendell:2586/homelab`).

**Reboots** (`modules/reboot-policy.nix`): after a clean upgrade (post-upgrade check passed), `homelab-reboot-check` compares the booted kernel with the installed one — **kernel only**; initrd/kernel-modules drift daily on the Pis without the kernel moving. `homelab.reboot.auto = true` (orthanc only) reboots inside 03:00–07:00 and never twice for the same kernel; everywhere else it pushes a nightly **"Reboot pending"** ntfy until someone reboots by hand. `homelab-reboot-report` confirms the host came back healthy. rivendell/mirkwood set `dnsPeer` to each other so enabling `auto` there can never take both resolvers down; pirateship needs its kill-switch latch and NFS verified after boot before it gets `auto`.

### Media Storage

Media lives on a single erebor NFS share, mounted via `fileSystems` on both pirateship (`pirateship.nix`, where the arr apps write it) and orthanc (`orthanc.nix`, where Jellyfin reads it, with `x-systemd.automount` so boot does not hang if erebor is away):
- `/var/lib/media` — single NFS mount from erebor (`/var/nfs/shared/media`); contains subdirectories `movies/`, `tv/`, `music/`, `torrents/`, `usenet/`
- `/var/lib/<service>/config` — per-service config directories (local, declared via `systemd.tmpfiles.rules`)

All subdirectories share the same filesystem, enabling hardlinks between them. **Radarr and Sonarr** have `copyUsingHardlinks = true` — imports from `torrents/` are hardlinked into the library at zero additional disk cost, so qBittorrent keeps seeding the original (94.8 of 96.7 GiB of video under `torrents/` is shared inodes).

**Lidarr deliberately has `copyUsingHardlinks = false` — do not "fix" this.** It runs `writeAudioTags = "newFiles"` with `embedCoverArt = true`, so it rewrites tags on import; through a hardlink that would rewrite the file qBittorrent is seeding and fail the torrent's hash check. Music therefore costs a real second copy (19.8 GiB today) and that is the price of seeding Redacted forever.
