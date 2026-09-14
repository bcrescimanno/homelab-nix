# Contact Sensors (Door & Window)

## Context

- **Current setup**: Two ecobee SmartSensors (front door, kitchen door), local in HA via `homekit_controller` since 2026-09-13. Kitchen Door is unavailable (device-side).
- **On order (2026-09-13)**: Eve Door & Window 3-pack, plus a mains-powered Thread smart plug to give the mesh a router (see `smart-plugs.md`). See Decision below for the install plan.
- **Goal**: Monitor doors and windows for open/close state; drive HVAC automations (see thermostats.md), security alerting via Alarmo or HA alarm_control_panel, and general home automation.
- **Scale**: Large deployment likely — 10–20+ sensors across all doors and windows.
- **Protocol**: **Thread only (decided 2026-09-13).** No Zigbee or Z-Wave coordinator will be added. Every candidate in this file is Matter-over-Thread.
- **HA integration target**: Alarmo (HACS custom component) auto-discovers `binary_sensor` entities with `device_class: door` or `device_class: window`. Matter contact sensors surface exactly that.

## Selection Criteria

Standard criteria apply. Additional constraints specific to this category:

- **Matter-over-Thread only.** Zigbee and Z-Wave each need a second USB radio on rivendell (the ZBT-2 is dedicated to Thread), plus a second integration to run. HomeKit-only Thread sensors without Matter (e.g. Onvis CS2) are also out, because they tie the sensor to Apple.
- **Battery is universal here** — contact sensors are inherently battery-powered; Wi-Fi is therefore categorically excluded (hard rule).
- **Large deployment cost matters** — per-unit price at 10–20+ units is a primary factor.
- **Size/aesthetics matter** — sensors go on visible doors and windows; smaller is better.
- **Thread coordinator status**: ZBT-2 border router running on rivendell (native OTBR since 2026-08-01). The mesh has **one router** (rivendell). Battery sensors are sleepy end devices that never route, so each one must reach rivendell directly. Check range before a bulk deployment.

## Research

### 2026-03-17

Matter contact sensors are genuinely shipping and certified in early 2026 — no longer vaporware. Two clear leaders: Eve Door & Window (Matter) and Aqara P2. Both are Matter-over-Thread, fully local, and confirmed working with Home Assistant via the Matter integration (Eve joined the Works with Home Assistant program in April 2025).

*The Zigbee and Z-Wave candidates from this pass (SONOFF SNZB-04P, Aqara MCCGQ11LM/T1, Third Reality, Aeotec Recessed 7, Ecolink), and the UniFi Protect G4 Sensor, were removed 2026-09-13 when the Thread-only decision was made. See git history if ever needed.*

Sources checked: Home Assistant community forums, r/homeassistant, matterdevices.io, matteralpha.com, 9to5mac, The Hook Up, home-assistant-guide.com, cnx-software.com.

#### Candidates

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|
| **Eve Door & Window (Matter)** | ~$40 ea / ~$100 3-pack | Yes (certified, shipping) | Thread | Full (no cloud ever) | Yes | Yes (Matter) | Best-in-class Matter sensor. Zero cloud, zero account. Works with Home Assistant Connect ZBT-2 OTBR. Eve joined Works with HA Apr 2025. Small, clean design. Expensive at scale. |
| **Aqara Door & Window Sensor P2** | ~$30 ea | Yes (certified, shipping) | Thread | Full (local automation) | Yes | Yes (Matter) | Matter-over-Thread, no Aqara hub required. Uses CR123A battery (~2 yr life). Notably larger/bulkier than original Aqara. Requires Thread border router. Some HA community reports of occasional unavailability; check ZBT-2 compatibility before buying at scale. |

#### What to Avoid

- **Any Wi-Fi battery contact sensor** (Ring Alarm sensors, Wyze sensors, SimpliSafe sensors, Tuya Wi-Fi sensors): Hard no — battery-powered + Wi-Fi violates the battery rule. These all drain batteries faster, congest the Wi-Fi network, and are all cloud-dependent. Ring/SimpliSafe require paid subscriptions for full function. Wyze has no local control. Avoid all.
- **Aqara sensors without "P2" / Matter**: Aqara's original and T1 sensors are Zigbee and need a hub or coordinator. Buy only the Thread P2.
- **Samsung SmartThings Multipurpose Sensor**: Legacy, hub- and cloud-dependent. Avoid.

### 2026-09-13

**Current setup changed.** The ecobee SmartSensors are now in HA locally through `homekit_controller` (2026-09-13), not the ecobee cloud: `binary_sensor.front_door_contact` and `binary_sensor.kitchen_door_contact`. The Kitchen Door sensor was unavailable at pairing — device-side (battery or range), check it in the ecobee app. The kitchen door sensor drives the HVAC pause in `modules/ha-hvac-openings.nix` (#699); the front door sensor is deliberately excluded, because the front door isn't kept open when the house is opened up for cooling. **Every window or door sensor added later that should pause the HVAC must also be added to `openings` in that module**, or it won't — see `thermostats.md` → Adding sensors.

**The border router is live** (ZBT-2, native OTBR since 2026-08-01), so the Matter/Thread candidates can be bought now. But the Thread mesh has **one router — rivendell**. Contact sensors are battery devices and never route, so each must reach the Pi on its own; windows at the far end of the house may be out of range until a mains-powered Thread device is added nearby (see `smart-plugs.md` and `switches-dimmers.md`). Pair one sensor at the farthest door first and check its link in `ot-ctl child table` on rivendell before a bulk order.

**New candidate: IKEA MYGGBETT.** Matter-over-Thread door/window sensor, single AAA, adhesive mount. It worked reliably in AppleInsider's 2026-05 test of IKEA's Thread line, though that review also reports commissioning failures across the line that vary a lot by home ([AppleInsider](https://appleinsider.com/articles/26/05/15/ikea-matter-over-thread-review-amazing-smart-home-tech-when-they-work), [HA setup walkthrough](https://chrissmart.de/en/ikea-myggbed-home-assistant-furnishings/)). Priced in the next section.

### 2026-09-13 — Pricing and HA reliability check (Thread only)

Prices checked today. Retailer pages at B&H, Micro Center, Home Depot and Amazon block automated fetches, so Eve's US price comes from Matter Alpha's Amazon tracker and 9to5toys deal posts.

| Device | US price (2026-09-13) | Battery | Size | HA reliability signal |
|---|---|---|---|---|
| **Aqara Door & Window Sensor P2** | **$29.99** (Aqara US store) | CR123A, included | 77 × 22 × 22 mm + 36 mm magnet | Unavailability thread (2023–25) was mostly fixed by Matter Server 4.8.3. One Aqara forum report of a battery drained in days when paired to Apple Home and HA at once. The reporter of the open MYGGBETT bug says their P2s are stable on the same HA. |
| **Eve Door & Window (Matter)** | **$43.95** list (Amazon US via Matter Alpha). Sales in 2026: $34 (Feb, Mar), **$32** (Prime Day, Jun) | ½ AA ER14250, included | **52 × 24 × 23 mm** (smallest) + 18 mm magnet | Old HA issues (2023–24: stops reporting hours after commissioning, add fails) predate Eve joining Works with HA in Apr 2025. No current open issue found. |
| **IKEA MYGGBETT** | **$11.99** (IKEA US; not the $7.99–8 quoted in reviews) | 1× AAA, **not included** (IKEA recommends LADDA rechargeable) | ~1 × 3 in; reviewers call it bulky | **Open bug**: disconnects from HA after a few hours, recovers only with a battery pull ([core #162230](https://github.com/home-assistant/core/issues/162230), opened 2026-02, no fix). **OTA updates always fail** in the Matter server ([core #174389](https://github.com/home-assistant/core/issues/174389)). HA forum (Mar–Apr 2026): drops are location-sensitive, and adding Thread routers helped only partly. Matter Alpha (2026-05): "almost gets it right", intermittent. |

**Excluded on this pass:** Onvis CS2 (~$35) is Thread but HomeKit-only, with no Matter. A search guide listed IKEA PARASOLL as Thread; it is Zigbee.

Sources: [Aqara US P2](https://us.aqara.com/products/door-and-window-sensor-p2), [Aqara P2 HA unavailability thread](https://community.home-assistant.io/t/aqara-door-and-window-sensor-p2-with-thread-and-matter-becomes-unavailable-and-comes-back-als-the-time/590222/15), [Aqara P2 battery drain report](https://forum.aqara.com/t/p2-sensor-dies-quickly-no-battery-within-days-matter-apple-home-assistant/65130), [Eve Door & Window](https://www.evehome.com/en/eve-door-window), [Matter Alpha Eve price tracker](https://www.matteralpha.com/evehome/eve-door-window-p9), [9to5toys Eve Prime Day 2026](https://9to5toys.com/2026/06/23/eve-2026-prime-day-deals-matter-plugs-switch-water-sensor/), [9to5toys Eve spring 2026](https://9to5toys.com/2026/03/25/eve-big-spring-matter-smart-home-deals/), [Eve HA issue #89376](https://github.com/home-assistant/core/issues/89376), [IKEA US MYGGBETT](https://www.ikea.com/us/en/p/myggbett-door-window-sensor-smart-60617641/), [Matter Alpha MYGGBETT review](https://www.matteralpha.com/review/ikea-myggbett-review-affordable-matter-contact-sensor), [HA forum MYGGBETT connection loss](https://community.home-assistant.io/t/ikea-myggbett-matter-device-loses-connection/996839), [Onvis CS2](https://www.onvistech.com/product_details/CS2.html).

## Recommendation (2026-09-13)

| Use | Pick | Why |
|---|---|---|
| **Default for the bulk of doors and windows** | **Aqara P2** ($29.99) | The cheapest Thread sensor without an open HA bug. Its known unavailability problem was fixed on the Matter server side. Downside: long body (77 mm) and a CR123A battery. |
| **Visible spots where size matters** | **Eve Door & Window** (buy on sale, ~$32–34) | Smallest by far, no cloud or account, and in the Works with HA program. At list price ($43.95) it costs about 50% more than the P2. |
| **Not yet** | **IKEA MYGGBETT** ($11.99 + AAA) | Would save about $360 over the P2 at 20 units. But it has an open "disconnects after hours" HA bug and firmware updates that can't install. On a one-router mesh that failure mode is exactly the risk. Re-check when #162230 and #174389 close. |

Pilot before any bulk order: one P2 and one Eve at the window farthest from rivendell. A dropout on a sensor that pauses the HVAC blocks the resume (see `modules/ha-hvac-openings.nix`), so reliability outranks the price difference.

## Coordinator Requirements

- **Thread/Matter**: Done — ZBT-2 + native OTBR on rivendell (`modules/homeassistant.nix`). Nothing else to buy for the radio.
- **Mesh depth**: Not done. Add at least one mains-powered Matter-over-Thread device (plug or switch) between rivendell and the far windows before a large deployment. See `smart-plugs.md`.

## Security System Integration (Alarmo)

Alarmo (HACS) auto-discovers all `binary_sensor` entities with security-related device classes. Any contact sensor that registers as `device_class: door` or `device_class: window` in HA will appear automatically in Alarmo's sensor list.

- Matter sensors via HA Matter integration: expose proper device class automatically
- No special wiring or config needed — just add the sensor to HA and Alarmo picks it up

Alarmo supports 4 arm modes (away, home, night, custom), per-sensor enable/disable per mode, entry/exit delays, and ntfy-compatible notifications. Works entirely locally.

## Cost Analysis (20-unit deployment, 2026-09-13 prices)

| Device | Per Unit | 20 Units | Notes |
|---|---|---|---|
| IKEA MYGGBETT | $11.99 + AAA | ~$240 + batteries | Not recommended yet (open HA bugs) |
| Aqara P2 | $29.99 | ~$600 | Battery included |
| Eve Door & Window (sale) | ~$32 | ~$640 | Prime Day 2026 price |
| Eve Door & Window (list) | $43.95 | ~$880 | Battery included |

No coordinator cost for any of them. Budget separately for one or more mains-powered Thread routers.

## Follow-ups

- [ ] **2026-09-13** — When the Eve 3-pack arrives, run it as the pilot (replaces the planned P2-vs-Eve pilot; the P2 is no longer being tested). Follow the install order in Decision. Watch each sensor for `unavailable` over a week and check its link in `ot-ctl child table` before buying more.
- [ ] **2026-09-13** — Kitchen Door ecobee sensor has been unavailable since pairing; check its battery and range in the ecobee app.
- [ ] **2026-09-13** — Re-check IKEA MYGGBETT when [core #162230](https://github.com/home-assistant/core/issues/162230) (disconnects) and [core #174389](https://github.com/home-assistant/core/issues/174389) (OTA fails) close. If both are fixed it becomes the bulk pick on price.
- [ ] **2026-09-13** — Buy Eve units during a sale (Feb, Mar and Jun 2026 each had one at $32–34).
- [ ] **2026-03-17** — Alarmo setup: after first sensors are added, install Alarmo via HACS and configure zones (perimeter = doors/windows; interior = motion sensors if added later).

## Decision

- **Protocol**: Matter-over-Thread only (2026-09-13). No Zigbee or Z-Wave.
- **Chosen device**: Eve Door & Window (Matter), 3-pack. It's the first batch and doubles as the pilot. Aqara P2 stays the fallback if the Eves disappoint.
- **Date purchased**: 2026-09-13 (ordered, not yet arrived)
- **Price**: $32 per sensor (the sale price)
- **Where purchased**: *(record)*
- **Placement**: *(decide on arrival — which three doors/windows)*
- **HA integration**: Matter
- **Installation notes** (plan, not done yet):
  1. **Install the Thread smart plug first** (ordered the same day, see `smart-plugs.md`). Confirm it is a router (`ot-ctl neighbor table` on rivendell, role `R`) before pairing the sensors, so they attach through it rather than straight to rivendell.
  2. Commission each Eve through HA's Matter integration. Pairing from an iPhone also adds an Apple Home fabric, as happened with the Eve Weather; remove it if unwanted.
  3. Check each sensor's link in `ot-ctl child table`. Match each sensor to its node by the ext MAC in the Matter `NetworkInterfaces` attribute, not by guessing from RSSI.
  4. Give each entity a clear name (`binary_sensor.<room>_window_contact`), and confirm `device_class` is `window` or `door`.
  5. For sensors on openings used to air out the house, add the entity ID to `openings` in `modules/ha-hvac-openings.nix` and deploy rivendell. Otherwise the HVAC won't pause for them.
