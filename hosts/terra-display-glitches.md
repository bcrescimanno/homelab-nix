# terra display glitches — catalog

Running log of every display fault seen on terra (RTX 5070 Ti, open NVIDIA
driver, LG TV "SSCR2" on HDMI-A-1). The point is to find which fix matches
which trigger before automating more of it: the same-looking symptom has
needed different fixes on different days. Add an entry for every new
occurrence, even a repeat — the repeats are the data.

Recovery tooling lives in `hosts/terra.nix` ("Display recovery"):
`terra-display-resume-check.service` runs after every resume, and
`sudo terra-display-recover now` re-probes HDMI and restarts the session
(Gaming Mode) or cycles DPMS (Desktop Mode).

## Fix ladder, cheapest first

| # | Fix | Cost | How |
|---|---|---|---|
| 1 | DPMS cycle (Desktop Mode only) | none | `kscreen-doctor --dpms off; sleep 5; kscreen-doctor --dpms on` as brian with the session env (see `terra-display-recover`) |
| 2 | Re-probe HDMI | none | `echo detect \| sudo tee /sys/class/drm/card1-HDMI-A-1/status` |
| 3 | Fresh gamescope | quits Steam and anything in it | `sudo terra-display-recover now` |
| 4 | Suspend + wake | pauses everything, keeps the session | `sudo systemd-run --on-active=60s systemctl suspend`, close SSH, then `wol -i 10.0.1.255 1c:1b:0d:9a:b4:a8` |
| 5 | Cold power-off ≥1 min | full reboot | `sudo systemd-run --on-active=5s systemctl poweroff`; WoL works from off (verified 2026-10-12) |

A warm reboot is **not** on the ladder: it did not clear type D on 2026-10-10.

## Glitch types

- **A — Black, connector lost on resume (Gaming Mode).** Kernel reads HDMI-A-1
  `disconnected` after resume and never re-probes; gamescope logs
  `cannot find any connected connector!`. Automated (fix 2 + 3) since #867.
- **B — Black, Steam's idle sleep refused.** No resume at all. Steam logs
  `org.freedesktop.login1.BlockedByInhibitorLock`, has already drawn its black
  layer, and never removes it. Fix 4. A legitimately held inhibitor (SSH with a
  running command, upgrade, backup) causes this in Gaming Mode.
- **C — Black in Desktop Mode, KWin still rendering.** Spectacle screenshot is
  fine, `kscreen-doctor -o` says enabled. Fix 1.
- **D — Corruption: smeared colours, regions repeated elsewhere, flicker**,
  Gaming Mode only, while `gamescopectl screenshot` of the same moment is
  clean — the frame is right, scan-out of it is wrong. Fix has varied: 3 once,
  forced composition once, 5 twice. See the entries.
- **E — Flicker along the bottom edge** (historical). gamescope DRM backend on
  the 595.x driver, NVIDIA bug 5240452. Gone on 615.x (FF7 Remake 4K60 HDR
  clean, 2026-10-09).

## Log

Times are terra-local (PDT).

### 2026-10-10 ~12:00 and 16:03 — D
- **Mode / trigger:** Gaming Mode, TV turned on after being off a long time.
  Reproduced with autosleep off, so not sleep-related.
- **Seen:** on the previous wake the TV missed DDC (6× "Unable to read EDID",
  gamescope briefly at 1024x768). Desktop Mode was fine; back to Gaming Mode
  was broken again.
- **Did not fix:** warm reboot (12:06, 12:08).
- **Fixed:** cold power cycle, 12:10–12:12.

### 2026-10-10 21:00 — D
- **Mode / trigger:** Gaming Mode.
- **Seen:** screenshot clean during corruption. `gamescopectl composite_force 0`
  brought it back instantly, `1` cleared it — A/B repeatable live.
- **Fixed:** forced composition, made permanent in
  `/etc/gamescope/scripts/90-terra-force-composition.lua` (#855).
- **Later note:** incidents on 2026-10-12 recurred with forced composition
  on, so scan-out of client buffers was at most one of the causes.

### 2026-10-10 21:26 — B
- **Mode / trigger:** Gaming Mode, Steam's 30-min idle sleep.
- **Seen:** an idle multiplexed SSH master counted as a session and the guard
  refused the sleep.
- **Fixed:** suspend + wake at the time; guard changed to ignore idle masters
  (#856).

### 2026-10-12 morning — C
- **Mode / trigger:** Desktop Mode, ES-DE left running overnight (its own
  "Playing a game" inhibition kept terra awake, as intended).
- **Seen:** KWin output enabled at 4K@120, ES-DE drawing normally in a
  screenshot, TV black; no DPMS or suspend logged overnight.
- **Fixed:** fix 1.

### 2026-10-12 12:59 — A, then D
- **Mode / trigger:** Gaming Mode, resume after ~1h40m asleep. In the 11 other
  resumes in that boot gamescope saw the TV within 0–1s, TV on or in standby.
- **Seen:** HDMI-A-1 `disconnected`; fix 2 brought the picture back but with
  type-D corruption (screenshot clean).
- **Did not fix the D:** `composite_force 1`, TV input switch, Steam HDR off.
- **Fixed:** fix 3. Automated as `terra-display-resume-check` (#867).

### 2026-10-12 13:41 — B
- **Mode / trigger:** Gaming Mode, ES-DE scraping, Steam's idle sleep.
- **Seen:** `BlockedByInhibitorLock`; no other inhibitor active. Most likely
  Claude's own diagnostic SSH session held a running channel (ssh guard).
- **Fixed:** fix 4; the ES-DE scrape survived it.

### 2026-10-12 17:41 — D
- **Mode / trigger:** switched Desktop Mode → Gaming Mode (Desktop had been
  fine; KWin drives 4K@119.88 SDR, gamescope 4K@60 HDR).
- **Seen:** forced-composition script loaded; `drm_info` showed one plane in
  use — gamescope's own composite, XBGR2101010, NVIDIA block-linear —
  Colorspace BT2020_RGB, link-status Good, no stale LUT/CTM. No screenshot taken.
- **Did not fix:** fix 3, fix 4, TV wall-power cycle, Steam refresh 120 Hz.
- **Fixed:** fix 5 (off 17:50:04, WoL 17:51:06, Gaming Mode 17:51:37).

## Working hypotheses

Not conclusions — update as entries accumulate.

- Type D has at least two causes: one cleared by forced composition or a
  fresh gamescope, and one that survives everything short of a cold
  power-off. The second looks like state held by the GPU itself (its firmware
  keeps running through suspend and warm reboot), set off by Desktop→Gaming
  transitions or a long TV-off.
- Worth capturing on the next type D, before fixing it:
  `gamescopectl screenshot` (clean or not), `sudo nix shell nixpkgs#drm_info
  -c drm_info`, the driver version, and the last mode switch / TV-off before it.
