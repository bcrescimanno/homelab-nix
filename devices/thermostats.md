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

**1. The replacement is now optional, not urgent.** The problem this file was opened to solve was ecobee's cloud breaking the window/door HVAC shutoff. The ecobee now runs locally through `homekit_controller`, and its door SmartSensors are already HA binary sensors, so the shutoff can be an HA automation today with no new hardware. The "What to Avoid: Ecobee" entry still stands for *new purchases* — it is about ecobee's cloud, which is now out of the path for the unit already on the wall.

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
- [ ] **2026-09-13** — Decide whether to replace the ecobee at all now that it is local. If not, implement the window/door shutoff below against the ecobee.
- [ ] **2026-09-13** — Kitchen Door SmartSensor and Living Room room sensor were unavailable at pairing (device-side — check battery/range in the ecobee app). Must be fixed before the shutoff automation can rely on them.
- [ ] **Future** — When heat pump upgrade is planned: verify chosen thermostat's heat pump wiring support with the HVAC contractor before ordering. Confirm O/B, W2/AUX, dual-fuel terminals match the new system's requirements.

## HA Automation: Window/Door Shutoff

**Rewritten 2026-09-13.** The March version used placeholder entities, the deprecated `platform:`/`service:` keys and `"00:05:00"` duration strings. In this repo it should be declared as a Home Assistant package in Nix (like `modules/ha-bathroom-lights.nix`), not added through the UI.

```yaml
# Turn off HVAC when any door is opened, remembering the prior mode
- alias: HVAC off when doors open
  triggers:
    - trigger: state
      entity_id:
        - binary_sensor.front_door_contact
        - binary_sensor.kitchen_door_contact
        # add window sensors here as they are installed
      to: "on"
      for: { seconds: 30 }        # ignore walking through the door
  conditions:
    - condition: not
      conditions:
        - condition: state
          entity_id: climate.main_floor
          state: "off"
  actions:
    - action: scene.create
      data:
        scene_id: hvac_before_door_open
        snapshot_entities: [climate.main_floor]
    - action: climate.set_hvac_mode
      target: { entity_id: climate.main_floor }
      data: { hvac_mode: "off" }

# Restore after every door has been closed for 5 minutes
- alias: HVAC restore when doors closed
  triggers:
    - trigger: state
      entity_id:
        - binary_sensor.front_door_contact
        - binary_sensor.kitchen_door_contact
      to: "off"
      for: { minutes: 5 }
  conditions:
    # All sensors must read "off". An "unavailable" sensor (the Kitchen Door
    # SmartSensor today) fails this, so the HVAC stays off rather than
    # restoring blind. Fix the sensor rather than loosening the condition.
    - condition: state
      entity_id:
        - binary_sensor.front_door_contact
        - binary_sensor.kitchen_door_contact
      state: "off"
    # Only restore a snapshot the first automation actually took. Test that
    # the entity EXISTS — a created scene's state is "unknown" until it is
    # activated, so a has_value()/state check would never pass.
    - condition: template
      value_template: "{{ states.scene.hvac_before_door_open is not none }}"
  actions:
    - action: scene.turn_on
      target: { entity_id: scene.hvac_before_door_open }
    # Delete it, or a later door opening shorter than the 30 s trigger (which
    # takes no new snapshot) would still fire this restore 5 min after closing
    # and silently revert any mode change made since.
    - action: scene.delete
      target: { entity_id: scene.hvac_before_door_open }
```

Caveat: `scene.create` scenes live in memory, so a HA restart while a door is open loses the snapshot. The restore then does nothing and the HVAC stays off — acceptable failure direction, but see `modules/ha-bathroom-lights.nix` for the restart-trigger pattern if it matters.

*2026-09-13 fix:* the first rewrite restored without deleting the snapshot, so a brief door opening could revert a manual mode change up to 5 minutes later. The existence check and `scene.delete` above close that.

## Decision

*(Pending)* — 2026-09-13 leaning: keep the ecobee (now local via `homekit_controller`), implement the shutoff in HA, and revisit replacement at heat pump time. Lux TQ1 remains the pick if replacing sooner.
