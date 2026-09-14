# Presence / Occupancy Sensors

## Context

- **Current setup**: One Aqara FP2 on hand (gifted). No presence sensors deployed yet.
- **Goal**: True occupancy detection per room — must detect stationary people (desk work, sleeping, reading). Lights-off-while-you-sit-there is unacceptable.
- **HA setup**: Thread border router (ZBT-2 + OTBR) running, Matter Server running, **no Zigbee coordinator**.
- **Priority**: High accuracy over cost.

## Selection Criteria

Standard criteria apply, with presence-sensor-specific notes:

- **PIR is categorically excluded for occupancy use cases.** PIR detects motion, not presence. A person sitting still at a desk, reading, or sleeping is invisible to PIR. If you need lights to stay on while you sit motionless, PIR fails by design. Acceptable only for hallways/entryways where brief triggering is sufficient.
- **mmWave radar is required** for true presence detection. 60 GHz mmWave detects micro-vibrations including breathing — a completely motionless sleeping person registers as present. This is the only technology appropriate for desk/bedroom use.
- **Wi-Fi battery devices**: No. Standard hard rule applies.
- **Wi-Fi mains-powered devices**: Acceptable if the integration is fully local (ESPHome, HomeKit Controller).

## Technology Primer

### PIR (Passive Infrared) — motion detection only

Detects changes in IR radiation (heat crossing zones). Goes OFF within seconds of the last movement. Cannot detect a still person. Used in 90% of consumer "motion sensors." Classic failure mode: lights turn off while you sit at your desk.

Good for: hallways, triggering initial lights-on, entryways. Wrong for: desk, bedroom, living room, bathroom.

### mmWave Radar — true occupancy detection

Actively transmits radio waves and detects Doppler returns. Can resolve micro-movement at the sub-millimeter scale:

- **5.8 GHz** (Sonoff SNZB-06P): Cheaper, less sensitive to truly motionless targets (breathing). Adequate for most rooms, may false-off for sleeping/very still people.
- **24 GHz** (Apollo MSR-2, LD2410/LD2412 family): Highly configurable per-distance-gate sensitivity. LD2412 chip specifically optimized for static presence. Outperforms some 60 GHz sensors when tuned correctly.
- **60 GHz** (Aqara FP2, FP300, FP1E): Shortest wavelength, highest sensitivity. Detects breathing patterns. Industry standard for fall detection and sleep monitoring. Most reliable for stationary occupants.

mmWave is RF-based — unaffected by steam, humidity, temperature, or light. Important for bathrooms (where PIR false-positives from steam are a serious problem).

## Research

### 2026-03-17

Research covered: matteralpha.com, SmartHomeScene, HA community forums, r/homeassistant, r/homekit, manufacturer pages (Aqara, Apollo Automation, Sonoff, IKEA), HA GitHub issues tracker, 9to5mac HomeKit Weekly, CNX Software, Zigbee2MQTT device database. Sources from 2025–2026 prioritized.

---

#### Aqara FP2 — the gifted sensor

**Technology**: 60 GHz mmWave radar. No PIR component. Detects breathing-level micro-vibration in completely still people.

**What it uniquely offers:**
- Up to **5 simultaneous targets** tracked — each with their own X/Y position and occupancy state
- Up to **30 configurable zones** mapped to a room floorplan in the Aqara app
- **Fall detection** — detects the mmWave signature of a person falling and remaining on the floor
- **Sleep monitoring** — breathing rate detection and sleep stage transitions when mounted above a bed
- 8-meter range, 120°H × 60°V FOV
- USB-C 5V/1A wired (no battery option — this is a reliability positive)
- Built-in illuminance sensor
- **~$83 USD**

**Protocol: Wi-Fi only (2.4 GHz)**. Not Zigbee. Not Thread. Not Matter. This is the key limitation.

