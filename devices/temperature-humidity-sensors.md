# Temperature & Humidity Sensors

## Context

- **Current setup**: None — no temperature or humidity sensors deployed yet.
- **Goal**: Monitor indoor temperature and humidity per room; drive HVAC automations, comfort alerts, and occupancy-based climate control.
- **Scale**: Multiple sensors (5–15+ likely), one per room or zone.
- **HA integration target**: `sensor` entities with `device_class: temperature` and `device_class: humidity`. Used by climate automations, dashboards, and optionally Home Assistant's climate integration.

## Selection Criteria

Standard criteria apply. Additional constraints specific to this category:

- **Battery is universal here** — temperature/humidity sensors are almost always battery-powered; Wi-Fi is therefore categorically excluded (hard rule: no Wi-Fi battery devices).
- **Thread border router**: ZBT-2 running as Thread RCP on rivendell (flashed 2026-03-17). OTBR native (`services.openthread-border-router`) since 2026-08-01, HA Thread integration active. Thread/Matter devices work now — but the mesh has **one router** (rivendell), so every battery sensor must reach the Pi directly.
- **Zigbee coordinator**: No coordinator currently configured. Zigbee requires a **separate** USB stick (e.g., Sonoff Zigbee 3.0 USB Dongle Plus, ~$20, or a second ZBT-2) before any Zigbee sensor works — the ZBT-2 is on Thread and cannot run both.
- **Accuracy matters**: For HVAC automations, ±0.2°C / ±2% RH or better is preferred. Cheap sensors (DHT11-class) with ±2–3°C are often not worth deploying.

## Research

### 2026-03-17

Research covered: matteralpha.com (Matter product database and reviews), 9to5mac HomeKit Weekly, homekitnews.com, Home Assistant community forums (multiple threads), r/homeassistant, SmartHomeScene reviews, CNX Software, Android Authority, The Gadgeteer, IKEA official product pages, Aqara official US store, Eve Systems official pages, Apollo Automation product pages, and Zigbee2MQTT device database.

**State of Matter/Thread temperature sensors (early 2026):**
A small but real set of Matter-over-Thread temperature sensors are shipping and certified — this is no longer vaporware. The viable options are: IKEA TIMMERFLOTTE ($10, just arrived in US stores), Aqara W100 (~$40–50, dual Thread/Zigbee, but Thread mode is "unfinished"), Eve Weather ($80, outdoor, excellent), and arre TUO (~$35, but community reliability reports are concerning). The IKEA sensor is the most compelling new entrant — $10, available in-store, Matter-over-Thread certified.

**Zigbee remains the workhorse for interior sensors.** Sonoff SNZB-02P is the community consensus winner for pure sensor use: Swiss-made SHT4x chip (±0.2°C, ±2% RH), CR2477 battery rated 4 years, ~$10–12, works flawlessly with ZHA and Zigbee2MQTT. No display — just data. Aqara's classic T1 sensors work with Z2M/ZHA but officially "require Aqara hub" (this is only true for HomeKit — Z2M/ZHA works fine). Aqara's T1 sensors also have known occasional disconnection issues on non-Aqara coordinators.

**ESPHome/DIY:** Apollo Automation TEMP-1 is the best pre-built ESPHome option but is probe-focused (refrigerator/freezer monitoring), not a typical room sensor. ESPHome on battery is generally not ideal — deep sleep modes help but battery life is mediocre compared to purpose-built Zigbee/Thread chips. Best for mains-powered or probe use cases.

**What to avoid:** Govee Wi-Fi sensors (cloud required, terrible HA integration), SwitchBot meters (Bluetooth only — limited range, needs hub for automation), Inkbird sensors (Bluetooth only), generic Tuya Wi-Fi, any sensor marketed as "Wi-Fi battery powered." Also avoid the original arre/TUO — community reports of total device failures and "horrific battery life" after a few months.

#### Candidates

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|
| **IKEA TIMMERFLOTTE** | $10 | Yes (certified) | Thread | Full | Yes | Yes (Matter) | Best value Matter-over-Thread sensor. $10, AAA batteries, dot-matrix display (tap to show temp, then humidity). Available in US IKEA stores and online as of early 2026. Requires Thread border router (ZBT-2 will work). No "always-on" display — display activates on tap to save battery. Accurate, CSA-certified. |
| **Aqara W100 Climate Sensor** | ~$40–50 | Yes (certified) | Thread or Zigbee (user selects at pair time) | Full | Yes | Yes (Matter or Z2M/ZHA) | Dual-protocol: pair as Thread/Matter OR as Zigbee 3.0 — not both simultaneously. 3.4" LCD always-on display. 3 programmable buttons. ±0.2°C / ±2% RH accuracy. 2× CR2450 battery, ~2.3 years (Thread). **Thread/Matter mode is "unfinished"**: display doesn't show secondary sensor data, button actions are limited vs Zigbee mode. Full features only in Zigbee mode. If display + buttons are important, use Zigbee; if Matter ecosystem integration matters more, use Thread. |
| **Eve Weather (Matter)** | $80 | Yes (certified) | Thread | Full (no cloud ever) | Yes | Yes (Matter, Eve joined Works-with-HA Apr 2025) | **Outdoor/exposed use**: IPX4 rated, large display. Measures temp, humidity, and barometric pressure. CR2450 battery ~1 year. Excellent accuracy. Overkill (and wrong form factor) for indoor rooms, but best option for outdoor/porch/garage monitoring. Eve is fully local, zero cloud, zero account. |
| **arre Temperature Sensor (TUO)** | ~$35 | Yes (certified) | Thread | Full | Yes | Yes (Matter) | Measures temp, humidity, barometric pressure, and VOC air quality. CR2032, ~1 year claimed. **Community reliability concerns**: multiple HA forum reports of total device failures (bricking) and "horrific" battery drain. One of the first Matter/Thread temp sensors to ship — but quality control issues flagged. Not recommended until reliability improves. |
| **SONOFF SNZB-02P** | ~$10–12 | No | Zigbee 3.0 | Full | No | Yes (ZHA / Z2M) | Community consensus best Zigbee temp/humidity sensor. Swiss-made Sensirion SHT40 chip: ±0.2°C, ±2% RH — highest accuracy in class. CR2477 battery rated 4 years. Compact, no display. Pairs with ZHA and Zigbee2MQTT with no issues. Works with any Zigbee 3.0 coordinator — no Sonoff hub required. No HomeKit. |
| **SONOFF SNZB-02D** | ~$13–15 | No | Zigbee 3.0 | Full | No | Yes (ZHA / Z2M) | Like SNZB-02P but adds a 2.5-inch LCD display. Calibration recommended on humidity (reports ~6–7% low vs reference). Display has poor viewing angles. Good option if a local display is needed on a shelf; otherwise SNZB-02P has better accuracy. |
| **Aqara Temperature & Humidity Sensor T1** | ~$13–18 | No | Zigbee | Full (via Z2M/ZHA) | Yes (requires Aqara hub) | Yes (Z2M / ZHA — **no Aqara hub needed for HA**) | Small, puck-form sensor. Works with Zigbee2MQTT and ZHA without Aqara hub (Amazon listing says "hub required" — that's only for native HomeKit). Known occasional disconnection issues on non-Aqara coordinators. Slightly lower accuracy than SNZB-02P (±0.3°C). Good if already in Aqara ecosystem. |
| **Apollo Automation TEMP-1** | ~$20–25 | No | Wi-Fi (ESPHome) | Full (ESPHome/local) | No | Yes (ESPHome, native) | Pre-built ESPHome device — plug into Wi-Fi, auto-discovered by HA. Designed primarily for **probe-based** monitoring (refrigerator, freezer, aquarium) via external DS18B20 probe. Has onboard AHT30 for ambient temp/humidity. Mains-powered or rechargeable battery (limited life). **Not suitable as a typical battery-powered room sensor** — ESPHome Wi-Fi devices drain batteries fast. Best use: fixed probe monitoring near power. |
| **UniFi G4 Sensor (multi-sensor)** | ~$80 | No | UniFi proprietary | Full (UDM Pro on-prem) | No | Yes (UniFi Protect integration, official) | Multi-sensor: contact + motion + **temperature + humidity** + light + leak. Only justified if deploying UniFi Protect anyway and want all-in-one. Overkill and expensive for temperature-only use. |

#### What to Avoid

- **Govee Wi-Fi thermometers** (H5179, H5075, etc.): Cloud-required for HA integration. No local API. Popular but fundamentally incompatible with the local-control requirement. Avoid.
- **SwitchBot Meter / Meter Plus**: Bluetooth only. Short range (~30ft), requires SwitchBot Hub to reach HA over the network, and the hub adds cloud dependency. HA integration via Bluetooth works locally but needs HA Bluetooth hardware close to each sensor. Impractical for whole-home deployment. Avoid for HA automation use.
- **Inkbird IBS-TH2 / IBT series**: Bluetooth only, same range/hub issues as SwitchBot. Primarily useful with the dedicated Inkbird app. HA Bluetooth integration is unofficial/unreliable. Avoid.
- **arre Temperature Sensor (TUO)**: Until reliability improves. Community reports of bricking and terrible battery life. The hardware concept is right (Matter/Thread, VOC, pressure) but real-world QC is not there yet. Check again in 6+ months.
- **Aqara WSDCGQ11LM (original, round/square)**: Older Zigbee device, not Zigbee 3.0, uses a non-standard Xiaomi cluster — known pairing stability issues with non-Aqara coordinators. Replaced by T1; prefer T1 or go to SNZB-02P instead.
- **Any Tuya/Smart Life Wi-Fi temperature sensor**: Tuya Zigbee sensors are fine (work with Z2M); Tuya Wi-Fi sensors require cloud and are excluded by the battery+Wi-Fi hard rule.
- **DHT11-based DIY sensors**: Accuracy is ±2°C / ±5% RH — far too imprecise for climate automation. If DIY, use Sensirion SHT31/SHT40 or BME280 at minimum.
- **Generic Amazon "smart thermometer" brands** (Govee, inkbird, ThermoPro Wi-Fi models): All require cloud. None have local HA integration. Avoid.

### 2026-09-13

**Eve Weather deployed outdoors** — paired 2026-08-30 as Matter node 7, `sensor.eve_weather_temperature`, drives `modules/ha-window-notifications.nix`. The device is accurate; **siting** was the whole problem:

- Under a low roof eave it was fully shaded and still read up to **+19.5°F** high on a hot, still afternoon (2026-09-02: Eve 95.5°F vs met.no 76°F), plus an overnight warm bias from the structure releasing heat. The error swung between +3.6 and +19.5 on consecutive days at the same spot, so a single good day proves nothing about a placement.
- Between those regimes it read within 0.2°F of met.no — a miscalibrated sensor could not do that.
- The requirement is **airflow away from the structure**, not merely shade. A radiation shield is the proper fix and would end the relocation loop.
- Moved 2026-09-04 ~09:00. First partial day was clean (mean +0.1°F, range ±1.6) but it was a cloudy, easy day. Verdict still needs a clear, low-wind 83°F+ afternoon plus an overnight comparison.
- **Thread range:** outdoors it links straight to rivendell at roughly -85 to -93 dBm, only ~7 dB above the noise floor, because the mesh has no other router. On 2026-09-13 it dropped off Thread when the UniFi 2.4 GHz radio was locked to Wi-Fi ch6 (overlaps our Thread ch19), and re-attached on its own once the lock was removed.

**Indoor follow-ups (due 2026-09-17, checked early):**

- **Aqara W100:** no evidence Thread/Matter mode has improved. Aqara's own forum has a 2026 wish-list thread asking for full configurability over Matter and firmware updates without a forced reset and protocol switch ([Aqara forum](https://forum.aqara.com/t/wish-list-for-2026-full-configurability-and-firmware-updates-over-matter-thread/181733)). Full features still only in Zigbee mode.
- **arre:** still sharply split. Many buyers report battery drain within a month or two, firmware lockups affecting the wider Matter/Thread network, and units that stop responding ([Matter Alpha review](https://www.matteralpha.com/review/arre-temperature-sensor-review)). A device that can destabilise a single-router mesh is an especially bad fit here. Keep avoiding.
- **IKEA TIMMERFLOTTE:** accurate once working, but commissioning is inconsistent from home to home across IKEA's Thread line ([AppleInsider, 2026-05](https://appleinsider.com/articles/26/05/15/ikea-matter-over-thread-review-amazing-smart-home-tech-when-they-work)); some users call it one of the most frustrating IKEA devices to connect. Battery type conflicts between sources (March entry: AAA; AppleInsider: 2×AA) — check [IKEA's page](https://www.ikea.com/us/en/p/timmerflotte-temperature-humidity-sensor-smart-50618957/) before buying spares. Still the cheapest Matter sensor; buy one and test before buying ten.

## Protocol Decision Guide

| Situation | Recommendation |
|---|---|
| Thread border router (ZBT-2) running, want cheapest Matter sensor | **IKEA TIMMERFLOTTE** ($10) |
| Thread border router running, want display + buttons on sensor | **Aqara W100** in Thread/Matter mode (~$40–50) |
| Thread border router running, want best outdoor/porch sensor | **Eve Weather** ($80) — outdoor only |
| Have Zigbee coordinator, want best accuracy + 4-year battery life | **SONOFF SNZB-02P** (~$11) |
| Have Zigbee coordinator, want a visible display on sensor | **SONOFF SNZB-02D** (~$14) or **Aqara W100** in Zigbee mode |
| No coordinator yet, want to start with Matter now | **IKEA TIMMERFLOTTE** (wait for ZBT-2 OTBR setup, then $10/sensor) |
| Need probe sensor for fridge/freezer near power outlet | **Apollo Automation TEMP-1** (~$22, ESPHome/Wi-Fi, mains) |

## Coordinator Requirements

Before non-Matter sensors work in HA:

- **Zigbee**: Need a **separate** Zigbee coordinator USB stick — the ZBT-2 is committed to Thread and cannot run Zigbee simultaneously. Recommended: **Sonoff Zigbee 3.0 USB Dongle Plus (SONOFF-ZIGBEE-3.0-USB-ZDONGLE-P)** — ~$20, or a second ZBT-2. HA is native now (not a `--privileged` container), so the device needs udev/permissions declared in Nix. Use Zigbee2MQTT (`services.zigbee2mqtt`; better device support and attribute exposure than ZHA).
- **Thread/Matter**: OTBR running on rivendell (ZBT-2, since 2026-03-17; native module since 2026-08-01). HA Thread integration configured. Ready now — mind the single-router range limit.

## Aqara Hub Clarification

Aqara's Amazon listings say "Requires Aqara Hub (not 3rd-Party)" — this is **only true for native Apple HomeKit pairing via the Aqara hub**. For Home Assistant via Zigbee2MQTT or ZHA, no Aqara hub is required. The T1 sensors pair directly with any Zigbee 3.0 coordinator. The W100 in Thread mode pairs directly as a Matter device with no Aqara hub.

The Aqara W100 does support Aqara's own Matter hub (M100) for additional features, but that hub is not required for HA or HomeKit when using Thread mode.

## Follow-ups

- [x] **2026-08-01** — Eve Weather chosen for outdoor temperature (drives `modules/ha-window-notifications.nix`). Paired 2026-08-30 (#636); also tracked in `Plan.md` → Home Assistant / IoT (this file was gitignored at the time).
- [ ] **2026-09-13** — Eve Weather placement verdict: needs a clear, low-wind 83°F+ afternoon and an overnight comparison against met.no at the new spot. If it fails, buy a radiation shield rather than moving it again.
- [ ] **2026-09-13** — Put the ZBT-2 on a USB extension cable (the Pi 5's USB 3.0 ports are strong 2.4 GHz emitters). Cheapest range fix for every Thread device; still not done.
- [ ] **2026-03-17** — Test IKEA TIMMERFLOTTE pairing with HA Matter integration. Still not done; inconsistent commissioning reports make a one-unit test before any bulk buy more important.
- [x] **2026-09-17** — Re-evaluate arre sensor reliability. Checked 2026-09-13: still poor (battery drain, lockups). Next look 2027-03.
- [x] **2026-09-17** — Check whether Aqara W100 Thread-mode limitations were fixed. Checked 2026-09-13: no fix found. Next look 2027-03.
- [ ] **2026-03-17** — If Zigbee route ever desired: add a **dedicated** Zigbee coordinator to rivendell (the ZBT-2 stays on Thread and cannot run both — a second ZBT-2 or a Sonoff Dongle Plus). Set up Zigbee2MQTT (`services.zigbee2mqtt` native nixpkgs module exists).

## Decision

- **Chosen device (outdoor)**: Eve Weather (Matter over Thread)
- **Date purchased**: August 2026 (paired 2026-08-30)
- **Where purchased**: *(not recorded)*
- **Installation notes**: First under a low roof eave (2026-08-30) — fully shaded but read up to +19.5°F high on hot, still afternoons. Moved 2026-09-04 to a spot with more airflow; verdict pending. Links directly to rivendell at roughly -85 to -93 dBm.
- **HA integration**: Matter node 7, `sensor.eve_weather_temperature` — not the serial-prefixed `eve_weather_20ebs9901_*` entities, which are disabled Matter diagnostics. Consumed via `sensor.outdoor_temperature` in `modules/ha-window-notifications.nix`.
- **Indoor sensors**: no decision yet.
