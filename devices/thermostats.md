# Thermostats

## Context

- **Current setup**: Ecobee (upstairs) + basic thermostat (downstairs). Replacing the Ecobee upstairs first; downstairs deferred.
- **Update 2026-09-13**: the ecobee (EB-STATE5, 10.0.1.173) is **no longer cloud-bound in HA**. It was removed from Apple Home and paired to HA via `homekit_controller` (fully local). The ecobee cloud integration was deleted and its discovery card ignored — do not re-add it. Entity is `climate.main_floor`; its SmartSensors surface as `binary_sensor.front_door_contact` and `binary_sensor.kitchen_door_contact`. It is re-exposed to Apple Home through the HASS Hall HomeKit Bridge. This removes most of the original urgency to replace it — see the 2026-09-13 research below.
- **Goal**: Replace Ecobee with a locally-controlled thermostat that integrates with Home Assistant. Primary automation need: shut off HVAC when windows/doors are open (currently handled via Ecobee but Ecobee has progressively broken this). Multi-sensor averaging has not worked well — all smart logic will move to HA.
- **System (upstairs)**: Gas furnace + central AC. C-wire present (no power extender needed). Single zone.
- **System (downstairs)**: Gas furnace only, no AC. Deferred — may add AC in the future.
- **Future**: Both systems will eventually be replaced with heat pumps. Thermostat must support heat pump wiring (O/B reversing valve, aux/emergency heat, dual-fuel).

## Selection Criteria

Standard criteria apply. Additional constraints:
- Must support heat pump wiring for future compatibility (O/B terminal, at least 2H/1C)
- Battery-powered thermostats not relevant here (mains-powered by definition)
- Smart features (AI scheduling, room sensor averaging) explicitly not needed — HA handles all automation logic
- **Added 2026-09-13**: must not require an Apple home hub (or any vendor hub) for automations. Apple devices are fine as clients, never as load-bearing infrastructure.

## Research

### 2026-03-16

Matter thermostat market is still maturing. Most "smart" thermostats are cloud-dependent; Matter-certified options are limited but usable. Key finding: setup requirements vary significantly — some need a cloud account once, some need it permanently, one (Lux TQ1) needs no account at all.

#### Candidates

| Device | Price | Matter | Protocol | Heat pump | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|---|
| **Lux TQ1** | ~$65 | Yes (1.4) | Wi-Fi | 3H/2C | Full (no cloud ever) | Yes | Yes (Matter) | No app/account required at all. Small but clean HA community. Top pick. |
| **Meross MTS300MA** | ~$70 | Yes | Wi-Fi | Yes (O/B) | Full after setup | Yes | Yes (Matter + meross_lan) | One cloud touch to generate Matter code, local forever after. Most proven HA Matter integration in category. |
| **Eve Thermostat** | ~$130 | Yes | Thread | Unconfirmed | Full (no cloud ever) | Yes | Yes (Matter) | Matter-over-Thread. Zero cloud. Just announced CES 2026; Q1 2026 shipping. Heat pump (O/B) support not yet confirmed in specs — this is the critical open question. |
| **Google Nest 4th gen** | ~$250 | Yes | Wi-Fi | 2H/2C + dual-fuel | Partial (Google account permanent) | Yes | Yes (Matter) | Best heat pump terminal count. Rejected: Google account required permanently — same cloud-hostility problem as Ecobee. |
| **Honeywell X8S** | ~$220 | Yes | Wi-Fi | 4H/2C | Partial (Resideo app) | Yes | Yes (Matter) | Matter issues in HA reported. Skip until resolved. |

#### What to Avoid

- **Ecobee (any model)**: cloud-hostile, even though they added Matter the cloud dependency remains. Same problem.
- **Google Nest (any)**: Google account required permanently.
- **Honeywell X2S**: Matter implementation broken in HA per community forum. "Honeywell X2S Thermostat Is Complete Garbage" — HA community thread.
- **Amazon Smart Thermostat**: no Matter, no HomeKit, Alexa cloud-only, no dual-fuel/heat pump.
- **Emerson Sensi Touch 2**: no Matter, cloud-only, dead end.

### 2026-09-13

Refresh of the March research. Three things changed.

**1. The replacement is now optional, not urgent.** The problem this file was opened to solve was ecobee's cloud breaking the window/door HVAC shutoff. The ecobee now runs locally through `homekit_controller`, and its door SmartSensors are already HA binary sensors, so the shutoff can be an HA automation today with no new hardware — since implemented as `modules/ha-hvac-openings.nix` (#699). The "What to Avoid: Ecobee" entry still stands for *new purchases* — it is about ecobee's cloud, which is now out of the path for the unit already on the wall.

Remaining reasons to replace it anyway: the eventual heat pump install (verify the ecobee's terminals then), and `homekit_controller` being a less-travelled path than Matter.

**2. Eve Thermostat (US): still unshipped, still unspecified.** As of 2026-09-13 the US HVAC model is listed as **"Coming Soon"** on [evehome.com/en-us/eve-thermostat](https://www.evehome.com/en-us/eve-thermostat) — it missed its announced Q1 2026 ship date ([Eve press release](https://www.evehome.com/en/news/eve-thermostat-na), $129.95).

- **Trap:** the same product page also carries the EU **underfloor-heating** Eve Thermostat, which *is* shipping. Its FAQ — "Only water-based 230-V underfloor heating systems … are supported", "does not support boilers or heat pumps" — describes the **EU model only**. It says nothing about the US HVAC model. (This was misread once during this refresh.)
- Eve has published **no** terminal list, stage counts, or O/B / aux-heat support for the US model. Heat pump support remains the open question.
- **New concern:** the press release states it "requires the Eve App for iPhone or iPad and a compatible home hub, such as Apple TV or HomePod, running software version 26 or later, for automations and remote access." Whether plain Matter control from HA works without an Apple hub is unstated. If an Apple hub is required, that conflicts with the no-Apple-infrastructure constraint above.

**3. Lux TQ1 is unchanged and still the top pick.** Matter 1.4 certified, Wi-Fi, "heat pump systems up to 3 heat and 2 cool", C-wire or LUX Power Bridge required ([Lux product page](https://luxproducts.com/products/tq1-smart-thermostat)). There is an active HA community thread for TQ1/TQX users ([HA community](https://community.home-assistant.io/t/any-lux-tqx-tq1-smart-thermostat-users/976352)); no regressions found.

**Network note for any Wi-Fi Matter thermostat (Lux, Meross):** commission it on the **main LAN**, not the IoT VLAN. matter-server binds `eth0`, and the IoT VLAN advertises no IPv6 prefix, so a Wi-Fi Matter device there is unreachable (learned pairing the Leviton D26HD, see `switches-dimmers.md`).

## Follow-ups

- [~] **2026-03-16** — Check Eve Thermostat specs when units start shipping (Q1 2026). **2026-09-13:** US model still "Coming Soon", no HVAC specs published. Also confirm whether HA-only Matter control works without an Apple home hub. Recheck at [evehome.com/en-us/eve-thermostat](https://www.evehome.com/en-us/eve-thermostat) — read the US section only.
- [ ] **2026-03-16** — When ready to buy: check HA community for any new Lux TQ1 issues or Meross MTS300MA regressions. (2026-09-13: none found for Lux.)
- [ ] **2026-03-16** — When adding downstairs thermostat: decide whether to match upstairs (Lux or Meross) or wait for Eve if heat pump support confirmed.
- [ ] **2026-09-13** — Decide whether to replace the ecobee at all now that it is local. The window/door shutoff is already done (`modules/ha-hvac-openings.nix`, #699) and does not depend on this decision.
- [ ] **2026-09-13** — Kitchen Door SmartSensor and Living Room room sensor were unavailable at pairing (device-side — check battery/range in the ecobee app). The kitchen door sensor is the one `modules/ha-hvac-openings.nix` watches; it dropped out for ~40 min on 2026-09-13, and the module's unavailable alert now covers that.
- [ ] **2026-09-13** — Decide whether `binary_sensor.front_door_contact` belongs in `openings`. It is paired and working but not watched — deliberate (a door opened briefly and often) or an omission?
- [ ] **Future** — When heat pump upgrade is planned: verify chosen thermostat's heat pump wiring support with the HVAC contractor before ordering. Confirm O/B, W2/AUX, dual-fuel terminals match the new system's requirements.

## HA Automation: Pause HVAC While the House Is Open

**Implemented 2026-09-13 in `modules/ha-hvac-openings.nix` (#699).** The module is the source of truth; read its header before changing behaviour. The draft YAML that used to live here was superseded by it and has been removed, so there is only one version of the logic.

How it behaves:

- **Pause:** any sensor in `openings` open for 60 s while `climate.main_floor` is in heat, cool or heat_cool → set it off, save the prior mode in `input_text.hvac_openings_saved_mode`, and push "HVAC paused" to both phones.
- **Resume:** every sensor in `openings` reports `off` → restore the saved mode immediately, silently. It also retries when the thermostat comes back from `unavailable`.
- **Manual override:** setting heat, cool or heat_cool by hand while paused abandons the pause; nothing is restored on close.
- **Already off:** a thermostat that is off is never paused, so a closing door never turns it on.
- **Dead sensor:** `unavailable`/`unknown` is not closed. A dark sensor never pauses and blocks resume; after 30 min it sends one alert to `notify.homelab_alerts`.
- **Restarts:** the saved mode is an `input_text`, which survives restarts (a `scene.create` snapshot would not), and every state-keeping automation re-checks on `homeassistant: start`.

**Watched today:** only `binary_sensor.kitchen_door_contact`. `binary_sensor.front_door_contact` exists but is **not** in `openings` — see Follow-ups.

### Adding sensors

When contact sensors are added (candidates in `contact-sensors.md`), do this for each one:

1. **Pair it and confirm the entity.** Find the entity ID in Developer Tools → States and check it reads `on` when open (device class door, window or opening). For a Thread sensor, check its link in `ot-ctl child table` at its final mounting position: the mesh has one router, and a sensor that drops to `unavailable` blocks every resume.
2. **Add the entity ID to `openings`** in `modules/ha-hvac-openings.nix`. That is the whole change — the any-open pause, all-closed resume, notification text and unavailable alert all follow the list.
3. **Deploy rivendell and test both directions**: open for 60 s → pause and notification; close everything → resume. deploy-rs does not catch Home Assistant failing to load a package, so confirm the automations exist and check a trace.

When the change is more than a longer list, follow the module header's expansion plan:

- **Windows want a different delay than doors** → make `openings` an attrset of entity → duration and emit one pause trigger per distinct duration.
- **A second thermostat or zone** (e.g. the downstairs thermostat in Follow-ups) → map each opening to the climate entity it affects, with one saved-mode helper per thermostat.
- **One dead sensor keeps blocking resume** once there are many → the escape hatch is to treat a sensor unavailable for longer than `unavailableFor` as closed *for resume only*, keeping the alert. Don't do it pre-emptively: it trades a noisy failure (HVAC stays off, alert fires) for a quiet one (AC runs with a window open).
- **Replacing the ecobee** (Lux TQ1 or otherwise) → change `thermostat`, and check the new entity's HVAC modes still match `activeModes`.

## Decision

*(Pending)* — 2026-09-13 leaning: keep the ecobee (now local via `homekit_controller`) and revisit replacement at heat pump time. The shutoff is implemented in `modules/ha-hvac-openings.nix`. Lux TQ1 remains the pick if replacing sooner.
