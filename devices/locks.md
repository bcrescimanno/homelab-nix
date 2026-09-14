# Smart Door Locks

## Context

- **Current setup**: None — no smart locks installed.
- **Goal**: Add smart lock(s) for keyless entry, remote access, and HA automations (auto-lock, presence-based unlock, guest codes).
- **Requirements**: Must not require a cloud service for runtime operation. Battery drain is a real concern — Wi-Fi is disqualifying for battery-powered locks.
- **Thread border router**: ZBT-2 on rivendell is set up and running OTBR as of 2026-03-17. Thread devices are ready to go.
- **Zigbee coordinator**: Not configured. Zigbee-only locks require adding a coordinator first.
- **Z-Wave controller**: Not configured. Z-Wave locks require adding a controller first.

## Selection Criteria

Standard criteria apply with additional constraints:

- **Battery-powered + Wi-Fi = hard reject.** All smart locks under consideration are battery-powered. Wi-Fi kills battery (3 months max vs. 1+ year on Thread/Zigbee). No Wi-Fi battery locks.
- **HomeKey required.** Entire household uses Apple devices. HomeKey (NFC/UWB express mode — tap iPhone/Watch to unlock without opening the app) is a hard requirement. Note: HomeKey is distinct from HomeKit compatibility via Matter — verify certification explicitly, not just "works with HomeKit."
- PIN code management: HA has managed Matter lock users and PINs natively since 2026.4 (see 2026-09-13). The check per lock is now whether it exposes PIN users over Matter — flag any lock that doesn't.

## Research

### 2026-03-17

Matter-over-Thread locks are now a real, shipping category as of late 2024/2025 — but the ecosystem is still early. Key findings:

- **Level** and **Nuki** are the two standout Matter-over-Thread locks with confirmed good HA integration and strong local-first stories.
- **Yale Assure Lock 2** (the original modular line) is Wi-Fi or Bluetooth only for the standard consumer version; Yale's *new* 2025 Matter-over-Thread lock is a different product shipping summer 2025.
- **Schlage Encode Plus** is Wi-Fi + Thread, but Thread is used only for HomeKit (via Apple's border router) — it is NOT a Matter device and has no Matter certification. HA integration requires the Schlage cloud API.
- **ULTRALOQ Bolt** ships with Matter-over-Thread but has active, unresolved HA pairing issues as of late 2025.
- **Schlage Sense Pro** (Matter-over-Thread) was announced at CES 2025 but was not yet shipping as of the research date.
- **Aqara U100** is Zigbee-based; "Matter" support is bridged through an Aqara hub (the lock itself is not a native Matter device).
- **August Wi-Fi (4th gen)** fails the battery+Wi-Fi hard rule. 3-month battery life on Wi-Fi. Rejected.
- **Schlage BE489WB** is Wi-Fi only (not Zigbee, despite the user question — confirmed across all official sources). Rejected.

HA PIN code management is a known gap for *all* Matter locks as of 2025. There is an open HA feature discussion (#551) but no native UI yet. Workaround: manage codes in the lock's app or use a HACS custom component.

#### Candidates

| Device | Price | Matter | Protocol | Local | HomeKit | HA | Battery | Notes |
|---|---|---|---|---|---|---|---|---|
| **Nuki Smart Lock Ultra** | ~$230 (US) | Yes (certified) | Thread | Full after setup | Yes (via Matter) | Yes (Matter, Local Push) | Built-in rechargeable, ~6mo/charge | Best-in-class HA story. "Works with HA" certified. No cloud after initial setup. Retrofit (no cylinder change). US launched Jul 2025. |
| **Nuki Smart Lock 4.0 Pro** | ~$180 (US) | Yes (certified) | Thread | Full after setup | Yes (via Matter) | Yes (Matter, Local Push) | 4×AA, ~6 months | Same HA story as Ultra. Slightly cheaper. Confirmed working with ZBT-1/ZBT-2 (some setup friction reported, solved). |
| **Level Lock+ (Matter)** | ~$200 | Yes (certified) | Thread | Full after setup | Yes + HomeKey | Yes (Matter) | 1×CR2, ~6–12 months | Smallest/most invisible design. HomeKey support. Concurrent Bluetooth + Thread. Active HA community. Level app needed for initial pairing only. |
| **Level Lock Pro** | ~$250 | Yes (certified) | Thread | Full after setup | Yes + HomeKey | Yes (Matter) | 1×CR2, ~9–12 months | Newer model (shipping Aug 2025). Improved battery, door sensor, security. Reviews excellent. Best Level option if in stock. |
| **Yale Smart Lock with Matter** | ~$170 | Yes (certified) | Thread | Full after setup | Yes (via Matter) | Yes (Matter) | 4×AA, ~12 months | Yale's new dedicated Matter-over-Thread lock announced Mar 2025, ships summer 2025. Distinct from Assure Lock 2 line. Excellent battery life. |
| **ULTRALOQ Bolt (Matter)** | ~$130 | Yes (certified) | Thread | Full after setup | Yes (via Matter) | Unreliable | 4×AA | Matter-over-Thread + fingerprint reader. **Active HA pairing failures reported (2025)**. Door sensor state unreliable. Hold until issues resolved. |
| **Schlage Sense Pro** | TBD (~$200?) | Yes (announced) | Thread | Likely full | Yes (via Matter) | Likely via Matter | TBD | CES 2025 announcement. UWB + Matter-over-Thread. **Not yet shipping as of research date.** Watch for release. |
| **Schlage Encode Plus** (BE499WB) | ~$230 | No | Wi-Fi + Thread* | Cloud (Schlage API) | Yes (native + HomeKey) | Cloud-only (Schlage integration) | 4×AA, ~3–12 months** | *Thread used only for HomeKit, not Matter. HA integration uses Schlage cloud API — slow (10–15s state updates), unreliable. Rejected for this stack. |
| **Aqara U100** | ~$170 | Bridge-only | Zigbee → Aqara hub | Partial (hub required) | Yes (HomeKey, native) | Via Aqara hub | 8×AA, ~1 year | Zigbee lock. "Matter" is bridged via Aqara hub. Requires Aqara Zigbee 3.0 hub for HA/remote. No direct Matter certification on lock itself. Ecosystem lock-in. |
| **Yale Assure Lock 2** (standard) | ~$150–$250 | Module only (Wi-Fi version) | Wi-Fi or Bluetooth | Cloud (Wi-Fi module) | Yes (with module) | Cloud-only (Wi-Fi) | 4×AA, ~6 months (Wi-Fi) | The modular platform. Matter module was never shipped for the Assure Lock 2 consumer line. Wi-Fi module = cloud. Bluetooth = no remote. Skip; see Yale Smart Lock with Matter instead. |

**(*)** Schlage Encode Plus Thread: This is Apple HomeKit's Thread network specifically, NOT Matter-over-Thread. The lock is not Matter-certified.

**(**)** Schlage Encode Plus battery: ~3 months on Wi-Fi, ~12 months if using HomeKit-Thread-only (but then HA loses local access — it falls back to cloud).

#### What to Avoid

- **August Wi-Fi Smart Lock (4th gen)**: Wi-Fi + battery = rejected. 3–6 month battery life. Cloud-dependent (August/Yale cloud API in HA). No Matter. No Thread. Fails three criteria.
- **Schlage BE489WB**: This is the Schlage Encode (not Encode Plus) — Wi-Fi only, no Thread, no Matter. HA integration uses Schlage cloud API. Rejected.
- **Schlage Encode Plus (BE499WB)**: Not a Matter device. Thread is used exclusively for Apple HomeKit's border router — HA still uses the Schlage cloud API. 10–15s state lag in HA. Battery life collapses if both Wi-Fi and HomeKit are active simultaneously. Cloud-dependent for HA.
- **Yale Assure Lock 2 (Wi-Fi module)**: Cloud-dependent. The promised Matter module for the Assure Lock 2 line was never shipped. The new Yale Smart Lock with Matter (2025) is the replacement.
- **ULTRALOQ Bolt (Matter) — current**: Active HA Matter pairing failures and door sensor bugs as of late 2025. May resolve in future firmware — revisit in 6 months.
- **Schlage Connect BE469 Zigbee**: The Zigbee variant of the Connect line (BE468) was discontinued. No current Schlage Zigbee lock is available. The Z-Wave Plus (BE469ZP) is alive but requires a Z-Wave controller (not currently in this homelab).
- **Any proprietary ecosystem lock** (e.g., Kwikset Halo, Lockly, Wyze Lock): Cloud-required, no Matter, no Thread, no local path.

#### Matter-over-Thread Locks: Current Reality Check (Mar 2026)

The ecosystem caught up significantly in 2024–2025. These locks are **actually shipping** on Matter-over-Thread as of the research date:

| Lock | In Stock | HomeKey |
|---|---|---|
| Level Lock+ (Matter) | Yes (Amazon, Home Depot) | Yes |
| Level Bolt (Matter) | Yes (Amazon, Home Depot) | No |
| Level Lock Pro | Yes (Aug 2025) | Yes |
| Nuki Smart Lock Ultra (US) | Yes (Jul 2025) | Yes (via Matter) |
| Nuki Smart Lock 4.0 Pro (US) | Yes | Yes (via Matter) |
| Yale Smart Lock with Matter | Summer 2025 | No |
| ULTRALOQ Bolt (Matter) | Yes | No |
| Schlage Sense Pro | Not yet shipping | Yes (via Matter) |

#### HA PIN Code Management Gap

This affects **all** Matter locks. As of 2025, HA has no native PIN code management UI for Matter door locks. Options:
1. Manage codes in the lock's native app (Level app, Nuki app, etc.)
2. Use a HACS custom integration (e.g., `keymaster` or `lock-code-manager`) — community-maintained, variable reliability
3. Wait for native HA support (open feature request: github.com/orgs/home-assistant/discussions/551)

This is a real UX trade-off: you can lock/unlock from HA automations, but adding/removing guest codes requires the vendor app. For this homelab that's acceptable; for a rental property or frequent guest management it would be a significant limitation.

#### UniFi Access Option

UniFi Access is Ubiquiti's access control platform — runs as an application on the UDM Pro (already present), so controller cost is $0 additional.

**Does not meet requirements for this use case:**
- **No Apple HomeKey.** UA-G2/G3 readers use NFC with Ubiquiti's own credential system (cards, fobs, QR codes, mobile app). HomeKey is not supported or announced.
- **Not compatible with residential deadbolts.** Hubs output a wired relay to drive electric strikes or maglocks — requires door frame modification and wiring. Does not replace a deadbolt thumbturn.
- **HA integration is unlock-only.** Community integration (`imhotep/hass-unifi-access`) connects via local API — no cloud — but the UniFi Access API does not expose a lock command. Doors lock by timer or door sensor only.

**Minimum per-door cost if pursuing anyway:** UA-Ultra ($129) + electric strike ($80–150) + wiring = ~$210–280 new hardware.

**When UniFi Access makes sense:** Multi-door deployments (garage, office, secondary entry) where NFC fobs, access schedules, audit logs, and HA event-driven automations matter more than HomeKey. The ecosystem scales well and the controller is free given the existing UDM Pro.

### 2026-09-13

Three changes since March: HA closed the PIN gap, new HomeKey + Thread locks shipped, and Level's HA story got worse.

#### HA now manages Matter lock PINs natively (2026.4)

A "Manage lock" option on the Matter lock's device page lists users and lets you add, edit or remove them with a PIN and an access type — permanent, or one-time (the lock deletes the code after one use). The same functions are exposed as actions (e.g. [`matter.set_lock_user`](https://www.home-assistant.io/actions/matter.set_lock_user/)), so an automation can mint a one-time guest code and send it via ntfy.

- Launched as beta. Matter Alpha's test hit a bug where a one-time code worked more than once ([Matter Alpha, 2026-03-26](https://www.matteralpha.com/news/home-assistant-adds-native-pin-management-for-matter-smart-locks)).
- Named as working: Aqara U200, Aqara U400, ULTRALOQ Bolt and Bolt Fingerprint (Matter).
- Support depends on the lock exposing users over Matter. Nuki keypad PINs, for example, are still a [feature request](https://developer.nuki.io/t/allow-keypad-pin-code-management-through-matter/39676).
- rivendell's HA has been at 2026.7.4 or later since the native migration (2026-08-01), so this is available now.

**The "HA PIN Code Management Gap" section above is superseded.** The per-lock question is now "does it expose PIN users over Matter?"

#### New and changed candidates

**Aqara U400 — new strongest candidate.** UWB hands-free unlock plus HomeKey tap, fingerprint, keypad and NFC card; Matter over Thread; rechargeable battery. Reviews are very strong — "probably the best smart lock from any company reviewed so far" ([HomeKit News](https://homekitnews.com/2026/02/10/aqara-smart-lock-u400-w-matter-over-thread-homekey-and-ultra-wideband/), [Tom's Guide](https://www.tomsguide.com/home/home-security/aqara-u400-review)). Named as working with HA's PIN management. Not checked: price, and whether any feature needs an Aqara hub.

**Aqara U200 / U300** are also Matter-over-Thread with HomeKey; the U300 is a lever set, useful for side or interior doors ([U300](https://us.aqara.com/products/smart-lock-u300), [U200](https://us.aqara.com/products/smart-lock-u200)). Aqara's U200 listing says it is "exclusively compatible with the Aqara M3 hub for optimal performance" — probably marketing, but confirm nothing HA needs is hub-gated. The March "Aqara U100 — bridge-only" row is about the older Zigbee U100 and still stands; it does not apply to Aqara's current native-Thread locks.

**Schlage Sense Pro — shipped 2026-06-29, not recommended.** UWB hands-free + HomeKey + Matter over Thread ([HomeKit News](https://homekitnews.com/2026/06/16/schlage-sense-pro-w-uwb-matter-and-thread-arrives-june-29th/)). Against it: $399, 4×AA, built-in 2.4 GHz Wi-Fi for the Schlage Home app's remote access, and on Matter platforms including HA "some capabilities remain unavailable or limited" — the advanced features favour Apple Home ([Gearbrain](https://www.gearbrain.com/schlage-sense-pro-review-2677668080.html)). Top price for features HA can't use.

**Level — demote.** HA community threads report Level locks failing to commission onto HA's Matter fabric, including locks that had worked before a Matter/Thread reset, with Level support saying they don't support Home Assistant ([HA forum](https://community.home-assistant.io/t/level-bolt-locks-failing-commissioning-on-my-matter-fabric/1013542), [HA forum](https://community.home-assistant.io/t/level-lock-matter-and-matter-setup-cant-get-working/945203)). An exterior door is no place for a lock whose vendor won't help with HA.

**ULTRALOQ Bolt — still hold.** HA community threads describe Matter pairing failures on the Bolt F and Bolt Mission, with no confirmed fix found ([HA forum](https://community.home-assistant.io/t/cannot-add-an-ultraloq-bolt-f-matter-device-to-home-assistant/945019), [HA forum](https://community.home-assistant.io/t/ultraloq-bolt-mission-wont-connect-via-matter/989312)). Once paired it is on the PIN-management list, but pairing is the problem. Thread commissioning failures are often the network or IPv6 rather than the lock, but that is unproven here.

Nuki and Yale were not re-checked in this pass.

#### Thread range matters more for a lock than for any sensor

An exterior door is at the edge of the house, locks are sleepy end devices that never route, and the mesh has one router (rivendell). Check the lock's link quality in `ot-ctl child table` during the return window, and plan a mains-powered Thread device near the door (see `smart-plugs.md`) if the link is marginal.

## Follow-ups

- [x] **2026-03-17** — Check if Schlage Sense Pro has shipped. Shipped 2026-06-29; $399 and limited features in HA. Not recommended.
- [ ] **2026-03-17** — Verify Yale Smart Lock with Matter availability and check HA community for integration reports before buying. Not re-checked 2026-09-13.
- [ ] **2026-03-17** — Check ULTRALOQ Bolt HA Matter pairing status. **2026-09-13:** pairing-failure threads, no confirmed fix. Next look 2027-03.
- [ ] **2026-09-13** — Shortlist: Aqara U400 (primary), Nuki Ultra (alternative). For the U400, check price and whether anything HA needs is hub-gated. For Nuki, check whether it now exposes PIN users over Matter.
- [ ] **2026-03-17** — When buying: test Matter pairing with the ZBT-2 border router on rivendell inside the return window. **Also check the lock's Thread link at the door** (`ot-ctl child table`) — the mesh has one router.
- [x] **2026-03-17** — Evaluate native HA PIN code management progress. Shipped in HA 2026.4 (beta at launch). Before relying on it for guests, confirm one-time codes actually expire on the chosen lock.

## Decision

*(Fill in when a purchase is made)*

- **Chosen device**:
- **Date purchased**:
- **Where purchased**:
- **Installation notes**:
- **HA integration**:
