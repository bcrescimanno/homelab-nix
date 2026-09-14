# Switches & Dimmers

## Context

- **Current setup**: Leviton Decora Smart Wi-Fi installed throughout the house — D26HD dimmers and companion switches (likely D215S). Purchased with Matter support promised but not yet shipped at time of purchase.
- **Goal**: Enable Matter on existing devices for local control via Home Assistant and HomeKit. Evaluate whether to stay with Leviton long-term or switch to Thread-native alternatives for future purchases.
- **Scope**: In-wall switches and dimmers, house-wide.

## Selection Criteria

Standard criteria apply. Additional constraints:
- **Hard requirement (2026-09-13): must be a Thread router** (mains-powered Full Thread Device). The goal is everything on Thread, with every in-wall device adding depth to a mesh that today has only one router. Wi-Fi Matter switches (all Leviton Decora Smart) no longer qualify.
- **Hard requirement (2026-09-13): body no deeper than the Leviton D26HD (1.32 in).** Box fit was a real installation problem with the Leviton dimmers.
- Decora form factor strongly preferred (existing wallplates and aesthetic)
- Neutral wire is present throughout — not a limiting factor
- 3-way configurations exist (primary + companion devices)

## Research

### 2026-03-17

Leviton Matter firmware is generally available. Existing Wi-Fi devices remain Wi-Fi after Matter update — no Thread radio. For future purchases, Thread-native alternatives now exist.

#### Existing Devices: Leviton D26HD + Companion Switch

| Device | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|
| **D26HD** (dimmer) | Yes — OTA via My Leviton app | Wi-Fi 2.4 GHz | Full at runtime | Yes | Yes (Matter) | Matter firmware shipped July 2023; static setup code on device and in app |
| **D215S** (switch, likely model) | Yes — same OTA rollout | Wi-Fi 2.4 GHz | Full at runtime | Yes | Yes (Matter) | Released alongside D26HD in same Matter update batch |
| **DAWDC** (companion dimmer, wire-free) | No | Proprietary RF | N/A — tethered to primary | N/A | N/A | RF-paired to D26HD only; does not appear as a Matter device |

**Re-provisioning process**: No factory reset required. Apply OTA via My Leviton app, then commission into HA/HomeKit using the static Matter setup code (visible in app under Device Settings or printed on device). Existing My Leviton, Alexa, and Google Home connections remain intact — Matter is additive. Factory reset (14-second top-rocker hold) only needed to wipe all Matter commissioners and start fresh.

**Known limitations**:
- Wi-Fi only — no Thread radio, even after Matter update. Each switch is a 2.4 GHz client on your AP.
- Leviton's own manual documents a "reconfigure wireless" troubleshooting step for connectivity drops — Wi-Fi dropout is a known enough issue to merit an official FAQ entry.
- DAWDC companion uses proprietary RF, not Matter — 3-way setups have a RF coupling dependency that is outside the Matter fabric.
- Large installs may stress AP client limits; Leviton recommends checking AP specs for max device count.
- Matter over Wi-Fi does provide fully local runtime control — Leviton cloud is not required once commissioned.

#### Candidates for Future Purchases

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|
| **Inovelli White Series VTM31-SN** (dimmer) | ~$65 | Yes | Thread | Full | Yes | Yes (Matter) | Thread-native; requires Thread border router (ZBT-2 running on rivendell since 2026-03-17). Smaller vendor, newer product. Decora form factor. Each unit is also a Thread router — see 2026-09-13. |
| **Leviton D26HD** | ~$45 | Yes | Wi-Fi | Full at runtime | Yes | Yes (Matter) | Known quantity; widely available. Wi-Fi client load tradeoff for large installs. |
| **Eve Light Switch** | ~$50 | Yes | Thread | Full (no cloud ever) | Yes | Yes (Matter) | Thread-native, zero cloud. **No dimming** — switch only. |

#### What to Avoid

- **Any Wi-Fi smart switch requiring permanent cloud**: Kasa, Wemo (cloud-dependent), older Leviton pre-Matter firmware. Runtime cloud dependency is a hard no.
- **Lutron Caseta/RA3**: proprietary Clear Connect RF ecosystem, requires Caséta Pro hub. Excellent reliability and no-neutral support, but ecosystem lock-in and bridge dependency. Only relevant if neutral wire is absent (it isn't here).
- **GE/Enbrighten Zigbee switches**: require Zigbee coordinator (not currently configured). Acceptable fallback but adds coordinator dependency. Defer unless Zigbee coordinator is added.

### 2026-09-13

**First D26HD commissioned.** Paired to matter-server as node 8 on 2026-09-13, firmware 2.4.1. The March "static setup code, no factory reset required" process did not match reality:

- The iPhone hung on "Connecting…" and nothing reached matter-server until the switch was **factory reset**: hold the top of the rocker ~14s (amber at 7s, keep holding, release; flashes green). A unit left half-paired does not re-enter commissioning cleanly.
- Setup mode without a reset: hold the top of the rocker ~7s until amber, release; flashes green. A brief amber blink on entry means it is already commissioned to a controller — reset first.
- These steps are on page 15 of Leviton's full Getting Started Guide, not on the quick-start sheet. Same procedure for D215S, D215P, D23LP.
- **Pair from the main LAN's 2.4 GHz SSID, not the IoT VLAN.** The switch joins whatever network the phone is on, and matter-server cannot reach a Wi-Fi Matter device on the IoT VLAN (no IPv6 prefix there; matter-server binds `eth0`). This applies to every Wi-Fi Matter device, not just Leviton.
- matter-server does not do BLE. The iPhone does BLE and network provisioning, then hands the device off on-network.

**Leviton's current generation is the D36HD (dimmer) / D315S (switch)** — Matter from the factory, still **Wi-Fi only** ([Leviton store](https://store.leviton.com/products/decora-smart-dimmer-switch-wi-fi-works-with-matter-my-leviton-alexa-google-assistant-apple-home-siri-wired-or-wire-free-3-way-neutral-wire-required-d36hd-1rw-white), [review](https://www.dumbswitches.com/leviton-decora-smart-review/)). No Leviton Thread in-wall device found. If buying Leviton again, buy these rather than the 2nd-gen D26HD.

**Inovelli White Series matters more than it did in March.** Measured 2026-08-30: our Thread mesh has exactly **one router**, rivendell's border router, so every Thread device must reach the Pi directly. Battery devices never route; mains-powered Thread devices do. Every Inovelli White switch would be a Thread router, fixing the mesh-depth problem as a side effect of buying a switch. That makes it the vendor-neutral answer to Thread range (merging with Apple's Thread network was declined 2026-08-30).

Reliability is good but not settled:
- Positive reviews — "rock-solid" after a month installed ([Matter Alpha](https://www.matteralpha.com/review/inovelli-white-series-smart-dimmer-review)).
- Firmware is actively maintained: dimmer VTM31-SN production 1.1.5 with beta 1.1.6r1; on/off VTM30-SN 1.0.5 on 2026-05-27 ([changelog](https://help.inovelli.com/en/articles/10175651-white-series-dimmer-switch-firmware-changelog)).
- Open community reports of poor Thread connectivity even near a router, and of White Series **fan** switches going offline after a matter-server restart and sometimes never coming back ([bug thread](https://community.inovelli.com/t/white-series-dimmer-vtm31-sn-bug-enhancement-thread/17216)). matter-server restarts whenever rivendell reboots or it is redeployed, so that failure mode is directly relevant here.
- Trial one unit through several matter-server restarts before buying more.

**2.4 GHz coexistence:** our Thread network is on channel 19, which overlaps Wi-Fi channels 6 and 11. On 2026-09-13 locking the UniFi 2.4 GHz radio to ch6 knocked the Eve Weather off Thread within minutes. Every additional Wi-Fi switch adds 2.4 GHz traffic; Thread switches don't.

#### Eve Light Switch and Eve Dimmer Switch (US, Matter)

Eve makes two Matter-over-Thread in-wall devices. The March table covered only the Light Switch, as "no dimming". The **Eve Dimmer Switch** launched in February 2025 and fills that gap.

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Multi-way | Notes |
|---|---|---|---|---|---|---|---|---|
| **Eve Dimmer Switch** | $49.95 | Yes | Thread (FTD, router) | Full (no cloud, no account) | Yes | Yes (Matter; Works with HA certified) | **Unclear — see below** | Neutral required. LED max **150 W**, incandescent/halogen 600 W, MLV 300 VA, min 3 W. 120 × 75 × 45 mm (1.8 in deep). Touch face plus side dim buttons. **Out of stock** on Eve's US store 2026-09-13. |
| **Eve Light Switch (3rd gen)** | ~$50 | Yes | Thread (FTD, router) | Full (no cloud, no account) | Yes | Yes (Matter; Works with HA certified) | Single-pole or 3-way by replacing one switch | On/off only. Neutral required. 600 W incandescent, 1800 W / 15 A resistive. 120 × 75 × 45 mm. **Out of stock** on Eve's US store 2026-09-13. |

Sources: [Eve Dimmer Switch](https://www.evehome.com/en-us/eve-dimmer-switch), [Eve Light Switch](https://www.evehome.com/en-us/eve-light-switch), [How-To Geek dimmer review, 2025-06](https://www.howtogeek.com/eve-dimmer-switch-review/), [Tom's Guide dimmer review](https://www.tomsguide.com/home/eve-dimmer-switch-review), [Matter Alpha Light Switch review, 2025-02](https://www.matteralpha.com/review/eve-light-switch-review), [Eve joins Works with Home Assistant](https://www.home-assistant.io/blog/2025/04/29/eve-joins-works-with-home-assistant/).

**What fits this homelab:**
- **Both are Thread routers.** Eve's own spec says Full Thread Device / router node. So both solve the single-router mesh problem the same way an Inovelli would.
- **Eve is already in use here** (Eve Weather). Both are certified under Works with Home Assistant, and they have the cleanest local story in the category: no account, no cloud, no hub.
- **Commissioning** is the same Matter QR flow as the Eve Weather. It also adds an Apple Home fabric when paired from the iPhone.

**What counts against them:**
- **3-way is the deciding problem for this house.** Eve's US dimmer page says it "replaces a single-pole switch", and Amazon's listing says "for Single-Pole switches". How-To Geek did install one in a 3-way circuit using its traveler wire, but **the other switch must stay "on"**. That is not real two-location control: the second location becomes a switch you can't use. The Light Switch (3rd gen) officially supports 3-way "by replacing one switch", and the same limitation should be assumed until proven otherwise. Neither works with Leviton's DAWDC wire-free companions, so any existing 3-way location would lose its second switch. Inovelli White supports multi-way properly and is the better choice there.
- **LED load limit is low.** The dimmer's 150 W LED rating is half the Leviton D26HD's (300 W LED). Fine for a room's worth of LED cans; check the total before putting a large fixture group on one.
- **Size.** Both are 1.7–1.8 in deep with five non-removable pigtail leads. Matter Alpha found fitting it into standard boxes an "installation headache"; crowded or multi-gang boxes may not fit.
- **Not a Decora paddle.** The dimmer has a touch front with side dim buttons. It fits standard Decora plates, but it won't match the Leviton paddles already on the walls. How-To Geek found the touch surface "too easy" to trigger by accident and the side buttons stiff.
- **Settings live in the Eve app** (iOS only): bulb type, dimming range, status LED. That is setup-time app use rather than a cloud dependency, but it is config HA can't see or restore — the same trade-off as Meross presence tuning. Inovelli exposes most of its parameters over Matter instead.
- **Stock.** Both were out of stock on Eve's US store on 2026-09-13; check Amazon or B&H.
- **HA reliability:** no community reports specific to the Eve switches were found. The Eve reports that did turn up are old Eve Energy plug issues (dropping to unavailable, pairing failures) from its early Matter firmware. That doesn't tell us much either way.

**Verdict (as first written):** a good Thread option for **single-pole** locations, and a peer to Inovelli there — simpler and more local, but less configurable over Matter and with a non-matching look. **Superseded the same day by the depth requirement below — Eve is rejected.**

#### Requirements tightened: Thread router + shallow body (2026-09-13)

Two hard requirements now apply to every in-wall switch or dimmer (see Selection Criteria):

1. **Must be a Thread router.** The goal is everything on Thread, and every in-wall device must add depth to the mesh. That rules out **all Leviton Decora Smart models** — the D26HD/D215S and the current D36HD/D315S are Wi-Fi only.
2. **Must not be deeper than the Leviton D26HD (1.32 in).** Box fit was a real problem installing the Leviton dimmers, so anything deeper is a step backwards.

| Device | Body depth | Thread router | 3-way | LED load | Price / stock | Result |
|---|---|---|---|---|---|---|
| **Inovelli White (VTM31-SN)** | **1.2 in** | Yes, with neutral (see below) | Proper: Inovelli Aux switch (AUX01, dims from both ends) or an existing plain switch (no dimming from that end) | 300 W | $65, in stock | **Only device meeting both requirements** |
| Leviton D26HD (installed today) | 1.32 in | **No** — Wi-Fi | Leviton wire-free companion | 300 W | — | Baseline; fails router requirement |
| Aqara Dimmer Switch H2 US | 1.66 in | Only with neutral (MTD without) | Not stated | 240 W | $49.99 | Rejected: deeper than Leviton |
| Eve Dimmer Switch | 1.8 in, plus five fixed pigtails | Yes | Single-pole per Eve's US page | 150 W | $49.95, out of stock | Rejected: deepest; single-pole only |
| Eve Light Switch (3rd gen) | 1.8 in, plus five fixed pigtails | Yes | 3-way by replacing one switch | on/off only | ~$50, out of stock | Rejected: deepest; no dimming |

Depth figures come from different sources — [Inovelli](https://inovelli.com/products/thread-matter-white-series-smart-2-1-on-off-dimmer-switch), a distributor listing for the Leviton D26HD ([Gerrie](https://www.gerrie.com/Product/Leviton-D26HD-1BW)), [Aqara specs](https://www.aqara.com/us/product/dimmer-switch-h2-us-specs/), [Eve](https://www.evehome.com/en-us/eve-dimmer-switch) — and may be measured differently. 1.2 in vs 1.66–1.8 in is still not close.

**Aqara Dimmer Switch H2 US, for the record:** buttons for on/off and brightness, works with or without neutral, leading- and trailing-edge dimming, minimum load 9 W on non-Aqara Matter platforms. In Thread/Matter mode HA gets only a dimmable light entity and a kWh counter; live power, brightness limits, dimming-mode and decoupled mode need Zigbee mode ([SmartHomeScene review, 2026-08](https://smarthomescene.com/reviews/aqara-dimmer-switch-h2-with-zigbee-and-thread-review/) — reviewed the EU dial model; US model assumed similar). Rejected on depth before any of that mattered.

**Inovelli White — the remaining risks, since this makes it single-vendor:**
- **Router role is not officially documented.** Inovelli's manual says only "Thread enabled". The confirmation is a community member, not staff: "[Yes. Always on. Router capable.](https://community.inovelli.com/t/is-white-series-an-ftd-full-thread-device/17876)" (2024-10). Expected for an always-powered device, but **verify on the first unit**. Neutral is optional for single-pole installs; install with neutral (present throughout) so there's no question of it being always powered.
- **Mixed reliability reports.** Owners describe occasional drops needing an air-gap reset ([community thread](https://community.inovelli.com/t/state-of-inovelli-white-matter-over-thread-switches/19378), mostly Google Home multi-admin setups), plus the fan-switch restart problem noted above. Firmware is actively maintained.
- **No fallback that meets both requirements.** If Inovelli fails the trial, the choice becomes relaxing depth (Eve, Aqara) or relaxing Thread (stay on Leviton) — decide then, not now.
- **Fan switches:** hold off on the White Series fan switch until the "offline after matter-server restart" reports are resolved.

## Follow-ups

- [~] **2026-03-17** — Commission all existing D26HD and D215S units into Home Assistant via Matter. **2026-09-13:** first D26HD done (node 8). Still worth finishing — cheap, and gives HA control until each is replaced. For the rest: factory reset any unit that was ever partly paired, and pair from the main-LAN 2.4 GHz SSID.
- [ ] **2026-09-13** — Inventory every switch location while pairing: which are 3-way (need an Inovelli Aux), which companion model is installed (this file says "likely D215S"), and which boxes would best extend the Thread mesh.
- [x] **2026-03-17** — Evaluate Inovelli White Series once the border router is running. **2026-09-13:** evaluated — only candidate meeting the Thread-router and depth requirements. Trial below.
- [ ] **2026-09-13** — **Trial one Inovelli White dimmer (VTM31-SN)**, wired with neutral, in a single-pole box between rivendell and the Eve Weather. Pass criteria:
  - shows role `R` in `ot-ctl neighbor table` on rivendell (the official router confirmation this file is missing);
  - stays available across several matter-server restarts and a rivendell reboot, with no air-gap reset needed;
  - settings are reachable from HA over Matter.
- [ ] **After a passing trial** — Standardise on Inovelli White. Replace Levitons over time, prioritising (1) 3-way locations (dimmer + Aux), (2) boxes that extend the mesh toward the Eve Weather and future exterior-door devices.
- [ ] **If the trial fails** — Decide which requirement to relax: depth (Eve Dimmer 1.8 in / Aqara H2 US 1.66 in) or Thread (stay on Leviton). Recheck Inovelli firmware before giving up on it.
- [ ] **Watch** — Inovelli White Series fan switch: don't buy until the post-matter-server-restart offline reports are fixed.

## Decision

- **Hard requirements (2026-09-13)**: every in-wall switch/dimmer must be a Thread router and no deeper than the Leviton D26HD (1.32 in).
- **Future purchases**: **Inovelli White Series only** (dimmer VTM31-SN, on/off VTM30-SN, Aux AUX01 for 3-way), gated on a single-unit trial. Leviton, Eve and Aqara are rejected — Leviton for Wi-Fi, Eve and Aqara for depth.
- **Existing hardware**: Leviton D26HD and companions are **to be replaced over time**, not kept long-term. Until each is replaced, commission it into HA via Matter (first unit: 2026-09-13, node 8, firmware 2.4.1). Buy no more Leviton.