**HA integration path: HomeKit Controller** (`homekit_controller` integration — fully local push, no cloud required for operation).
- Configure zones in the Aqara iOS/Android app (requires Aqara cloud account for setup)
- Pair to HA via HomeKit Controller: each configured zone becomes a separate `binary_sensor` with `device_class: occupancy`
- Once paired, all automations run locally — no cloud needed
- Advanced data (X/Y coordinates, breathing rate, fall events) is **not** exposed via HomeKit — stays in the Aqara app only
- Known pairing issues: some users report infinite loading loops during pairing; may require a few attempts

**Cloud dependency**: Aqara cloud account required for initial zone configuration and any subsequent zone changes. Runtime operation is local via HomeKit. The cloud is not in the data path for automations — if Aqara's servers go down, your HA automations still work.

**Verdict**: Excellent sensor for the money. Best consumer-grade presence accuracy available. The Wi-Fi protocol and indirect HA integration path are real drawbacks, but the occupancy detection quality is best-in-class. Use it — just understand what you're getting and what you're not.

---

#### Candidates

| Device | Price | Matter | Protocol | Cloud | HomeKit | HA | Multi-target | Zones | Power | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| **Aqara FP2** | ~$83 | No | Wi-Fi | Setup only | Yes | HomeKit Controller (local) | Yes (5) | Yes (30) | USB-C wired | Best accuracy + zone capability. Indirect HA integration. On hand now. |
| **Aqara FP300** | ~$50 | Yes (certified) | Thread or Zigbee | No | Yes | Matter (local) or Z2M/ZHA | No (single) | Yes | Battery (2× CR2450, ~3yr) | **Best new purchase**. 60 GHz + PIR hybrid. Thread/Matter native = zero cloud, local HA. Battery means easy placement. Single-target only. |
| **Aqara FP1E** | ~$50 | No | Zigbee 3.0 | No | No | ZHA / Zigbee2MQTT (local) | No (single) | Yes | USB-A wired | FP2's little sibling. Same 60 GHz chip, single-target, shorter range (6m). Requires Zigbee coordinator (not currently present). |
| **Sonoff SNZB-06P** | ~$15–20 | No | Zigbee | No | No | ZHA / Zigbee2MQTT (local) | No | No | USB-C wired | Budget mmWave (5.8 GHz). Single binary occupancy. Adequate for most rooms; may false-off for sleeping/motionless. Requires Zigbee coordinator. |
| **Apollo MSR-2** | ~$38 | No | Wi-Fi (ESPHome) | No | No | ESPHome (local, native) | No | No | USB-C wired | LD2410B 24 GHz. Highly configurable per-gate sensitivity. 60°×60° cone (ideal for desk). Full local, 100+ HA entities. No cloud ever. |
| **Apollo MTR-1** | ~$40 | No | Wi-Fi (ESPHome) | No | No | ESPHome (local, native) | Yes (3) | Yes (3) | USB-C wired | LD2450 24 GHz. Multi-target + zone tracking. 120° FOV. Better for large rooms. Less sensitive to micro-motion than 60 GHz. |
| **Apollo R PRO-1** | ~$70 | No | Wi-Fi (ESPHome) | No | No | ESPHome (local, native) | Yes (3) | Yes (3) | USB-C or PoE | Dual radar: LD2450 (zones/multi-target) + LD2412 (static micro-motion). Also CO2, temp, humidity, pressure, illuminance. 148 HA entities. Best ESPHome option for demanding use. PoE = clean install. |
| **UniFi G4/G5 AI cameras** | ~$130–200 | No | UniFi proprietary | Local (UDM Pro) | No | UniFi Protect integration | N/A | N/A | PoE | Person detection via AI; fires HA events. ~3s delay, camera FOV limitations, privacy concerns. Supplement, not replacement. |

#### What to Avoid

- **Any PIR-only sensor for occupancy** (Philips Hue Motion, IKEA TRADFRI, IKEA VALLHORN, standard Sonoff motion, standard Xiaomi motion): Will false-off when you're sitting still. Acceptable only for triggered-entry use cases.
- **Govee / Ring / Wyze / Ecobee presence**: Cloud-required, no real local HA integration.
- **Tuya ZG-204ZH mmWave**: 24 GHz dual-sensor but known illuminance sensor bug that destroys battery life (3 months instead of 1+ year). Inconsistent ZHA support. Avoid.
- **Generic AliExpress "human presence sensors"** without confirmed model numbers: Lottery on quality; many use unsupported LD2410 clones with no OTA firmware path.
- **IKEA VALLHORN**: Community reports persistent false-offs in static scenarios. Limited configuration. Not worth it when FP300 exists at similar price.
- **Aqara FP2 via Aqara cloud integration**: Do not use the official Aqara HA cloud integration for FP2 — it depends on Aqara's servers. Use HomeKit Controller instead for local operation.

### 2026-09-13

**Aqara FP300 in Thread mode is thin.** Paired over Thread/Matter it exposes only basic occupancy, temperature, humidity and illuminance; sensitivity and the rest of the configuration are only reachable in **Zigbee** mode ([Derek Seaman](https://www.derekseaman.com/2025/11/aqara-fp300-the-ultimate-presence-sensor-home-assistant-edition.html), [SmartHomeScene teardown](https://smarthomescene.com/reviews/aqara-fp300-presence-multi-sensor-teardown-and-review/)). Detection quality is praised — very few ghost triggers. For HA, reviewers recommend Zigbee mode, which here means a second radio because the ZBT-2 is committed to Thread. The March "best new purchase" label assumed Thread mode was complete; it isn't.

**New: Meross MS605.** Battery mmWave + PIR + light sensor, Matter over Thread, ~$34–36. Presence within ~4 m, motion to ~6 m, three zones. Reviews call it very reliable with few ghost detections, and the only Matter-over-Thread presence sensor with native multi-zone ([Matter Alpha review](https://www.matteralpha.com/review/meross-ms605-review-multi-zone-presence-detection-via-matter), [Meross](https://shop.meross.com/products/thread-presence-sensor-ms605)). Catch: sensitivity and hold times are set in the Meross app over Bluetooth, not through Matter. That is setup-time app use, not a runtime cloud dependency, but it is config HA can't see or restore.

**Announced: Aqara FP400.** Multi-person tracking with posture (standing, sitting, lying), Thread or Zigbee, Matter ([HomeKit News, 2026-05](https://homekitnews.com/2026/05/02/aqara-teases-fp400-mmwave-presence-sensor-w-matter-support/)). Power source, price and how much it exposes over Matter not confirmed. Given the FP300's Thread-mode limits, assume Matter exposes little until an HA review shows otherwise.

**IKEA MYGGSPRAY** (Matter-over-Thread motion sensor): AppleInsider found it unreliable for occupancy — misses still people ([AppleInsider](https://appleinsider.com/articles/26/05/15/ikea-matter-over-thread-review-amazing-smart-home-tech-when-they-work)). Closets and hallways only; same category as the PIR sensors under What to Avoid.

| Device | Price | Matter | Protocol | Cloud | HomeKit | HA | Multi-target | Zones | Power | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| **Meross MS605** | ~$34–36 | Yes | Thread | No (BLE app for tuning) | Yes | Matter (local) | No | Yes (3) | Battery | mmWave + PIR. Reliable in reviews. Tuning not exposed via Matter. |
| **Aqara FP400** | TBD | Yes | Thread or Zigbee | TBD | Yes | Matter / Zigbee | Yes | Yes | TBD | Announced 2026. Posture detection. No HA review yet. |

**Range reminder:** battery Thread presence sensors never extend the mesh, which has one router (rivendell). The FP2 and Apollo sensors are Wi-Fi and don't depend on Thread.

## Use-Case Guide

| Scenario | Best option | Runner-up |
|---|---|---|
| **Sitting at a desk (stationary)** | Apollo R PRO-1 (LD2412 handles micro-motion, narrow tuning) | Aqara FP2 (zone for desk area, breathing-level detection) |
| **Bedroom / sleeping** | Aqara FP2 (breathing detection, fall detection, sleep monitoring) | Apollo R PRO-1 (LD2412) |
| **Living room (multi-person)** | Aqara FP2 (5 targets, 8m range, zone per zone) | Apollo MTR-1 (3-zone, 120° coverage) |
| **Bathroom (steam environment)** | Aqara FP1E or FP300 (60 GHz, wired or battery, steam-immune) | Sonoff SNZB-06P (budget, steam-immune) |
| **Works right now (no new hardware)** | Aqara FP2 via HomeKit Controller | Apollo MSR-2 (Wi-Fi/ESPHome) |
| **Native Matter/Thread (best long-term)** | Meross MS605 (multi-zone; 2026-09-13) | Aqara FP300 (little exposed in Thread mode) |

## Deployment Notes

### Getting the Aqara FP2 working in HA

1. Create an Aqara account (required for zone configuration)
2. Add the FP2 in the Aqara Home app; configure your zones (label each zone — they become entity names in HA)
3. In the Aqara app: enable HomeKit under device settings
4. In HA: Settings → Integrations → Add → HomeKit Controller
5. Enter the HomeKit pairing code (on the device label or in the Aqara app)
6. Each configured zone appears as `binary_sensor.<zone_name>_occupancy`
7. Place FP2 on the IoT VLAN (10.0.12.0/22) — it's Wi-Fi, treat it like any other IoT device

**Zone placement advice**: The FP2 does not require line-of-sight to the entire zone — radar penetrates some furniture. Optimal mount is on a wall or in a corner at 1.5–2m height, aimed across the room (not straight down from ceiling).

### FP300 Thread commissioning (when purchased)

In Thread/Matter mode, commission via HA: Settings → Devices & Services → Add Integration → Matter. Follow Thread QR code pairing. No Aqara account or cloud needed. All operational data is local via the Matter Server on rivendell.

### Zigbee path (FP1E / SNZB-06P)

Requires a Zigbee coordinator first. Add a **Sonoff Zigbee 3.0 USB Dongle Plus** (~$20) to rivendell. A `services.zigbee2mqtt` NixOS module exists in nixpkgs (check current state vs running as a container). Once the coordinator is up, FP1E and SNZB-06P pair normally via Zigbee2MQTT.

## Follow-ups

- [ ] **2026-03-17** — Set up Aqara FP2 via HomeKit Controller. Configure zones in Aqara app first. Place on IoT VLAN. Test occupancy entity accuracy for desk use. Status unknown as of 2026-09-13; nothing blocks it (`homekit_controller` is already loaded for the ecobee). Unverified whether HomeKit discovery works across `eth0.4` — if the FP2 isn't discovered, that is the first suspect.
- [ ] **2026-09-13** — Choose the Thread presence sensor for rooms without the FP2: Meross MS605 (multi-zone, cheaper, tuning via app) vs Aqara FP300 (strong detection, little exposed over Thread). If unsure, trial one of each at a desk and in a bedroom.
- [ ] **2026-03-17** — Decide whether to add a Zigbee coordinator to rivendell. It would need its own radio (the ZBT-2 stays on Thread). With one, FP300 in Zigbee mode gets full configuration, FP1E is available at ~$50 for high-accuracy rooms, SNZB-06P at ~$18 for bathrooms/utility rooms.
- [x] **2026-09-17** — Check if new Matter-over-Thread mmWave sensors have shipped. Checked 2026-09-13: Meross MS605 shipped; Aqara FP400 announced. Next look 2027-03, including an HA review of the FP400.

## Decision

*(Fill in when a purchase is made)*

- **Chosen device**:
- **Date purchased**:
- **Where purchased**:
- **Installation notes**:
- **HA integration**:
