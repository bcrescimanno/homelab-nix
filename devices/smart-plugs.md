# Smart Plugs (and Thread Routers)

## Context

- **Current setup**: No Matter-over-Thread plugs. **One ordered 2026-09-13** to act as the first Thread router; see Decision.
- **Goal**: Two jobs.
  1. Ordinary switched and energy-metered outlets.
  2. **Give the Thread mesh routers.** Measured 2026-08-30: rivendell's border router is the *only* router on our Thread network (`OpenThread-0b14`), so every Thread device links straight to the Pi in the office. The Eve Weather sits outdoors at roughly -85 to -93 dBm. A mains-powered Matter-over-Thread device normally becomes a router, and a plug is the cheapest, most freely placeable one.
- **Location/scope**: First unit between the office and the Eve Weather / exterior wall. More later near exterior doors if Thread locks or contact sensors are added.

## Selection Criteria

Standard criteria apply. Additional constraints:

- **Thread, not Wi-Fi**, for job 2. A Wi-Fi plug does nothing for the mesh.
- **Must actually become a Thread router.** Most mains-powered Thread devices do, but verify on arrival: on rivendell, `ot-ctl neighbor table` should show the plug with role `R`. (This `ot-ctl` build rejects `router table` with Error 35.)
- **Merging with Apple's Thread network is not the answer.** It was declined 2026-08-30 to keep Apple out of the infrastructure path. The five HomePod/Apple TV routers on `MyHome56` don't help our network; our own plug does.
- Energy monitoring is a plus, not a requirement.

## Research

### 2026-09-13

Mains-powered Thread devices are the vendor-neutral fix for a mesh with no depth. Plugs are the easiest to place; Inovelli White Series in-wall switches do the same job where a switch box is better placed than an outlet (see `switches-dimmers.md`).

#### Candidates

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|---|
| **Eve Energy (Matter)** | not verified | Yes | Thread | Full (no cloud, no account) | Yes | Yes (Matter) | The widely recommended Thread plug. Acts as a Thread router. Energy monitoring, 15 A / 1800 W, UL listed ([MatterCatalog](https://mattercatalog.com/guides/best-matter-smart-plugs-2026)). Same vendor as the Eve Weather already in use. **Top pick.** |
| **IKEA GRILLPLATS** | check IKEA US | Yes | Thread | Full | Yes | Yes (Matter) | Cheap, compact, energy monitoring, straightforward HA integration in one review ([chrissmart.de](https://chrissmart.de/en/ikea-grill-plates-in-home-assistant-inexpensive-matter-power-outlet-in-the-test/)). Some users report pairing trouble, which the thread attributes mostly to their Thread/IPv6 setup ([HA forum](https://community.home-assistant.io/t/ikea-and-home-assistant-grillplats/1013787)). **Router role not confirmed** in anything read — verify before relying on it for coverage. |
| **Meross MSS315** | ~half of Eve Energy | Yes (1.4) | **Wi-Fi** | Full after setup | Yes | Yes (Matter) | Fine as a plain metered plug, but does nothing for Thread. As a Wi-Fi Matter device it must be commissioned from the main LAN, not the IoT VLAN. |

#### What to Avoid

- **Wi-Fi plugs bought to fix Thread range** — they cannot route Thread.
- **Cloud-required plugs** (Wemo, Kasa without local control, generic Tuya Wi-Fi): standard rule.
- **Adding a second Thread border router casually** (e.g. hubs or cameras with one built in, like the Aqara G350). A second border router running its own network splits Thread rather than extending ours.

## Follow-ups

- [ ] **2026-09-13** — Cheapest step first: put the ZBT-2 on a USB extension cable (Pi 5 USB 3.0 ports are strong 2.4 GHz emitters). Re-read the Eve Weather's link quality in `ot-ctl child table` before buying anything.
- [x] **2026-09-13** — Buy one Thread plug. Ordered 2026-09-13 alongside an Eve Door & Window 3-pack (see `contact-sensors.md`).
- [ ] **2026-09-13** — On arrival, install it before pairing the new contact sensors. Commissioning through the iPhone Matter flow also adds it to an Apple Home fabric (as happened with the Eve Weather); remove that fabric afterwards if unwanted. Place it between the office and the Eve Weather, then confirm (a) it shows as a router, and (b) the Eve Weather's link improves. A sleepy child may take a while, or need a reset, to move to the new router.
- [ ] **2026-09-13** — Verify Eve Energy and GRILLPLATS current US prices.

## Decision

- **Chosen device**: Matter-over-Thread smart plug. *Record the model on arrival.* If it isn't the Eve Energy, confirm it actually becomes a router.
- **Date purchased**: 2026-09-13 (ordered, not yet arrived)
- **Where purchased**: *(record)*
- **Purpose**: First Thread router for `OpenThread-0b14`. It arrives with the Eve Door & Window 3-pack and must be up before they are paired.
- **Installation notes** (plan, not done yet): place between the office and the exterior wall/doors where the sensors go. Confirm role `R` in `ot-ctl neighbor table`. Check whether the Eve Weather's link improves in `ot-ctl child table` (-85 to -93 dBm today). Record placement and the before/after RSSI here.
- **HA integration**: Matter
