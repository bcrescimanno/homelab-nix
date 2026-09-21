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

- [~] **Install the Eve Energy plug and finish the Eve Door & Window 3-pack (ordered 2026-09-13)** — **2026-09-15: two of three Eves paired.** Office door = Matter node 9, in `openings` in `modules/ha-hvac-openings.nix`. Boys Bathroom door = node 10, drives `modules/ha-bathroom-lights.nix`.

  **✅ DONE — the mesh has a Thread router.** The first Eve Energy plug ("Office Plug") went in **2026-09-15** as **Matter node 11** and took the router role. **Re-verified live 2026-09-20:** Thread Network Diagnostics reports `RoutingRole: 5 (Router)`; rivendell's `ot-ctl neighbor table` shows an **`R`** entry at RLOC16 `0xb000`, ext MAC `923978dd24d28bbc`, **LQ In/Out 3/3, avg RSSI -65 dBm** — the strongest link in the mesh. `ot-ctl router table` lists two allocated routers (id 7 = rivendell/leader, id 44 = the plug).

  The plug is carrying real traffic, not sitting idle: it parents **two of the three** sleepy end devices — node 9 office door (`0xb005`, LQ 3) and node 10 bathroom door (`0xb087`, LQ 2). Node 7 Eve Weather remains a direct child of the border router (`0x1cc0`, -81 dBm / LQ 2), which is expected — the fence is closer to rivendell than to the office plug. This matches the 2026-09-15 outcome exactly; nothing has drifted.

  Remaining: pair the **third Eve Door & Window**, and install the **second Eve Energy plug**. Add any cooling-relevant sensor to `openings` and deploy rivendell. Full steps in `devices/contact-sensors.md` → Decision and `devices/smart-plugs.md` → Decision.

  Pairing gotcha (2026-09-15): the second sensor hung forever on the iPhone's "Connecting" screen while the device advertised happily on BLE and matter-server logged **nothing at all** — no `Starting Matter commissioning` line, because the setup code never reached it. **Rebooting the iPhone fixed it instantly.** iOS's MatterSupport extension wedges after a successful commissioning, so every device after the first in one session can stall. Reboot the phone before debugging the stack.

- [ ] **Presence sensor for the Boys Bathroom** — **2026-09-15: the door half is done.** `modules/ha-bathroom-lights.nix` is now door-gated (closed door = occupied; 30s after the door opens, 5-min open-door timeout, 60-min closed backstop), and the 15-minute timer and the 19:00–20:30 shower window are **deleted**. What remains is the motion half of **wasp-in-a-box**: an IKEA MYGGSPRAY (~$10, Thread PIR) alongside the Eve that is now installed. Motion while the door is closed would hold "occupied" so presence outlives the door state; door open + no motion ~2 min → off. If the kids' habit of leaving the door open makes that pointless, use a Meross MS605 (mmWave) alone. Cats can only keep the light on longer, never turn it on. **The gap the motion sensor still closes:** someone in the bathroom with the door **open** loses the light after 5 min, and someone who opens the door but stays in the room loses it after 30s (accepted deliberately — they just flip it back on). Detail in `devices/presence-sensors.md` → "use cases and pets".

### Power / Battery Resilience

**DECIDED 2026-09-19: NUT secondaries are a definite yes — do them first, on their
own.** The full load-shedding tier design below is a bigger argument that does not
need to be settled to get the main benefit. Today three of four hosts take an
unclean power cut on every outage, and the software is already in the repo. The
contained first step is:

- [x] **NUT secondaries on mirkwood, pirateship and orthanc — DONE 2026-09-19**
  (`modules/nut-secondary.nix`). All three run `upsmon` in netclient mode against
  `tripplite@10.0.1.9` as `type=secondary`, authenticating as a dedicated
  `upsmon-secondary` upsd user that does NOT hold primary privileges. Verified:
  upsd logged all three logins (10.0.1.8 / 10.0.1.35 / 10.0.1.10), and stopping
  upsd for 40s — past DEADTIME — left every secondary up and self-recovering,
  which is the property that makes rivendell's kernel reboots safe. Shutdown
  ordering comes free from the primary/secondary FSD + HOSTSYNC protocol, so
  rivendell goes last without anything declaring it. **Still outstanding from the
  original note:** orthanc's BIOS *Restore on AC Power Loss*, and the staged
  early-shutdown tiers below (blocked on "is orthanc even on the UPS?" and on
  NOTIFYCMD running unprivileged — see the module header).

- [ ] ~~**NUT secondaries on mirkwood, pirateship and orthanc.**~~ Superseded by
  the entry above; original text kept for the reasoning. Add `upsmon` with
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

#### Measured power report (2026-09-19)

Tripp Lite SMC15002URM, `ups.power.nominal` 1500, battery 100%, input 119 V.

| condition | `ups.load` | `output.current` | `battery.runtime` |
|---|---|---|---|
| all four hosts idle | **18%** | 1.0 A | **3680 s — 61 min** |
| orthanc at full CPU (32 threads) | **29%** | 2.0 A | **2036 s — 34 min** |

Per host:

| host | measurement | how |
|---|---|---|
| orthanc | **19.0 W** CPU package, idle | `intel-rapl:0/energy_uj`, 95.045 J over 5 s (root) |
| rivendell | 2.65 W internal rails | `sudo vcgencmd pmic_read_adc`, sum of V×A |
| mirkwood | 2.48 W internal rails | same |
| pirateship | 1.91 W internal rails | same |

**Three conclusions, and the third is the plan:**

1. **orthanc IS on the UPS** — settled. Stressing its CPU moved `ups.load`
   18% → 29%, which also answers the question this section has carried since
   2026-08-09. (erebor and the network gear are still unconfirmed; that needs a
   physical look at the UPS outlets.)

2. **orthanc's CPU alone is 11 of the 18 load points**, and driving it from idle
   to busy costs **27 minutes** of runtime. orthanc's 19 W idle package is also
   below the 29 W quoted in `hosts/orthanc.nix`, consistent with auto-cpufreq's
   own overhead being gone since #736.

3. **orthanc is the ONLY load worth shedding.** The Pi 5s draw ~2 W each on their
   internal rails, so shedding one buys nothing measurable; erebor and the
   network gear are the other big draws and neither is ours to switch off. So do
   NOT build a general tiering framework — the measurement points at one lever,
   on one host. This is the main reason the tier sketch below was not implemented
   as written.

**Do not trust absolute watts from this UPS.** `ups.power` reports `0.0` and
`output.voltage` reports `0.0` — several wattage fields are broken in its USB HID
data, and `output.current` has one decimal and read exactly 1.0 / 2.0, which is
inconsistent with the 18%→29% load ratio. Reason in **load points and runtime**.
Total draw is roughly 120–200 W and that is an estimate, not a measurement.

Runtime scales nonlinearly — fitting the two points gives runtime ≈ C/load^1.24,
so halving load more than doubles it. **Extrapolating below the measured range is
unreliable**, so the projected post-shed runtime is deliberately not quoted as a
number here. The honest way to get it is to power orthanc off once and read
`battery.runtime`; that is a two-minute test worth doing at a quiet moment.

- [x] **Shed orthanc early — DONE 2026-09-19.** `homelab.ups.shedAfterMinutes = 5`
  and `shedBelowCharge = 50` in `hosts/orthanc.nix`, implemented in
  `modules/nut-secondary.nix` as a root systemd timer polling `upsc` every 30 s
  (12 ms CPU per tick). A root poller rather than an ONBATT hook because
  NOTIFYCMD runs unprivileged as `nutmon` and cannot `poweroff`. **Fails safe:**
  an unreachable `upsc` never sheds and never clears accumulated state, because
  an unreachable UPS is not evidence of an outage. All six branches were tested
  with a stubbed `upsc` on the host (hold / elapsed-shed / charge-floor-shed /
  mains-reset / unreachable-preserves-state).

- [x] **Wake orthanc back up after a shed — DONE 2026-09-19.** WoL armed on
  orthanc (`networking.interfaces.enp5s0.wakeOnLan.enable`; it read
  `Supports Wake-on: pumbg` but `Wake-on: d`, so nothing would have woken it),
  plus a waker on rivendell (`homelab.ups.wakeOnRestore` in `modules/nut.nix`).

  **`Restore on AC Power Loss` is NOT a substitute and never was** — a shed is a
  soft poweroff while the UPS still supplies AC, so the BIOS sees no AC
  transition. The two mechanisms cover disjoint cases and both are wanted:

  | case | recovered by |
  |---|---|
  | shed, then mains returns (**the common one**) | WoL only |
  | battery ran flat, UPS cut output | BIOS auto-restore only |

  Three guards, because a spurious wake would resurrect a host deliberately
  powered off for maintenance: (1) only after an outage rivendell itself
  witnessed; (2) only if it lasted ≥ `minOutageMinutes` (5, matching orthanc's
  shed threshold); (3) only once mains has been continuously up for
  `stableMinutes` (3) — the **anti-flap buffer**, since utilities bounce power
  repeatedly while restoring and every bounce restarts the clock. The *longest*
  outage segment is remembered, not the latest, or a 20-minute outage followed by
  a 10-second flicker would overwrite the duration with 10s and silently never
  wake. State lives in `/var/lib`, not `/run`, so a rivendell that shut down too
  still remembers it owes a wake. Attempts are bounded (3, 180s apart) and a
  give-up sends a distinct ntfy naming the BIOS/physical-press fallback.

  Verified: all nine branches against the deployed script with stubbed
  `upsc`/`ping`/`wakeonlan` (no-outage, short-outage, buffer-hold, flap-reset,
  longest-segment retention, send, retry-spacing, exhausted, and the full
  outage→buffer→send→boot→success sequence); and real magic packets from
  rivendell were **captured arriving on orthanc's `enp5s0`** (UDP:9, 102 bytes,
  0 dropped).

- [!] **WoL does NOT currently wake orthanc — TESTED AND FAILED 2026-09-19.**
  orthanc was powered off, the deployed waker sent two magic packets 180s apart,
  and **orthanc did not come up**; Brian pressed the button after a few minutes.

  Where it fails is now pinned down. After that manual boot, `ethtool enp5s0`
  reported **`Wake-on: g`** with no intervention, so udev *is* applying the
  `.link` file and the NixOS side is correct and durable. The packets were also
  confirmed arriving on the NIC earlier. **So the break is below the OS: the
  board is not honouring PME wake from S5.** On this board (ASUS X570-E Gaming)
  that is almost always one of two BIOS settings, both under
  Advanced → APM Configuration:
    * **ErP Ready = Enabled** — cuts standby power to PCIe/LAN in S5, which
      disables WoL outright. Most likely culprit.
    * **Power On By PCI-E/PCI = Disabled**.

  Note the waker's own logic was correct throughout: two attempts, correct
  broadcast and MAC, then it noticed orthanc was back and cleared state. It
  cannot distinguish "my packet worked" from "someone pressed the button", so
  its success push after a manual recovery is expected, not a bug.

- [ ] **ONE BIOS TRIP FIXES THREE THINGS** — all in the same APM Configuration
  menu, so do them together:
    1. `ErP Ready` = **Disabled** (WoL from S5)
    2. `Power On By PCI-E/PCI` = **Enabled** (WoL from S5)
    3. `Restore AC Power Loss` = **Power On** (the battery-ran-flat case)
  Re-test afterwards: power orthanc off, then
  `wakeonlan -i 10.0.1.255 fc:34:97:a6:4f:ad` from rivendell.

- [x] **Decided 2026-09-19: leave the 5-minute shed exactly as it is.** Brian's
  call, made knowing the consequence — a shed orthanc needs a physical press until
  the BIOS trip above happens, so every outage longer than 5 minutes costs the
  builder, Jellyfin, the attic cache and the Vaultwarden tunnel until someone
  notices. Runtime for the network wins over orthanc's availability.
  `shedAfterMinutes` stays `5`; it was **not** raised and **not** set to `null`.
  Do not revisit this without a stated change — revisit only once WoL is proven.

- [x] **erebor gets a clean shutdown — DONE 2026-09-19** (`homelab.ups.remoteShutdown`
  in `modules/nut.nix`). erebor is Debian 11 + systemd under UniFi OS, so
  rivendell SSHes in and runs `poweroff` at **25% charge** — well clear of
  `battery.charge.low` (10), where upsmon sets FSD and everything else starts
  shutting down, so the array gets its own quiet window to flush.

  **Ordering was the whole difficulty.** erebor's shares are `hard` NFS mounts,
  so IO to a vanished server blocks forever; a consumer still holding a mount
  would hang, then fail to unmount at FSD, stall past systemd's timeout and take
  the very unclean cut this prevents. Handled in two parts: rivendell lazily
  unmounts **its own** two live mounts (`/var/backup/erebor`,
  `/var/lib/media/music` — lazy so Music Assistant or restic cannot veto it), and
  `waitForDown` verifies orthanc and pirateship are already gone. **pirateship
  now sheds at 35% charge** purely to make that true — not for power, since it
  draws ~1.9 W. A 5-minute grace then bounds the wait so a consumer that never
  sheds cannot deadlock the sequence and leave the array to be cut anyway.

  Verified: ten branches against the deployed script with stubbed
  `upsc`/`ping`/`ssh`/`mountpoint`/`umount`/`curl` — mains no-op, charge above
  threshold, grace hold, consumers-down shutdown, no-repeat, mains reset, the
  unmount ordering, SSH failure raising a priority-5 alert, `upsc` unreachable
  doing nothing, and grace expiry proceeding with a warning.

- [x] **MANUAL PREREQUISITE for the above: authorize the key on erebor — DONE
  2026-09-19, and verified end to end.** Brian added it through the UniFi console's
  SSH-key UI and `sudo ssh -i /run/secrets/erebor_shutdown_key -o BatchMode=yes
  root@10.0.1.22` now succeeds from rivendell, with `/sbin/poweroff` present
  (a symlink to `/bin/systemctl`). Note for later: `uname -a` on erebor reports
  `5.10.216-alpine-unas`, which is only Ubiquiti's kernel build name — the
  userspace is genuinely Debian 11 bullseye with systemd 247, so `poweroff`
  behaves like systemd's and not busybox's. Keep using the **UniFi UI**, not
  `/root/.ssh/authorized_keys`, or a UniFi OS update will silently drop it:

  ```
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHR2C10cUgtEdcQ7YdnDNBet9eTQmD5ByHcZT/920vIO rivendell-erebor-shutdown
  ```

  Then confirm from rivendell:
  `sudo ssh -i /run/secrets/erebor_shutdown_key -o BatchMode=yes root@10.0.1.22 true`

- [ ] ~~**Low power mode — shed load while running on battery**~~. **Superseded —
  built and deployed 2026-09-19** (#741 secondaries, #743 shed + erebor + waker);
  original text kept below for the reasoning, and because it records what the
  2026-08-09 outage actually looked like. Note the design below reasons about
  *tiers*; the measured power report proved that wrong — orthanc is the only load
  worth shedding, so no tiering framework was built. Prompted by the 2026-08-09
  outage (~19:57, all hosts hard-cut).

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

**Decided 2026-09-20: Tailscale replaces the UDM Pro WireGuard server**, with a
time-boxed break-glass window rather than an open-ended one. The UDM WireGuard
server stays switched on until **2026-10-04** so there is a way in that does not
depend on Tailscale's control plane while the tailnet is still unproven. On that
date the client profiles are deleted from the phone and laptop and the server is
turned off in the UniFi UI. If it is still on after that date it has become
drift, which is the thing this section exists to prevent.

The implementation landed in `modules/tailscale.nix`, imported by `base.nix`, so
all four hosts join. Read that file's header before changing any of it — three
things in it are load-bearing and each fails silently:

- **Nothing opens a port, on purpose.** NixOS emits its top-level
  `allowedTCPPorts` rules with no `-i` match, so the tailnet already sees exactly
  the LAN-open surface and nothing more. mirkwood's Prometheus stays closed for
  free. `trustedInterfaces = [ "tailscale0" ]` would break that and must not be
  added.
- **`extraUpFlags` applies only at first authentication**; `extraSetFlags` is the
  every-activation reconcile path. Routes and the exit node live in the latter.
- **`--accept-dns=false` on the hosts.** Client devices should accept tailnet
  DNS — that is what makes Blocky follow the phone. The servers must not, or all
  host name resolution, including the nightly upgrade's flake fetch, starts
  depending on tailscaled.

Topology: rivendell **and** mirkwood both advertise `10.0.1.0/24`, so the subnet
router has the same redundancy the resolvers already have. orthanc advertises an
exit node (opt-in per client, costs nothing unselected). pirateship stays a plain
client — `useRoutingFeatures` above `none` would loosen reverse-path filtering on
the host running gluetun's kill switch. The IoT VLAN `10.0.12.0/22` is **not**
advertised; rivendell's `eth0.4` isolation is deliberate.

Remaining work, in order:

- [ ] **Bootstrap the tailnet.** Sign up with **GitHub**, not Apple — see the
      no-Apple-ecosystem-coupling constraint. The identity provider is chosen once
      and is painful to change later, and GitHub is already the account this
      repo's automation authenticates as.
- [ ] **Paste `tailscale/policy.hujson` into Access Controls — before creating the
      OAuth client, not after.** The OAuth client's tag scope can only select tags
      that already exist in `tagOwners`, so the policy has to land first or
      `tag:homelab` will not be offered.
- [ ] **Create the OAuth client**: Settings → OAuth clients, scope `auth_keys`
      (write), tag `tag:homelab`. The secret is shown exactly once. Plain auth keys
      cap out at 90 days and would need a remembered re-auth, which is the drift
      this avoids.
- [ ] **Add `tailscale_auth_key`** (the OAuth client secret, `tskey-client-…`) to
      all four `secrets/*.yaml`. Until this exists on a host, that host's deploy
      fails at sops activation — this gates everything below.
- [x] **Deploy** orthanc → mirkwood → rivendell → pirateship — done 2026-09-20.
      All four enrolled `Running` under `tag:homelab`; `tailscaled-set` returned
      `success` everywhere, which is what confirmed `--accept-dns=false`,
      `--advertise-routes` and `--advertise-exit-node` are accepted `set` flags.
      Verified: `CorpDNS=false` and no `100.100.100.100` in `resolv.conf` on every
      host; `10.0.1.0/24` advertised by rivendell + mirkwood, `none` on
      pirateship; orthanc offers the exit node; pirateship's forwarding and
      rp_filter sysctls byte-identical to the pre-deploy baseline, gluetun never
      restarted, qBittorrent still `Session\Interface=10.2.0.2`, and a fresh
      `vpn-leak-check` returned success.

      **Deploy from a worktree with `./scripts/deploy <host>`, never the bare
      `deploy`.** The PATH entry resolves to the MAIN checkout's copy and the
      script derives `FLAKE` from its own location, so `deploy orthanc` silently
      deployed the main checkout's stale pre-NUT branch and reverted orthanc's
      upsmon/nutmon/`homelab-ups-shed.timer` while reporting success. Magic
      rollback cannot catch this — the deploy genuinely succeeded, it was just the
      wrong flake. Tell: activation logs `removing user`/`removing secret` for
      things your change only adds.
- [x] **Routes and exit node approved** — `autoApprovers` covered them with no
      console clicking. rivendell reports `PrimaryRoutes=10.0.1.0/24` and carries
      it in `AllowedIPs`. Note this is only visible from the advertising node or
      the console: tagged nodes have an empty peer list by design (see
      `tailscale/policy.hujson`).
- [x] **Tailnet DNS** — done 2026-09-20, after the deploy, as planned. Global
      nameservers set to rivendell `100.115.136.4` and mirkwood `100.79.85.116`,
      Override local DNS + MagicDNS on.

      **`*.theshire.io` publicly resolves to the WAN IP** (`grafana.theshire.io`
      → CNAME `theshire.io` → `73.231.204.140`), so before this step an off-LAN
      browser dialled the WAN and hung rather than failing fast. This step is what
      makes the split-horizon answer reach the phone — it is not a nicety, it is
      the difference between working and stalling.
- [x] **Verified from cellular** 2026-09-20: `grafana.theshire.io` loads on the
      real wildcard cert and `ssh rivendell` resolves via MagicDNS. Blocky's CSV
      query log shows 45 rows with the phone's tailnet address `100.127.74.71` in
      the client column, and the tailnet listener returns `0.0.0.0` for
      `doubleclick.net` and `pagead2.googlesyndication.com` while `github.com`
      resolves normally — so ad-blocking genuinely follows the phone.

      The **negative** test was proven at the rule level rather than by one curl,
      because a curl from mirkwood to its own tailnet address arrives on `lo`,
      which the firewall accepts, and would have falsely passed. On mirkwood:
      zero accept rules for 9090, zero `tailscale0`-specific rules, and the only
      `-i` accepts are `lo` and ICMP. Prometheus binds `*:9090`, so the firewall
      is the only thing protecting it — and it refuses on `tailscale0` for the
      same reason it refuses on `eth0`.

      Still untested: erebor `10.0.1.22` through the subnet route, and whether the
      phone gets a `direct` path rather than `relay`.
- [x] **pirateship re-verified** after its deploy: forwarding and rp_filter
      sysctls byte-identical to the pre-deploy baseline, gluetun never restarted,
      qBittorrent still `Session\Interface=10.2.0.2`, fresh `vpn-leak-check`
      returned success with no latch.
- [ ] **Add the ACL gitops workflow** (`tailscale/gitops-acl-action`, same shape
      as `check-overlays.yml`) once `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET` are
      repo secrets. Until then the console and `policy.hujson` can drift.
- [ ] **2026-10-04: turn the UDM WireGuard server off** and delete the client
      profiles.
- [ ] Add the tailnet range to qBittorrent's `WebUI\AuthSubnetWhitelist` when the
      login-friction work happens (see that section).

### NAS (erebor) — Remaining Work

erebor is online (10G SFP+ at 10.0.1.22, 1G ethernet at 10.0.1.21 for management).

- [ ] **Monthly Btrfs scrub**: SSH into erebor and add `btrfs scrub start /` to crontab. Btrfs has no scheduled scrub in the UniFi Drive GUI.
- [ ] **Backup coverage**: verify R2 restic snapshots include erebor-resident data after media migration.

### DNS / Monitoring

#### Observability gaps (reviewed 2026-09-19)

- [~] **External dead man's switch — every alert path terminates at rivendell.**
  Traced 2026-09-19. Prometheus and Alertmanager run on **mirkwood**, but
  Alertmanager's only receiver posts to `http://10.0.1.9:2586` — rivendell's
  ntfy (`modules/grafana.nix`). Gatus runs on rivendell. ntfy *is* on rivendell.
  The reboot-policy and post-upgrade pushes go to `rivendell:2586`. Every bespoke
  `OnFailure` script pushes there too.

  **So if rivendell is down, or just its ntfy is broken, the lab goes silent —
  including the alert that would say rivendell is down.** Gatus has a `mkTcp`
  check for rivendell, but Gatus cannot report the death of its own host. This
  is the structural version of every silent failure in the memory index.

  **BUILT 2026-09-20 in `modules/deadman.nix`** (mirkwood + orthanc), pending
  account setup and deploy. Items 1 and 2 below are both delivered by it; item 3
  is deliberately not being done.

  1. **External dead man's switch — DONE.** Implemented as an *earned* heartbeat
     rather than a liveness ping, which is the part the original sketch got
     wrong: a timer that just curls an outside endpoint stays green while ntfy
     is dead, leaving the actual gap open. Instead each host publishes a random
     token to a dedicated `deadman-probe` ntfy topic on rivendell, reads it back
     through the poll API, and only then pings healthchecks.io. A failed
     round-trip POSTs `/fail` immediately instead of waiting out the grace
     period. One check per host, never a shared one.
  2. **Second notification channel — DONE, as a side effect.** healthchecks.io
     alerts out via a **public ntfy.sh topic**, reusing the existing ntfy iOS
     app. Routing it back through `ntfy.theshire.io` would rebuild the single
     point of failure one level up, so it deliberately shares nothing with the
     path it reports on. Payloads stay at "host X round-trip failed", not
     diagnostics, since they leave the premises.
  3. **Cross-monitoring (second Gatus) — NOT doing.** The round-trip probe
     already answers "is rivendell's ntfy alive", from two hosts, and reports it
     somewhere that survives the house being down. A second Gatus would add a
     service whose own alerts still have to escape, which is the original
     problem again.

  **Remaining before this is real:**
  - [ ] Create the healthchecks.io account + two checks and the ntfy.sh
        integration; recipe is in the `modules/deadman.nix` header.
  - [ ] Paste each ping URL into `deadman_ping_url` in the matching host's sops
        file, replacing the `REPLACE-ME-…` placeholder. Until then the hosts
        deploy fine and `DeadmanSwitchUnprovisioned` alerts hourly — an
        unprovisioned switch must never look like a healthy one.
  - [ ] Test by **actually stopping ntfy on rivendell** and confirming the
        ntfy.sh alert still arrives — simulating around the constraint that
        matters proves nothing. Test the *resolve* path separately, and let it
        outlast the retry period.

- [x] **Loki + Alloy — centralized logs. DONE 2026-09-20 (#754, and the Blocky
  query log in the PR that follows it).** Supersedes the Promtail sketch below.
  Originally scoped only as a prerequisite for the Pi-hole-style DNS dashboard.
  That undersells it: this lab's characteristic failure mode is **silent**, and
  every instance in the memory index was found by SSHing to a host and grepping
  a journal — empty backups green for four months (#569), the timer oneshot
  reporting success, `systemctl show` returning success for an unknown unit, the
  restart loop that looked healthy, nixpkgs-watch swallowing its own error.

  What shipped:

  - `modules/loki.nix` — Loki 3.7.7 on orthanc, single binary, TSDB + schema
    v13, filesystem storage, **14-day retention**, not backed up.
  - `modules/alloy.nix` — Alloy 1.17.1 on all four hosts via `base.nix`.
    Promtail was avoided as planned; it hit EOL 2026-03-02.
  - `modules/grafana.nix` — Loki datasource (uid `homelab-loki`), Alloy + Loki
    scrape jobs, and three alert rules that watch the pipeline itself.

  Measured volume rather than estimated: orthanc's journal ~57 MB/day, mirkwood
  ~2 MB/day, and **Blocky's query log 23–31 MB/day per DNS host — twice all
  four journals combined**. ~125 MB/day raw, ~250–400MB in Loki at 14 days,
  against 1.7TB free. 97 streams across four hosts.

  Two corrections to what this entry used to say:

  - **"Ship `/var/log/blocky/*`" was not possible as written.** Blocky ran
    `DynamicUser`, so that path is a symlink into `/var/log/private`, which
    systemd keeps at 0700 root:root — no group membership can reach it. Fixed
    by giving Blocky a static user; systemd migrates the directory but does
    **not** chown it, so an ExecStartPre chown is mandatory or Blocky cannot
    write its own log. Both behaviours were verified on a throwaway unit on
    orthanc before touching a resolver.
  - **The WAL open question is settled: accept the gap.** Alloy's WAL is
    disabled by default *and* gated behind `--stability.level=experimental`, so
    it is deliberately unused. orthanc's reboots still thin the history.

  Still open: **Loki ruler → mirkwood's Alertmanager** for log-derived alerts,
  which is what would make this active rather than passive. Deferred, not
  rejected.

- [x] **Grafana DNS dashboard (Pi-hole-style panels). DONE 2026-09-20.**
  `dashboards/dns-queries.json`, "DNS — Query Analytics" (uid
  `homelab-dns-queries`), provisioned to mirkwood alongside the existing
  Prometheus-fed "Blocky" dashboard, which is deliberately kept: the two are
  not redundant, and the split is now load-bearing (see the parsing note
  below). 18 panels over five rows — overview stats, answer-source breakdown,
  blocked vs allowed, three client rankings (volume, blocked, block rate),
  top domains and
  blocklist rules, and a formatted query log. Variables: resolver (multi),
  a case-insensitive client substring, and a blocked/allowed filter for the
  log panel.

  The original premise held — `blocky_query_total` carries only `client` and
  `type`, so none of this was expressible in Prometheus. Five things found
  while building it that are not obvious from the data:

  - **Only the six LEFT-HAND columns of the query log are parseable.** It is
    tab-separated, but written by a CSV writer, and the `answer` column is
    quoted *and contains literal tabs* whenever it holds an HTTPS/SVCB record
    (miekg/dns serialises RRs with them). A positional parse past `answer`
    therefore mis-assigns every later column on ~1.5% of lines — it reads the
    response type as `IN`. Everything here stops at `question`, which is
    lossless (verified: parsed line count == raw line count). Query type and
    response code sit past that break, which is why they stay on the
    Prometheus dashboard.
  - **sprig's `hasPrefix` takes the PREFIX FIRST.** `hasPrefix .reason
    "BLOCKED"` is not an error — it silently returns false for every line, and
    the panel renders a clean, entirely wrong breakdown. Signature failure
    mode of this lab; every `label_format` here is written prefix-first.
  - **`topk()` does not avoid Loki's `max_query_series`.** The limit bounds
    what a query MATERIALISES, so `topk(15, sum by (question) (...))` still
    builds one series per domain and dies at 24h on the default 500 while
    working fine at 6h. Fixed in `modules/loki.nix` by raising the limit
    against measured cardinality (972 distinct domains). `approx_topk` is the
    feature meant for exactly this and is **broken in Loki 3.7.7** — see that
    module's comment before trying it.
  - **The reason column has more values than the docs suggest** — `CACHED
    NEGATIVE`, `CUSTOM DNS` (with a space) and `Special-Use Domain Name` all
    appear. Matching `reason == "CACHED"` silently undercounts the cache hit
    rate; the dashboard matches `CACHED.*`.

  - **Sort ranked panels in LogQL with `sort_desc()`, never with a `reduce`
    transformation.** A Loki instant query returns one frame per series tagged
    `meta.type: numeric-multi`, so `sortBy` alone has nothing to reorder — it
    sorts rows *within* a frame. The obvious fix, `reduce` in `seriesToRows`
    mode, is worse than useless: it builds its output with `{...frame}` and so
    copies that `numeric-multi` meta onto a frame that is no longer that shape.
    Downstream the panel finds no numeric field and renders every bar as
    no-value, with no error anywhere. Shipped once and, because these panels
    also carried `noValue: "0"`, it read as "every widget says zero" rather
    than "every widget is broken" — `noValue` is now off on the ranked panels
    for that reason. `sort_desc()` around the existing `topk()` fixes the order
    server-side and needs no transformation at all.

    Verified by driving headless Firefox over Marionette against the live
    Grafana and reading the rendered DOM — transformations run only in the
    browser, so nothing short of a real browser can check them, and mirkwood
    has no renderer plugin. That harness is the only way any of this was
    settled; assume the same is needed for the next transformation change.

  - **Client names are shortened in LogQL, and the reason some are missing is
    upstream of Blocky entirely.** Every query trims the domain off
    `client_name` with `trimSuffix ".home.theshire.io" | trimSuffix
    ".theshire.io"` — a suffix trim rather than a cut at the first dot,
    because an unresolved client IS its own IP in this column and `10.0.1.184`
    must not become `10`. The same guard covers IPv6 and the dotless names the
    IoT VLAN returns (`THERMADOR-PRD486WIGU-68A40E2C6376`).

    What the shortening exposed is that **a failed PTR is cached for one hour,
    hardcoded**, in `client_names_resolver.go`: the miss is stored exactly like
    a hit, so one failure names that device by its IP for the next hour of log
    lines. Measured on 2026-09-20: 10.0.1.184 logged as
    `iPhone.home.theshire.io` for hours 01–08 and as `10.0.1.184` for 09–17,
    ~8,000 lines under the wrong identity. **The PTRs fail because UniFi keeps
    one record per hostname and several devices answer to the same one** —
    `iPad.home.theshire.io` resolves to whichever of three iPads renewed last,
    and the other two get NXDOMAIN. Confirmed by digging the UDM Pro directly:
    .63 answered 20/20, .69 and .166 answered 0/20, and all three log as
    "iPad" and merge into one bar.

    Fixed as far as this side can: `clientLookup.clients` in `modules/dns.nix`
    pins the five machines, loopback (the second-busiest client on mirkwood,
    16k queries in 6h, logged as `127.0.0.1`) and the tailnet addresses, which
    live in CGNAT space and can never have a PTR. Static entries are consulted
    before the cache path, so they cannot be poisoned. **The rest needs
    device-side renaming** — the duplicate "iPad"/"iPhone" names — which is
    also the only thing that will split them apart in the rankings.

  - **Conditional forwarding covered one VLAN out of six.** The reverse zone
    was `1.0.10.in-addr.arpa`, so `dig -x` through Blocky returned nothing for
    anything off 10.0.1.0/24 while the UDM Pro answered the same query fine.
    Now `0.10.in-addr.arpa`, one suffix covering 10.0.0.0/16. This never
    affected the dashboard — `clientLookup` queries its upstream directly and
    bypasses conditional forwarding, which is why IoT devices were named
    correctly the whole time the zone was broken.

  Not done, deliberately: the two resolvers each log what they answered and a
  client using both is counted in both, so `All` sums rather than
  de-duplicates. De-duplicating would need a query-side join on
  (timestamp, client, question) that Loki cannot do cheaply; the host picker
  is the escape hatch and the Notes row says so.

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

- [~] **Tailscale — IN PROGRESS.** Designed and written; awaiting the tailnet
  bootstrap and the sops key. Its job is the private half of remote access: SSH
  plus the LAN-only dashboards (Homepage, Grafana, the three unauthenticated
  `*-stats` Glances vhosts) with no inbound port and no public exposure. It
  **replaces** the UDM Pro's WireGuard server — the goal was consolidation, not a
  fourth mechanism — and the Cloudflare Tunnel stays, because it serves people
  who cannot be asked to join a VPN. gluetun's ProtonVPN WireGuard is
  **unrelated** and must not be folded in: that is outbound egress for the
  torrent stack.

  `modules/tailscale.nix` is written and imported by `base.nix`. The decision,
  the topology, the three silent-failure traps in that module, and the remaining
  checklist are in "Remote access consolidation" above.

- [~] **Dead man's switch — external, out-of-band.** Built 2026-09-20 in
  `modules/deadman.nix`; awaiting the healthchecks.io account and a deploy. See
  "Observability gaps".
- [x] **Loki + Alloy — centralized logs.** DONE 2026-09-20 (#754). See
  "Observability gaps" above; the old Promtail sketch there has been replaced.
- [~] **HomeKit migration — IN PROGRESS.** Done: four room bridges declared in
  `modules/homeassistant.nix` (Office, Kitchen, Hall, Boys Bathroom), covering
  all 3 `light.*` entities, `climate.main_floor`, and the 2 kitchen switches;
  the ecobee moved off its cloud integration to `homekit_controller` (2026-09-13).
  Remaining is the part HA cannot answer for itself: **inventory the devices
  still paired directly to Apple Home** and decide which should instead come
  through HA. HA has 477 enabled entities but only 3 lights / 1 climate, so the
  gap is devices HA never sees. Audit from the Home app, not from HA.
### Login friction — the work Authelia was rejected in favour of

Queued 2026-09-19. The goal is **fewer prompts**, not more auth. Each item uses the
app's own native setting; nothing new is deployed. Do these as a batch, separately
from any power or networking change.

**Read this first — the one real hazard.** `DisabledForLocalAddresses` and
subnet-whitelist settings judge the **connecting** address, which through Caddy is
*rivendell*, not the browser. So they effectively disable auth for anything
arriving via the reverse proxy, including from off-LAN **if a vhost were ever
published**. That is safe today only because these vhosts resolve solely through
split-horizon DNS, and Tailscale keeps remote access inside the same boundary.
This turns "these vhosts stay private" from a fact into a **load-bearing
invariant** — say so in a comment next to every setting below. If an arr UI ever
needs to face an untrusted network, switch that app to
`AuthenticationMethod=External` and revisit SSO.

- [ ] **Radarr / Sonarr / Prowlarr / Lidarr** — set
  `AuthenticationRequired=DisabledForLocalAddresses` (all four are currently
  `Forms` + `Enabled`). Keep `AuthenticationMethod=Forms` so a login still exists
  for any non-local path. These live in each app's `config.xml`, which the
  containers own, so this needs the same treatment qBittorrent already gets: a
  `preStart` that edits the file idempotently. Do not hand-edit via the UI — it
  will drift and nothing will notice.

- [ ] **qBittorrent** — add `WebUI\AuthSubnetWhitelistEnabled=true` plus
  `WebUI\AuthSubnetWhitelist` covering the LAN and the tailnet range. This is a
  natural extension of the existing `preStart` in `modules/arr-stack.nix`, which
  already rewrites `WebUI\Username`, `WebUI\Password_PBKDF2`,
  `WebUI\LocalHostAuth` and clears `WebUI\BanList`. Reuse that machinery rather
  than adding a second mechanism.

- [ ] **Grafana** — enable `auth.anonymous` with the `Viewer` role so dashboards
  open with no prompt, keeping the admin login only for edits. Native and
  declarative in `modules/grafana.nix`, which today sets only `security.admin_*`.

- [ ] **Homepage widgets — the cheapest win, and it removes the *reason* to log
  in.** All 12 widgets today are Glances system stats; there are **zero** arr
  widgets. Homepage has native `radarr`/`sonarr`/`prowlarr`/`lidarr`/`sabnzbd`/
  `qbittorrent`/`jellyfin` widgets that read via **API key**, no login involved.
  Most "did that grab work / what's queued" trips into an app become a glance at a
  page already open. API keys via sops (the recyclarr secrets already exist for
  radarr/sonarr).

- [ ] **UniFi — passkey on the UniFi account.** No reverse-proxy SSO can ever help
  here; UniFi is not a Caddy vhost. A passkey turns the most annoying login into
  Touch ID. **Unverified against this console** — Network 10.6.106 / UnifiOS 5.1.3;
  see [[unifi-software-versions]].

- [ ] **Bitwarden vault timeout** — if the vault re-prompts constantly, the
  timeout is too short. "On browser restart" plus biometric unlock removes most
  per-item friction. Client-side config, not infrastructure; belongs in dotfiles
  notes if anywhere.

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

- **SSO (Authelia) — REJECTED 2026-09-19.** Considered twice, for two different
  reasons, and dropped on the second. The motivation that mattered was not
  exposure but **login friction**: a separate credential for each arr app, qBittorrent,
  the UniFi stack, Grafana. Authelia does not solve that, for three reasons:

  1. **`forward_auth` does not remove an app's own login — it adds a gate in front
     of it.** All four arrs are on `AuthenticationMethod=Forms` +
     `AuthenticationRequired=Enabled` (read from `config.xml`, 2026-09-19), so
     Authelia would mean logging into Authelia *and then* Radarr. Two prompts
     where there is one today. Fixing it requires changing each app's own auth
     setting — and once that is done, Authelia's only remaining job is being a
     network gate, which is what Tailscale is for.
  2. **It cannot touch a large share of the pain.** UniFi is not a Caddy vhost,
     does not speak `forward_auth`, and owns its own account system. Vaultwarden
     must keep its own login by definition.
  3. The exposure argument is weak on its own: nothing is public except `vault`
     and the Invidious set, so it would mostly gate Brian out of his own LAN
     dashboards.

  *Reopen only if* the arr UIs (or similar) need to be reachable from an untrusted
  network or device **without** Tailscale, or if 2FA and an audit trail in front of
  everything become requirements. At that point build it as native
  `services.authelia.instances.<name>` — NOT the container in `memory/sso-plan.md`
  — and pair it with `AuthenticationMethod=External` on each arr, which is the
  setting that actually delegates auth to the proxy. See "Login friction" below
  for what was done instead.

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
