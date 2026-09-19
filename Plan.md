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

- **Hardcoded IPs**: UDM Pro (`10.0.1.1`) in `dns.nix`, erebor (`10.0.1.22`) in `dns.nix`, mirkwood (`10.0.1.8`) in `homepage.nix` allowedHosts, rivendell (`10.0.1.9`) as `publishIp` in `music-assistant.nix`. Set DHCP reservations in UniFi for all Pi IPs + erebor 10G MAC to prevent drift.
  - The `music-assistant.nix` one is deliberate and must stay explicit (#570): the whole point is to stop MA auto-detecting its own address, because on a multi-homed host it can pick eth0.4's IoT VLAN IP and silently break every pull-based player. If rivendell's LAN IP ever changes, this must change with it.
- **Caddy plugin hash** (`caddy.nix`): pinned to caddy 2.10.2 from rivendell's nixpkgs. Must be updated if nixpkgs upgrades Caddy on rivendell.
- **Homepage `allowedHosts` IP** (`homepage.nix:16`): `10.0.1.8` (mirkwood) is hardcoded. If the IP changes, homepage becomes unreachable from that address. Mitigated by DHCP reservation.

---

## Open Tasks

### High Priority

- [ ] **Backup restore dry run**: test restoring from restic snapshots — both local (erebor) and offsite (R2). Validate paths, passwords, and snapshot contents are correct.

  Raised in priority by #569: `music-assistant` and `atticd` had been backing up a single 0-byte symlink for ~4 months and *every* existing signal said the backups were healthy. A restore dry run is the only check that would have caught it. When this is done, assert on **entry counts and a real restore**, not on the job's exit code.

- [ ] **Assert backup snapshots have content, not just that the job ran** (follow-up to #569). Today nothing can detect an empty backup:

  | guard | question it answers |
  |---|---|
  | job exit code + ntfy alert | did it run? |
  | `restic-freshness-check` dead-man's switch | did it run *recently*? |
  | `restic check --read-data-subset=10%` | is the repo *readable*? |

  None asks **"does the snapshot contain anything?"** A repo holding one symlink and nothing else passes all three — which is exactly how #569 survived four months of green checks.

  Sketch: after each `restic backup`, run `restic ls <snap>` and assert a per-path minimum entry count (declared alongside `homelab.backup.paths`, e.g. `{ path = "/var/lib/private/music-assistant"; minEntries = 100; }`), failing the unit — and so tripping the existing `OnFailure` ntfy alert — when a path comes back at or near zero. Cheap, and it generalises past the DynamicUser case to any path that silently stops producing data.

  Detect the specific DynamicUser trap early with `[ -L /var/lib/<name> ]` or `systemctl show <unit> -p DynamicUser` before adding any new backup path; see the note on `/var/lib/private` in `hosts/rivendell.nix`.

- [ ] **Prune `atticd-migrate` leftovers** (orthanc): `/var/lib/private/atticd/atticd-migrate` is 280M of residue from the April 2026 migration and, since #569 fixed the atticd backup path, it is now copied to both restic repos nightly for no reason. Confirm atticd no longer reads it, then delete. Small, but it is ~11% of that host's backup volume.

### Home Automation

- [ ] **Install the Eve Energy plug and finish the Eve Door & Window 3-pack (ordered 2026-09-13)** — **2026-09-15: two of three Eves paired.** Office door = Matter node 9, in `openings` in `modules/ha-hvac-openings.nix`. Boys Bathroom door = node 10, drives `modules/ha-bathroom-lights.nix`. **The plug is still not installed, so the mesh still has no Thread router**: `ot-ctl neighbor table` shows only `C` children, and the Eve Weather (node 7) sits at **-96 dBm / LQ 1**, timing out its subscription repeatedly through the day. Install the plug next and confirm the `R` role in the neighbor table, then pair the third Eve; a mains-powered router is the only fix that gives the mesh depth. Add any cooling-relevant sensor to `openings` and deploy rivendell. Full steps in `devices/contact-sensors.md` → Decision and `devices/smart-plugs.md` → Decision.

  Pairing gotcha (2026-09-15): the second sensor hung forever on the iPhone's "Connecting" screen while the device advertised happily on BLE and matter-server logged **nothing at all** — no `Starting Matter commissioning` line, because the setup code never reached it. **Rebooting the iPhone fixed it instantly.** iOS's MatterSupport extension wedges after a successful commissioning, so every device after the first in one session can stall. Reboot the phone before debugging the stack.

- [ ] **Presence sensor for the Boys Bathroom** — **2026-09-15: the door half is done.** `modules/ha-bathroom-lights.nix` is now door-gated (closed door = occupied; 30s after the door opens, 5-min open-door timeout, 60-min closed backstop), and the 15-minute timer and the 19:00–20:30 shower window are **deleted**. What remains is the motion half of **wasp-in-a-box**: an IKEA MYGGSPRAY (~$10, Thread PIR) alongside the Eve that is now installed. Motion while the door is closed would hold "occupied" so presence outlives the door state; door open + no motion ~2 min → off. If the kids' habit of leaving the door open makes that pointless, use a Meross MS605 (mmWave) alone. Cats can only keep the light on longer, never turn it on. **The gap the motion sensor still closes:** someone in the bathroom with the door **open** loses the light after 5 min, and someone who opens the door but stays in the room loses it after 30s (accepted deliberately — they just flip it back on). Detail in `devices/presence-sensors.md` → "use cases and pets".

### Power / Battery Resilience

**DECIDED 2026-09-19: NUT secondaries are a definite yes — do them first, on their
own.** The full load-shedding tier design below is a bigger argument that does not
need to be settled to get the main benefit. Today three of four hosts take an
unclean power cut on every outage, and the software is already in the repo. The
contained first step is:

- [ ] **NUT secondaries on mirkwood, pirateship and orthanc.** Add `upsmon` with
  `type = "secondary"` pointed at `rivendell:3493` (credentials via the existing
  `nut_upsmon_password` pattern, one sops secret per host), so every host learns
  about `ONBATT`/`LOWBATT` instead of running flat out until the battery dies.
  Then set graceful shutdown ordering: pirateship and orthanc power off well
  before `battery.charge.low`, leaving the DNS pair last. **Do not enable the
  reboot/shutdown coupling on both DNS hosts in a way that can take them down
  together** — the same constraint `reboot-policy.nix` already encodes via
  `dnsPeer`. Verify by actually pulling the plug, not with `upsmon -c fsd`.
  Prerequisite, physical: orthanc's BIOS still needs *Restore on AC Power Loss*
  or it will never come back on its own regardless of what NUT does.

- [ ] **Low power mode — shed load while running on battery**. Prompted by the 2026-08-09 outage (~19:57, all hosts hard-cut). Design only, not yet implemented.

  **What today actually does.** Nothing coordinated. `modules/nut.nix` runs NUT on rivendell *only*, as `upsmon` `type = "primary"`, and no other host runs a secondary. So rivendell sees `ONBATT`/`LOWBATT` and can shut itself down, while **mirkwood, pirateship and orthanc have no idea the power is out** — they run flat out until the battery dies and then take an unclean power cut. There is no graceful shutdown ordering and no load shedding anywhere in the repo.

  **Measured baseline (2026-08-09, post-outage).** Tripp Lite SMC15002URM, `ups.load` 20% at idle; `battery.runtime` 1316s at 41% charge, so roughly **50 min at full charge and current load**. That is a lot of headroom *if* it is spent on the right things — and today it is spent equally on Jellyfin transcodes and on DNS.

  **Goal.** On `ONBATT`, cut draw to the services that matter so the remaining runtime covers a much longer outage, then shut down cleanly and in the right order as the battery drains. Ride through short outages entirely.

  Sketch of the tiers (to be argued out properly when this is picked up):
  - **Tier 0 — never shed**: rivendell (DNS secondary, NUT itself, HA, ntfy, Caddy) and mirkwood (primary DNS). Losing DNS makes the whole house look broken.
  - **Tier 1 — shed immediately on `ONBATT`**: the media stack. Pause/stop qBittorrent + SABnzbd transfers, stop Jellyfin transcodes, suspend the arr containers, stop recyclarr/music-sync timers. Pure discretionary load.
  - **Tier 2 — shed early**: orthanc's non-essential workloads (Invidious, Minecraft servers, attic, CI runner). Orthanc is a 5950X/32GB box and is by far the biggest single draw on the UPS.
  - **Tier 3 — graceful shutdown as the battery drains**: full `poweroff` for pirateship and orthanc well before `battery.charge.low` (currently 10%), leaving the DNS pair last.

  Open questions to settle first:
  - **Is orthanc even on the UPS?** It did not come back after this outage — needs its BIOS set to *Restore on AC Power Loss* regardless, or it will always need a physical press.
  - Whether to drive this from **NUT secondaries** on every host (`upsmon` `type = "secondary"` pointed at `rivendell:3493`, with `NOTIFYFLAG`/`NOTIFYCMD` per tier) or from **Home Assistant** automations off the existing NUT integration. NUT secondaries are the more declarative fit and survive HA being down — which is exactly when this has to work. Prefer NUT; HA is the fallback for anything cosmetic.
  - Hysteresis: what re-enables everything on `ONLINE`, and how to avoid flapping on a brownout. Needs a minimum-time-on-line before restoring.
  - Recovery ordering on power return, which is the *other* half of this and is already known-broken: the 2026-08-09 restart raced DNS against NFS (`var-lib-media-music.mount` on rivendell and `navidrome` on pirateship both failed because `erebor.theshire.io` could not resolve yet). Fix the ordering as part of this work.
  - Test plan must include **actually pulling the plug**, not just simulating with `upsmon -c fsd`. Per the standing verification note, a simulation that skips the constraint that matters proves nothing.

### Remote access consolidation

Referenced from the Tailscale entry under Future Services. Reviewed 2026-09-19.

There are three distinct mechanisms today and they are frequently conflated:

| mechanism | where | job | managed by Nix |
|---|---|---|---|
| Cloudflare Tunnel (`piped-api`) | orthanc, `services.cloudflared` | **public ingress** for `stream`, `vault`, Invidious/Materialious | yes |
| UDM Pro WireGuard VPN server | UDM Pro | **remote access** to the LAN for Brian's devices | **no — outside this repo** |
| gluetun ProtonVPN WireGuard | pirateship, in `arr-stack.nix` | **outbound egress** + kill switch for the torrent stack | yes |

The third is unrelated to remote access and must not be folded into this
discussion; it exists to hide torrent traffic, and the kill-switch behaviour
depends on its netns.

The real question is **Cloudflare Tunnel vs UDM Pro WireGuard vs Tailscale**, and
the answer is not "pick one" — they solve different problems:

- The **tunnel publishes to people who are not Brian** (family on cellular using
  Amperfy, the Bitwarden apps). Those clients cannot be asked to join a VPN.
  The tunnel stays.
- **UDM Pro WireGuard and Tailscale overlap almost completely.** Both give Brian's
  own devices the LAN. The honest comparison:
  - *UDM Pro WireGuard*: no extra dependency, no SaaS, already working — but it
    is **imperative config in the UniFi UI**, invisible to this repo, needs an
    inbound port on the router, and gives a single flat "you are on the LAN"
    with no per-service policy.
  - *Tailscale*: declarative (`services.tailscale` + `authKeyFile` from sops),
    no inbound port, works from networks that block WireGuard, per-device ACLs,
    and Tailscale DNS can point at Blocky so **ad-blocking follows the phone
    off-network**. Cost: a **SaaS control plane** — an external dependency on the
    path to your own infrastructure.

  Headscale is the declarative escape hatch and should **not** be chased: a
  self-hosted control plane running on the lab it grants access to is
  chicken-and-egg during exactly the outage you need it for.

**Decision to make before deploying anything:** does Tailscale *replace* the UDM
Pro WireGuard server, or sit beside it? Replacing it is the only outcome that
actually simplifies — adding Tailscale while keeping UDM WireGuard means four
mechanisms, not three. Keeping UDM WireGuard as a break-glass fallback for when
Tailscale's control plane is unreachable is a defensible exception, but it should
be a deliberate, documented fallback rather than drift.

### NAS (erebor) — Remaining Work

erebor is online (10G SFP+ at 10.0.1.22, 1G ethernet at 10.0.1.21 for management).

- [ ] **Monthly Btrfs scrub**: SSH into erebor and add `btrfs scrub start /` to crontab. Btrfs has no scheduled scrub in the UniFi Drive GUI.
- [ ] **Backup coverage**: verify R2 restic snapshots include erebor-resident data after media migration.

### DNS / Monitoring

#### Observability gaps (reviewed 2026-09-19)

- [ ] **External dead man's switch — every alert path terminates at rivendell.**
  Traced 2026-09-19. Prometheus and Alertmanager run on **mirkwood**, but
  Alertmanager's only receiver posts to `http://10.0.1.9:2586` — rivendell's
  ntfy (`modules/grafana.nix`). Gatus runs on rivendell. ntfy *is* on rivendell.
  The reboot-policy and post-upgrade pushes go to `rivendell:2586`. Every bespoke
  `OnFailure` script pushes there too.

  **So if rivendell is down, or just its ntfy is broken, the lab goes silent —
  including the alert that would say rivendell is down.** Gatus has a `mkTcp`
  check for rivendell, but Gatus cannot report the death of its own host. This
  is the structural version of every silent failure in the memory index.

  Fix, cheapest first:
  1. **External dead man's switch** (healthchecks.io free tier or equivalent): a
     timer on **mirkwood and orthanc** pings an outside endpoint on a schedule;
     the outside service alerts *Brian* when the pings stop. This is the only
     option that survives the whole house being down, and it is the one to do
     first.
  2. **Second notification channel**: point the most critical alerts at
     `ntfy.sh` (public) as well as self-hosted ntfy, so a rivendell outage does
     not mute them. Cheap; note it moves alert content off-premises, so keep it
     to "host X is down", not diagnostics.
  3. **Cross-monitoring**: a second Gatus (on mirkwood or orthanc) whose only
     job is watching rivendell and the ntfy endpoint itself.

  Test it by actually stopping ntfy on rivendell and confirming an alert still
  arrives — per the standing verification note, simulating around the constraint
  that matters proves nothing. Also test the *resolve* path separately.

- [ ] **Loki + Alloy — centralized logs. Supersedes the Promtail sketch below.**
  Originally scoped only as a prerequisite for the Pi-hole-style DNS dashboard.
  That undersells it: this lab's characteristic failure mode is **silent**, and
  every instance in the memory index was found by SSHing to a host and grepping
  a journal — empty backups green for four months (#569), the timer oneshot
  reporting success, `systemctl show` returning success for an unknown unit, the
  restart loop that looked healthy, nixpkgs-watch swallowing its own error.
  Centralized logs with retention turn that into one query, and let log-based
  alerts ride the Alertmanager → ntfy path that already exists.

  - **Use `services.alloy`, NOT Promtail** — Promtail hit EOL 2026-03-02.
  - **Host Loki on orthanc**, not rivendell as previously sketched: four hosts of
    journals plus retention wants RAM and disk, and orthanc has ~16GB free and
    1.7TB free NVMe versus rivendell's 8GB shared with HA. Grafana stays on
    mirkwood and gains a Loki datasource pointing at orthanc.
  - Ship **both** the systemd journal (all four hosts) and Blocky's query log
    (`/var/log/blocky/*` on rivendell + mirkwood).
  - Retention: start at 7–14 days. Watch disk before raising it.
  - Then build the LogQL panels the DNS dashboard needed all along: top clients,
    top blocked domains, per-client breakdown.

  Open question to settle at implementation time: orthanc is the one host that
  might get rebooted for a game or a build, so log history has a gap exactly
  when orthanc is the thing that broke. Accept it, or keep a small local buffer
  on each host via Alloy's WAL.

- [ ] **Grafana DNS dashboard (Pi-hole-style panels)** — blocked on Loki above.
  `blocky_query_total` has only `client` and `type` (DNS record type) labels, so
  there is no per-client blocked-domain breakdown; a Prometheus-only approach
  cannot deliver this panel set. Once Loki is up, build top blocked domains and
  per-client breakdowns in LogQL.

### Home Assistant / IoT

- [x] **Wake-on-LAN across IoT VLAN** — rivendell has `eth0.4` (VLAN 4, 10.0.12.2/22) tagged subinterface on its existing port (UniFi "Allow All" was already set). HA sends WoL broadcasts to `10.0.15.255` (IoT /22 broadcast); no UDM Pro changes required.
- [x] **Thread border router (ZBT-2)** — DONE (native `services.openthread-border-router`, migrated off the container 2026-08-01). Original note: Home Assistant Connect ZBT-2 USB dongle ordered. When it arrives: add OTBR (OpenThread Border Router) container to `modules/homeassistant.nix` alongside HA and Matter Server (`--privileged` + host networking), then wire HA's Thread integration to it. The ZBT-2 will be auto-accessible inside privileged containers.
- [x] **Eve Weather outdoor sensor (~$80)** — DONE 2026-08-30 (#636): paired as Matter node 7, `outdoorSensor` set to `sensor.eve_weather_temperature`, close threshold returned to 68°F, mounted shaded under a low eave. Original note: buy, commission over Thread, then set `outdoorSensor` in `modules/ha-window-notifications.nix` to the resulting entity ID (confirm it in Developer Tools → States) and redeploy rivendell. **Mount it in permanent shade** — an outdoor sensor in direct sun reads 10–20°F high, which would fire "close the windows" on every clear morning.

  The window open/close notifications are deployed and running *today*, but off the met.no forecast as a placeholder, which is not the hyperlocal reading they were designed around. Until this is done the thresholds are being compared against a grid forecast, not the yard.

  Weather Underground was evaluated and ruled out: WU only issues API keys to accounts already uploading from their own PWS, so there is no supported way to read a nearby station — hardware is required either way, and once you are buying hardware a sensor in your own yard beats a station a mile off. Eve Weather wins on fit: Matter-over-Thread, IPX4, no cloud and no account, and it pairs with the OTBR + Matter stack rivendell already runs (no new coordinator, no new integration). Runner-up was Ecowitt GW2000 + WH32 (~$85, local push, expandable to rain/wind/solar) — rejected only because it adds a second radio ecosystem.

  Once real hardware is the source, the fallback stops being a silent failover: a dead sensor makes `sensor.outdoor_temperature` unavailable rather than quietly reverting to forecast data, and the `Windows: outdoor temperature sensor unavailable` automation alerts to ntfy after 2h.

- [ ] **Merge the Thread network with Apple's — POSSIBLE, DEFERRED BY CHOICE.** Measured
  2026-08-30 by mDNS `_meshcop._udp` browse from rivendell: there are **two** Thread
  networks in the house.

  | network | border routers |
  |---|---|
  | `MyHome56` (Apple) | 3× HomePod mini (`B520AP`) + 2× Apple TV (`J255AP`, `J305AP`) — 10.0.1.236 / .114 / .64 / .204 / .170 |
  | `OpenThread-0b14` (ours) | rivendell only |

  So five mains-powered Thread routers already exist and are useless to our devices.
  The Eve links direct to rivendell at −85 dBm / LQ 2 with no hop available.

  **The merge only works in one direction.** Apple's border routers manage their own
  network and will not adopt a foreign dataset; rivendell would have to join
  `MyHome56`. HA's iOS companion app holds Apple's `ThreadNetwork` entitlement and can
  import those credentials into HA's `thread.datasets` store (today that store has one
  entry, `source: otbr`, ours).

  **Deferred deliberately — Brian does not want to tie the homelab tightly to Apple's
  ecosystem.** Two real costs back that up: changing OTBR's dataset orphans every
  existing Thread device (they hold the old credentials and need re-pairing), and the
  Thread dataset in `/var/lib/thread` becomes *Apple-sourced* imperative state,
  reproducible only by re-importing from an iPhone — which cuts against the declarative
  principle in CLAUDE.md.

  **The coupling-free alternative that gets the same result:** any *mains-powered*
  Matter-over-Thread device commissioned onto OUR network becomes a Thread router.
  Battery sensors are sleepy end devices and never route, which is why the mesh has no
  depth today. One mains-powered device sited between rivendell and the yard fixes the
  Eve's link with no Apple dependency at all. Prefer this unless the count of Thread
  devices grows enough that one shared mesh clearly wins.

  Cheaper first step, unrelated to either: put the ZBT-2 on a USB extension cable. It is
  plugged straight into a Pi 5 and USB 3.0 ports are strong 2.4 GHz emitters.

### Future Services

Reviewed 2026-09-19 against the live lab. Verdicts below; rejected ideas moved to
"Decided Against" so they stop resurfacing.

- [ ] **Tailscale — HIGH PRIORITY, design first.** The lab has three overlapping
  remote-access mechanisms and no single story for "reach the homelab from
  outside": the Cloudflare Tunnel on orthanc (public ingress for
  `stream`/`vault`/Invidious), the UDM Pro's own WireGuard VPN server (outside
  this repo, unmanaged by Nix), and gluetun's ProtonVPN WireGuard (**unrelated**
  — that is outbound egress for the torrent stack and is not remote access).
  Tailscale's job is the private half: SSH plus the LAN-only dashboards
  (Homepage, Grafana, the three unauthenticated `*-stats` Glances vhosts) with
  no inbound port and no public exposure.

  `services.tailscale` is native, with `authKeyFile` for the sops key, so this
  is declarative. **The goal is consolidation, not a fourth mechanism** — decide
  what retires before deploying. Full comparison and the open decision are in
  "Remote access consolidation" above.

- [ ] **Dead man's switch — external, out-of-band.** See "Observability gaps".
- [ ] **Loki + Alloy — centralized logs.** See "Observability gaps" above; the
  old Promtail sketch there has been replaced.
- [~] **HomeKit migration — IN PROGRESS.** Done: four room bridges declared in
  `modules/homeassistant.nix` (Office, Kitchen, Hall, Boys Bathroom), covering
  all 3 `light.*` entities, `climate.main_floor`, and the 2 kitchen switches;
  the ecobee moved off its cloud integration to `homekit_controller` (2026-09-13).
  Remaining is the part HA cannot answer for itself: **inventory the devices
  still paired directly to Apple Home** and decide which should instead come
  through HA. HA has 477 enabled entities but only 3 lights / 1 climate, so the
  gap is devices HA never sees. Audit from the Home app, not from HA.
- [ ] **SSO (Authelia) — TABLED PENDING DISCUSSION. Do not implement yet.**
  `memory/sso-plan.md` is stale in two ways and must be rewritten before any
  work starts: (a) it specifies an OCI **container**, but nixpkgs has
  `services.authelia.instances.<name>` natively — the container version would
  contradict the declarative principle in CLAUDE.md; (b) its vhost table still
  routes `jellyfin.theshire.io` to pirateship, which moved to orthanc.
  Separately, the *value* has dropped since it was written: nothing is public
  except `vault` and the Invidious set, so Authelia would mostly add a login
  wall between Brian and his own LAN dashboards. Brian wants to discuss scope
  before this is picked up.

### Future Ideas — may or may not happen

Not committed to. Parked here deliberately so they are not mistaken for planned
work.

- [ ] **Paperless-ngx** — document management with OCR (tax docs, warranties,
  receipts). `services.paperless` is native, and the Brother printer is already
  in HA via `ipp`/mDNS so the scan-to-ingest path exists. Host on orthanc, not
  pirateship. The reason this is an idea and not a plan: its entire value
  depends on sustaining a **scanning habit**, and it would add another
  irreplaceable-data path to back up. Revisit if the paper actually piles up.
- [ ] **Audiobookshelf** — native module; fills a real catalogue gap (Jellyfin
  is video, Navidrome is music, nothing serves audiobooks or podcasts). Only
  worth it if audiobooks are actually consumed.
- [ ] **Homebox** — native; home inventory, pairs with Paperless for warranties.
- [ ] **Actual Budget** / **Karakeep** / **Komga** — native modules, pure
  interest-driven. No gap in the lab argues for them.

### Decided Against — do not revisit without a stated change

- **Immich — REJECTED 2026-09-19.** The whole household is on the Apple photo
  ecosystem (iCloud Photos), which already does the job Immich would do:
  library, sharing, faces, and off-device backup, for everyone, with zero
  operational burden. Self-hosting photos would mean **competing with a working
  system and losing** — every family member would have to change apps and
  trust a single Pi-adjacent box with irreplaceable data. This is the one place
  the "no Apple ecosystem coupling" principle does not apply: photos are a
  client-side convenience, not load-bearing homelab infrastructure, and there
  is no automation or integration the lab needs from them.
  *Reopen only if* the household leaves iCloud Photos, or Apple's pricing or
  sharing model changes enough to force the question.

- **Node-RED — REJECTED 2026-09-19.** Contradicts the guiding principle head-on:
  flows live in `flows.json`, authored through a web UI, with no config-file
  equivalent — the exact failure mode that got Uptime Kuma replaced by Gatus.
  And the problem is already solved *better*: five HA-packages-in-Nix modules
  (`ha-bathroom-lights`, `ha-hvac-openings`, `ha-hood-light`,
  `ha-window-notifications`, `ha-dashboard`) put automation logic in the flake
  where it is reviewable in a PR and deployed by deploy-rs. Adopting Node-RED
  would move that logic back out of version control.
  *Reopen only if* HA's own engine plus Nix packages proves unable to express
  something genuinely needed — which has not happened yet.

- **DHCP out of UniFi (Kea) — REJECTED 2026-09-19 (for now).** `services.kea.dhcp4`
  exists and is fully declarative, and moving DHCP into the flake would make the
  IP reservations that currently mitigate the hardcoded-IP fragility reviewable
  in git, plus unlock DNSSEC and auto-DNS for leases. Brian is nonetheless
  keeping DHCP in UniFi: it works, the UDM Pro is the natural owner of the L2/L3
  edge, and moving it puts every device in the house behind a service this repo
  would then have to keep up at all times.
  *Reopen only if* the hardcoded-IP drift actually bites, or a concrete need for
  DNSSEC/lease-DNS appears. Until then set the reservations in UniFi by hand and
  leave it alone.

### Watch list — get Materialious onto an auto-updating source

`modules/materialious.nix` pins a `fetchFromGitHub` tag that **no automation
watches**, so it silently sat five releases behind (2026-07-29 → 2026-08-25).
Checked 2026-08-25; recheck when a bump feels overdue.

- [ ] **nixpkgs package — the outcome we actually want.** Not packaged today.
  Two attempts, both closed unmerged: issue #328282 (package request, closed
  2025-08-30) and PR #362445 (`materialious-desktop: init at 1.6.23`, closed
  2025-09-20). Note #362445 was the **Electron desktop app**, which would not
  help — we serve the web SPA's static tree. What we need is the `materialious`
  web build. If it lands, we inherit updates through the ordinary Saturday
  `flake.lock` maintenance and the local derivation goes away entirely.
  Recheck: `nix search nixpkgs materialious`, plus open nixpkgs PRs.

- [ ] **Container — already available, and NOT the answer. Decided, not pending.**
  `wardpearce/materialious` exists today and Renovate's `custom.regex` manager
  would digest-pin and automerge it like every other image, so "wait for a
  container" is already satisfied. The reason we don't use it is cost, not
  availability:

  1. **It cannot carry our two shaka patches.** `preferredVideoCodecs: ['avc1']`
     and `defaultBandwidthEstimate` do not exist upstream in ANY configurable
     form — verified against 1.17.11: no env var, no settings entry, no UI
     toggle, zero hits for either identifier anywhere under `src/`. They exist
     only because we patch the source before building. A prebuilt image means
     giving up the measured AV1→H.264 startup fix (#524).
  2. It returns config to a `replace_env_vars.sh` sed of VITE_ placeholders at
     container start, replacing build-time baking — and re-opens the `#`-in-an-
     unquoted-dotenv-value truncation trap that `installCheckPhase` guards.

  Revisit ONLY if upstream exposes codec/ABR preferences as configuration. That
  is the single condition that flips this decision.

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

Co-locating Attic on orthanc means post-build hooks push to localhost (fast) instead of over
the network (slow). Also frees mirkwood's NVMe for other use.

Steps:
1. Migrate Attic NVMe data: rsync `/var/lib/attic` from mirkwood → orthanc (with atticd stopped on both)
2. Move `modules/attic.nix` import from `hosts/mirkwood.nix` → `hosts/orthanc.nix`
3. Update Caddy on rivendell: `cache.theshire.io` → orthanc instead of mirkwood
4. Update post-build hook in `modules/base.nix` — URL stays the same (`cache.theshire.io`),
   no change needed if DNS resolves through Caddy
5. Verify cache hits after a clean build on any Pi

---

## OpenClaw: Personal AI Agent on Orthanc

[OpenClaw](https://openclaw.ai/) is an open-source personal AI agent (Gateway daemon) that runs locally, connects to Claude/GPT/local models, has persistent memory, and is controlled via chat apps. Goal: experiment with it in an isolated VM on Orthanc.

**Planned use cases:**
- Email triage/management (Gmail + iCloud)
- LinkedIn message management
- "Summary of my upcoming day" mode
- Home Assistant device control
- Claude models as backend

**Chat interface:** Discord (existing account; bot in a private server)

### Phase 1 — VM Infrastructure [ ]

Enable libvirt on Orthanc (`hosts/orthanc.nix`):
```nix
virtualisation.libvirtd.enable = true;
users.users.brian.extraGroups = [ "libvirtd" ];
```

Deploy orthanc, then create the VM imperatively:
- **OS**: Ubuntu 24.04 LTS (OpenClaw isn't packaged for Nix; no benefit to NixOS here)
- **Specs**: 2 vCPUs, 4GB RAM, 30GB disk
- **Network**: dedicated restricted bridge (see Phase 2)
- **Access**: SSH only, key-based
- **No display needed**: Gateway is fully headless; browser automation uses headless Chrome

Install dependencies in VM:
- Node.js 24 (recommended)
- Google Chrome `.deb` (not the Snap — AppArmor confinement breaks CDP; use the official `.deb`)
- Run: `openclaw onboard --install-daemon`

### Phase 2 — Network Isolation [ ]

Create a dedicated libvirt network (`virbr-openclaw`, `192.168.200.0/24`) with host-side nftables rules on Orthanc:

```
VM (192.168.200.x) CAN reach:
  ✓ Internet outbound (HTTPS 443) — Claude API, Gmail, LinkedIn, Discord API
  ✓ rivendell:8123 (10.0.1.9) — Home Assistant REST API only
  ✓ DNS (Orthanc as resolver, or 1.1.1.1 direct)

VM CANNOT reach:
  ✗ 10.0.0.0/8 except rivendell:8123 (no pirateship, mirkwood, erebor, UDM Pro)
  ✗ Orthanc itself (192.168.200.1) except SSH management
  ✗ Inbound from LAN (nothing initiates connections to the VM)
```

HA access: VM calls `http://10.0.1.9:8123` directly over LAN — no need to go through Caddy/TLS for a local-only integration.

### Phase 3 — Discord Bot Setup [ ]

1. Create a Discord Application + Bot in the [Developer Portal](https://discord.com/developers/applications)
2. Enable **Message Content Intent** (required) + Server Members Intent
3. Invite bot to a **new private server** (keeps agent chatter isolated; limits blast radius)
4. Bot permissions: View Channels, Send Messages, Read Message History, Embed Links, Attach Files
5. Configure in OpenClaw:
   ```json5
   { channels: { discord: { enabled: true, token: { source: "env", id: "DISCORD_BOT_TOKEN" } } } }
   ```
6. After first Gateway start, DM the bot to receive a pairing code and approve via CLI

### Phase 4 — Integrations [ ]

**Secrets** — store in VM at `~/.config/openclaw/.env`, permissions `600`, owned by openclaw service user. Never committed anywhere.

| Secret | Notes |
|---|---|
| `ANTHROPIC_API_KEY` | **Set a spend limit in the Anthropic Console before starting** — an always-on agent will generate ongoing token usage |
| `DISCORD_BOT_TOKEN` | From Developer Portal |
| HA long-lived access token | Create a dedicated HA user (`openclaw`) with limited device permissions — don't use the main account token |
| Gmail credentials | OAuth flow or app password — needs investigation at implementation time (no dedicated OpenClaw docs for Gmail) |
| iCloud app-specific password | Apple requires app-specific passwords for 3rd-party IMAP — generate at appleid.apple.com |

**Integrations to investigate at implementation time** (no dedicated OpenClaw docs exist for these yet):

- **Gmail / iCloud**: likely OAuth flow or browser-automation of webmail — check community skills first before building custom tooling
- **LinkedIn**: almost certainly headless Chrome + browser login (LinkedIn's API is heavily restricted). LinkedIn ToS prohibits automation; low enforcement risk for personal use but worth knowing.
- **Home Assistant**: likely HA REST API via a community skill or custom tool. Create a dedicated HA user with scoped permissions before wiring up.

**HA permissions design**: start narrow. Enable only lights and a specific area (e.g., office). Expand after validating behavior. A misunderstood prompt controlling the wrong devices is annoying; a misunderstood prompt locking doors or killing HVAC is worse.

### Implementation Sequence

When ready:
1. Add libvirt to `hosts/orthanc.nix`, deploy
2. Create restricted bridge + nftables rules on Orthanc
3. Spin up Ubuntu VM, install Node 24 + Chrome `.deb`
4. Run OpenClaw onboarding (`openclaw onboard --install-daemon`)
5. Configure and pair Discord bot (private server)
6. Set API spend limit in Anthropic Console
7. Create dedicated HA user + long-lived token
8. Investigate and configure email integrations
9. Wire up HA integration with narrow permissions
10. Test each use case in isolation before enabling all at once

### Open Questions

- [ ] Does Gmail integration use OAuth (requires registering a Google Cloud app) or browser automation? Check community skills.
- [ ] Does HA integration exist as a community skill, or does it need a custom tool pointing at `http://10.0.1.9:8123`?
- [ ] LinkedIn: verify headless Chrome login flow works before investing time — LinkedIn sometimes enforces 2FA/CAPTCHA for automated logins.
- [ ] If the experiment proves out, codify the VM definition declaratively (nixvirt or microvm.nix) and move it into the flake.

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
