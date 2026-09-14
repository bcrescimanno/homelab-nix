# Contact Sensors (Door & Window)

## Context

- **Current setup**: Two ecobee SmartSensors (front door, kitchen door), local in HA via `homekit_controller` since 2026-09-13. Kitchen Door is unavailable (device-side).
- **Goal**: Monitor doors and windows for open/close state; drive HVAC automations (see thermostats.md), security alerting via Alarmo or HA alarm_control_panel, and general home automation.
- **Scale**: Large deployment likely — 10–20+ sensors across all doors and windows.
- **HA integration target**: Alarmo (HACS custom component) auto-discovers `binary_sensor` entities with `device_class: door` or `device_class: window`. Any protocol that surfaces a clean binary sensor in HA works.

## Selection Criteria

Standard criteria apply. Additional constraints specific to this category:

- **Battery is universal here** — contact sensors are inherently battery-powered; Wi-Fi is therefore categorically excluded (hard rule).
- **Large deployment cost matters** — per-unit price at 10–20+ units is a primary factor. A $10/unit Zigbee sensor saves $200–$400 vs a $30/unit Matter sensor at the same scale.
- **Size/aesthetics matter** — sensors go on visible doors and windows; smaller is better.
- **Thread coordinator status**: ZBT-2 border router running on rivendell (native OTBR since 2026-08-01). Thread/Matter sensors work now, but the mesh has **one router** (rivendell) — check range before a bulk deployment.
- **Zigbee coordinator status**: No coordinator currently configured. Zigbee requires a **separate** USB stick (e.g., Sonoff Zigbee 3.0 USB Dongle Plus, ~$20) before any Zigbee sensor will work — the ZBT-2 is on Thread and cannot run both.

## Research

### 2026-03-17

Matter contact sensors are genuinely shipping and certified in early 2026 — no longer vaporware. Two clear leaders: Eve Door & Window (Matter) and Aqara P2. Both are Matter-over-Thread, fully local, and confirmed working with Home Assistant via the Matter integration (Eve joined the Works with Home Assistant program in April 2025). For large deployments, Zigbee remains significantly cheaper per unit. Z-Wave viable but adds cost and has no advantage over Zigbee for this use case. Samsung SmartThings sensors are legacy/avoid. Centralite is near-dead. Tuya Wi-Fi is excluded by the battery+Wi-Fi hard rule.

Sources checked: Home Assistant community forums, r/homeassistant, matterdevices.io, matteralpha.com, 9to5mac, The Hook Up, zigbeeguru.com, home-assistant-guide.com, cnx-software.com.

#### Candidates

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|
| **Eve Door & Window (Matter)** | ~$40 ea / ~$100 3-pack | Yes (certified, shipping) | Thread | Full (no cloud ever) | Yes | Yes (Matter) | Best-in-class Matter sensor. Zero cloud, zero account. Works with Home Assistant Connect ZBT-2 OTBR. Eve joined Works with HA Apr 2025. Small, clean design. Expensive at scale. |
| **Aqara Door & Window Sensor P2** | ~$30 ea | Yes (certified, shipping) | Thread | Full (local automation) | Yes | Yes (Matter) | Matter-over-Thread, no Aqara hub required. Uses CR123A battery (~2 yr life). Notably larger/bulkier than original Aqara. Requires Thread border router. Some HA community reports of occasional unavailability; check ZBT-2 compatibility before buying at scale. |
| **Aqara Door & Window Sensor (MCCGQ11LM / T1)** | ~$15–18 ea / ~$15 in bundles | No | Zigbee | Full | Yes (via hub) | Yes (ZHA / Z2M) | The community favorite for large Zigbee deployments. Tiny form factor, peel-and-stick, CR1632 battery (~2 yr). Requires Aqara hub for HomeKit; works hub-free with Zigbee2MQTT or ZHA. No Matter, but fully local with Z2M. "Best door sensor" per The Hook Up. ~$15 at scale. |
| **SONOFF SNZB-04P** | ~$10–11 ea | No | Zigbee 3.0 | Full | No | Yes (ZHA / Z2M) | Excellent value at $10–11 per unit. CR2477 battery rated ~5 years (best in class). Tamper detection. Good magnet, strong Z2M support. Larger than Aqara original. No HomeKit. Top pick for bulk Zigbee deployments where HomeKit not needed. |
| **Third Reality Zigbee Contact Sensor** | ~$12–15 ea (2-pack ~$20) | No | Zigbee | Full | No | Yes (ZHA / Z2M, native HA integration) | Works with HA locally, officially in Works with HA program. Quick response, no disconnections reported. Uses 2×AAA batteries (~2 yr). Noticeably larger than Aqara/Sonoff due to AAA form factor. Good for: ease of battery procurement. |
| **Aeotec Recessed Door Sensor 7** | ~$35–40 ea | No | Z-Wave 700 | Full | No (via Z-Wave hub) | Yes (Z-Wave JS) | Unique form factor — recessed into door frame, completely invisible. S2 security. Requires Z-Wave controller. High cost; only justified if covert installation is required. |
| **Ecolink Z-Wave Plus Door/Window Sensor** | ~$25–30 ea | No | Z-Wave Plus | Full | No | Yes (Z-Wave JS) | Reliable, S2 security, screw terminals for external wired sensor. Requires Z-Wave controller. No HomeKit. More expensive than Zigbee with no advantage for most use cases. |
| **UniFi Protect G4 Sensor (multi-sensor)** | ~$80 ea | No | UniFi proprietary | Full (UDM Pro on-prem) | No | Yes (UniFi Protect integration, official) | Multi-sensor: contact + motion + temperature + humidity + light + leak. HA integration is official and local. Way over-spec and over-priced for a contact-only use case. Only worth it if you want the multi-sensor bundle (e.g., garage + flood detection). |

#### What to Avoid

- **Samsung SmartThings Multipurpose Sensor**: Legacy Zigbee device that requires SmartThings Hub (cloud-dependent platform). Samsung has phased out first-party sensor hardware. HA integration routes through SmartThings cloud. Avoid.
- **Centralite contact sensors**: Near-dead product line. Last active development was 2019–2021 under Ezlo ownership. Scarce availability, no active firmware updates. Avoid.
- **Any Wi-Fi battery contact sensor** (Ring Alarm sensors, Wyze sensors, SimpliSafe sensors, Tuya Wi-Fi sensors): Hard no — battery-powered + Wi-Fi violates the battery rule. These all drain batteries faster, congest the Wi-Fi network, and are all cloud-dependent. Ring/SimpliSafe require paid subscriptions for full function. Wyze has no local control. Avoid all.
- **Generic Tuya Wi-Fi sensors**: Even if labeled "smart home" or "Alexa compatible" — if they connect via Wi-Fi, exclude. Tuya Zigbee sensors are fine (they work with Z2M locally), but verify the protocol before purchasing anything branded Tuya/Smart Life.
- **Aqara MCCGQ11LM via Aqara Hub for HA**: The original Aqara sensor works great with Z2M/ZHA without a hub. The official Aqara Amazon listing says "Requires Aqara Hub (not 3rd-Party)" — this is only true for native Apple HomeKit via their hub. For HA via Zigbee2MQTT, no Aqara hub is needed.
- **Philips Hue Motion Sensor (contact add-on)**: Hue contact sensor exists but requires Hue Bridge, adds $60 to the ecosystem cost, and only makes sense if already on Hue. Over-priced for pure contact use.

### 2026-09-13

**Current setup changed.** The ecobee SmartSensors are now in HA locally through `homekit_controller` (2026-09-13), not the ecobee cloud: `binary_sensor.front_door_contact` and `binary_sensor.kitchen_door_contact`. The Kitchen Door sensor was unavailable at pairing — device-side (battery or range), check it in the ecobee app. The kitchen door sensor drives the HVAC pause in `modules/ha-hvac-openings.nix` (#699); the front door sensor is paired but not watched. **Every door or window sensor added later must also be added to `openings` in that module**, or it won't pause the HVAC — see `thermostats.md` → Adding sensors.

**The border router is live** (ZBT-2, native OTBR since 2026-08-01), so the Matter/Thread candidates can be bought now. But the Thread mesh has **one router — rivendell**. Contact sensors are battery devices and never route, so each must reach the Pi on its own; windows at the far end of the house may be out of range until a mains-powered Thread device is added nearby (see `smart-plugs.md` and `switches-dimmers.md`). Pair one sensor at the farthest door first and check its link in `ot-ctl child table` on rivendell before a bulk order.

**New candidate: IKEA MYGGBETT.** Matter-over-Thread door/window sensor, single AAA, adhesive mount. It worked reliably in AppleInsider's 2026-05 test of IKEA's Thread line, though that review also reports commissioning failures across the line that vary a lot by home ([AppleInsider](https://appleinsider.com/articles/26/05/15/ikea-matter-over-thread-review-amazing-smart-home-tech-when-they-work), [HA setup walkthrough](https://chrissmart.de/en/ikea-myggbed-home-assistant-furnishings/)). Price not verified in this pass. If it is near Zigbee sensor prices, it removes most of the cost argument for Zigbee below, because it needs no new coordinator.

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|
| **IKEA MYGGBETT** | check IKEA US | Yes | Thread | Full | Yes (Matter) | Yes (Matter) | 1×AAA. Reliable once paired in reviews; IKEA's Thread line has inconsistent commissioning reports. Test one first. |

**Zigbee cost correction:** the "~$20 coordinator" in the cost table is a **second radio**. The ZBT-2 is dedicated to Thread and cannot run Zigbee alongside it ([Nabu Casa](https://support.nabucasa.com/hc/en-us/articles/31347057208989-Switching-from-Zigbee-to-Thread-support-on-Home-Assistant-Connect-ZBT-2)).

Eve Door & Window and Aqara P2 were not re-checked in this pass.

## Protocol Decision Guide

| Situation | Recommendation |
|---|---|
| Thread border router (ZBT-2) is running, want HomeKit too | **Eve Door & Window (Matter)** or **Aqara P2** |
| Thread border router running, HomeKit not needed, want lowest Matter cost | **Aqara P2** (~$30) |
| Have or will add Zigbee coordinator, deploying 10+ sensors, HomeKit not needed | **SONOFF SNZB-04P** (~$10–11/unit = saves $200–400 vs Matter at 20 units) |
| Have Zigbee coordinator, want smallest possible sensor + HomeKit via Aqara hub | **Aqara MCCGQ11LM** (~$15–18/unit) |
| Need invisible/recessed sensor for security aesthetics | **Aeotec Recessed Door Sensor 7** (Z-Wave, needs controller) |
| Want multi-sensor (contact + motion + temp + humidity) and already using UniFi Protect | **UniFi G4 Sensor** (overkill for contact-only) |

## Coordinator Requirements

Before any non-Matter sensor works in HA:

- **Zigbee**: Need a **separate** Zigbee coordinator USB stick — the ZBT-2 is committed to Thread and cannot run Zigbee simultaneously. Recommended: **Sonoff Zigbee 3.0 USB Dongle Plus (SONOFF-ZIGBEE-3.0-USB-ZDONGLE-P)** — ~$20, well-supported by Zigbee2MQTT and ZHA, or a second ZBT-2. HA is a native service now (no `--privileged` container), so device access must be declared in Nix.
- **Z-Wave**: Need a Z-Wave controller USB stick. Recommended if going Z-Wave: **Aeotec Z-Stick 7** or **Zooz ZST39 LR** — ~$40–50.
- **Thread/Matter**: Done — ZBT-2 + native OTBR on rivendell (`modules/homeassistant.nix`). Ready now.

## Security System Integration (Alarmo)

Alarmo (HACS) auto-discovers all `binary_sensor` entities with security-related device classes. Any contact sensor that registers as `device_class: door` or `device_class: window` in HA will appear automatically in Alarmo's sensor list.

- All Zigbee sensors via Z2M/ZHA: expose proper device class automatically
- Matter sensors via HA Matter integration: expose proper device class automatically
- No special wiring or config needed — just add the sensor to HA and Alarmo picks it up

Alarmo supports 4 arm modes (away, home, night, custom), per-sensor enable/disable per mode, entry/exit delays, and ntfy-compatible notifications. Works entirely locally.

## Cost Analysis (20-unit deployment)

| Protocol / Device | Per Unit | 20 Units | Coordinator Cost | Total |
|---|---|---|---|---|
| SONOFF SNZB-04P (Zigbee) | ~$11 | ~$220 | ~$20 (once) | **~$240** |
| Aqara MCCGQ11LM (Zigbee) | ~$16 | ~$320 | ~$20 (once) | **~$340** |
| Third Reality (Zigbee) | ~$13 | ~$260 | ~$20 (once) | **~$280** |
| Aqara P2 (Matter/Thread) | ~$30 | ~$600 | $0 (ZBT-2 covers it) | **~$600** |
| Eve Door & Window (Matter) | ~$40 | ~$800 | $0 (ZBT-2 covers it) | **~$800** |

Zigbee is ~$360–$560 cheaper than Matter for 20 units. The right choice depends on whether Thread/Matter ecosystem convergence is worth the premium. For a HomeKit + HA household, Matter makes long-term sense but costs 2–3× more today.

## Follow-ups

- [ ] **2026-03-17** — Test Aqara P2 pairing with HA Matter integration; confirm no "unavailable" reconnection issues. The border router has been running since March (native since 2026-08-01) but the test was never done. Test an IKEA MYGGBETT alongside it.
- [ ] **2026-09-13** — Before any bulk buy: pair one sensor at the door or window farthest from rivendell and check its link in `ot-ctl child table`. If it is marginal, add a mains-powered Thread router first (see `smart-plugs.md`).
- [ ] **2026-09-13** — Kitchen Door ecobee sensor has been unavailable since pairing; check its battery and range in the ecobee app.
- [ ] **2026-03-17** — Before deploying Zigbee sensors at scale: add a **dedicated** Zigbee coordinator to rivendell (the ZBT-2 stays on Thread). Decide ZHA vs Zigbee2MQTT (Z2M recommended — better device support, more attributes exposed).
- [ ] **2026-03-17** — Decide protocol split: Matter for front-facing doors (visible, might want HomeKit native), Zigbee for windows and interior doors (bulk, lower visibility priority)? Revisit once MYGGBETT price and range are known — a cheap Thread sensor may make all-Thread the simpler answer.
- [ ] **2026-03-17** — Alarmo setup: after first sensors are added, install Alarmo via HACS and configure zones (perimeter = doors/windows; interior = motion sensors if added later).

## Decision

*(Fill in when a purchase is made)*

- **Chosen device**:
- **Date purchased**:
- **Where purchased**:
- **Installation notes**:
- **HA integration**:
