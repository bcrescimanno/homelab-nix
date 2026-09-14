# Cameras & NVR

## Context

- **Current setup**: None — starting fresh
- **Goal**: Outdoor/indoor security cameras with local recording, AI detection, Home Assistant integration, and ideally HomeKit
- **Existing ecosystem**: UDM Pro at 10.0.1.1 — UniFi Protect is natively available; IoT VLAN 4 (10.0.12.0/22) for device isolation
- **Infrastructure**: Three Raspberry Pi 5 hosts; comfortable with container management via NixOS

## Selection Criteria

Cameras are a special category — Matter 1.5 (November 2025) finally defined camera device types, but no certified hardware exists yet as of early 2026. The standard Matter-first preference is moot here: evaluate on local operation, HA integration quality, and ecosystem fit instead.

Additional camera-specific criteria:
- **NVR**: local recording required — no cloud-subscription recording (Ring, Nest, Arlo disqualified)
- **PoE strongly preferred**: reliable power delivery, no Wi-Fi congestion, easier installation
- **AI detection**: person/vehicle/animal detection a must; should not require a cloud subscription
- **Remote access**: usable remotely without exposing raw RTSP to the internet

## Research

### 2026-03-18

Sources: UI store, iFeeltech, Evan McCann's Protect comparison charts, The Hook Up NVR comparison and Reolink tier list, Home Assistant blog, Frigate docs, Hailo/frigate.video, CSA announcement, FCC coverage.

#### Matter 1.5 Camera Spec

Matter 1.5 shipped November 20, 2025 and **finally defined camera device types** (Camera, Floodlight Camera, Video Doorbell, Intercom, Snapshot Camera, etc.) with live streaming via WebRTC, PTZ control, and detection zones. However, as of early 2026, **zero production cameras are Matter 1.5 certified** — the spec is brand new and the certification pipeline takes months. Neither UniFi nor Reolink has announced a timeline. Treat Matter cameras as a "watch this space for 2026–2027" development; not actionable today.

---

#### NVR Options

Two main paths:

| NVR | Approach | AI | HA integration | Remote access | Maintenance |
|---|---|---|---|---|---|
| **UniFi Protect** | Closed ecosystem NVR built into UDM Pro or UNVR | Native, per-camera (or AI Port for third-party) | Good, some rough patches | Excellent (cloud relay) | Low — appliance |
| **Frigate** | Open-source container, RTSP/ONVIF from any camera | Local via Hailo/Coral, per-zone, per-class | Excellent — deep HA entity integration | Slow for remote clips (~25s) | Medium — containers + Hailo drivers |

**UniFi Protect NVR storage note**: The base UDM Pro has a single 3.5" HDD bay — workable for a handful of cameras but not ideal. For a larger deployment:
- **UNVR** (~$299): Dedicated 4-bay NVR; recommended add-on to existing UDM Pro
- **UDM Pro Max** (~$500+): 2-bay + 128GB NVMe for AI clips; if replacing UDM Pro anyway

#### Camera Candidates

| Device | Price | Protocol | Local | HomeKit | HA | Notes |
|---|---|---|---|---|---|---|
| **UniFi G6 Bullet** | $199 | PoE (802.3af) | Full | Via Homebridge | Good | 4K/8MP, 1/1.8" sensor, IP66, current gen |
| **UniFi G6 Turret** | $199 | PoE | Full | Via Homebridge | Good | 4K, 3-axis mount, same sensor as Bullet |
| **UniFi G6 Dome** | $279 | PoE | Full | Via Homebridge | Good | 4K, IK10 vandal-resistant |
| **UniFi G6 PTZ** | $399 | PoE | Full | Via Homebridge | Good | 4K + 10× hybrid zoom, active tracking |
| **UniFi AI Doorbell** | ~$199 | PoE | Full | Via Homebridge | Good | Dual-camera, integrated display, AI |
| **UniFi G5 Turret Ultra** | $129 | PoE | Full | Via Homebridge | Good | 2K, previous gen, cheaper entry point |
| **Reolink RLC-810A** | ~$55 | PoE | Full | Via Scrypted | Platinum | 4K/8MP bullet, person/vehicle/pet AI |
| **Reolink RLC-820A** | ~$65 | PoE | Full | Via Scrypted | Platinum | 4K turret variant of above |
| **Reolink PoE Doorbell** | ~$78 | PoE | Full | Via Scrypted | Platinum | 4K, among best value PoE doorbells |
| **Annke C800** | ~$80 | PoE | Full | Via Scrypted | Via ONVIF | NDAA-compliant ONVIF, good Frigate candidate |
| **Logitech Circle View Wired** | ~$200 | PoE | Full | **Native HKSV** | Moderate | Only mainstream PoE camera with native HomeKit Secure Video |

#### UniFi Protect — Full Assessment

**Strengths:**
- Best-in-class mobile app: polished, low-latency live view, timeline scrubbing
- No subscription for local recording or AI detection
- Already in the ecosystem — UDM Pro has Protect built in, cameras auto-discover
- AI detection (person, vehicle, animal, package, face, license plate) native on G5/G6
- AI Port add-on ($?) brings AI to third-party ONVIF cameras in Protect 5.0
- Protect 5.0 added ONVIF third-party camera ingestion (beta, 24/7 recording only — no motion/AI without AI Port)
- Remote access via UniFi cloud is fast and doesn't require port forwarding

**Weaknesses:**
- Camera cost premium: G6 Bullet @ $199 vs Reolink @ $55 for similar specs. A 6-camera UniFi deployment = ~$1,200–$1,500 in cameras
- No native HomeKit — requires Homebridge + `homebridge-unifi-protect` plugin (well-maintained, supports full HKSV)
- HA integration has had breaking changes (2025.1, 2025.8); requires owner-level API token
- Third-party ONVIF cameras in Protect: recording works, AI does not without paid AI Port per camera
- Local notification latency: ~5.3s (benchmark by The Hook Up)

**HA integration quality**: Good. Local (RTSP streams + WebSocket events). Exposes motion, person detection, cameras as media entities. Has had breaking changes but is actively maintained. Install via Settings → Devices & Services.

**HomeKit**: Via Homebridge `homebridge-unifi-protect` plugin. Supports HomeKit Secure Video. Add a Homebridge container to rivendell.

#### Frigate NVR — Full Assessment

Open-source NVR container. Consumes RTSP/ONVIF from any camera. AI detection via Hailo-8/8L (recommended 2025+) or Coral TPU (deprecated).

**Key advantage for this setup**: Hailo AI HAT+ (~$70–$110) plugs into the RPi 5 PCIe slot (same connector as M.2 HAT). A dedicated RPi 5 running Frigate + Hailo gives fully local AI detection for any number of RTSP cameras.

**HA integration**: Excellent. Every detection (per-camera, per-zone, per-object-class) becomes a native HA entity. Clip URLs as entity state. Fine-grained automation triggers.

**Local notification latency**: ~2.9s (benchmark by The Hook Up) — faster than Protect.

**Remote clip access**: Slow (~25–30s over cellular). UniFi Protect wins significantly here.

**HomeKit Secure Video**: Not native. Path: Scrypted container (bridges Frigate motion events → HKSV). Direct RTSP-to-HKSV causes a conflict where HKSV stops detecting motion if Frigate is also consuming the stream; Scrypted as the sole RTSP consumer resolves this. Works, but it's two extra layers (Frigate + Scrypted).

**Maintenance**: Container updates, Hailo driver compatibility, per-camera RTSP URL config, zone tuning. More than Protect but well within the comfort zone of this homelab.

#### Core Trade-off: UniFi Protect vs. Reolink + Frigate

| Factor | UniFi Protect | Reolink + Frigate |
|---|---|---|
| Camera cost (6-cam) | ~$1,200–$1,500 | ~$330–$500 |
| AI detection quality | Excellent (native) | Excellent (Hailo on RPi 5) |
| HA integration | Good, some friction | Excellent (Reolink Platinum + Frigate) |
| Mobile/remote UI | Best-in-class | Functional, not polished |
| Remote clips (cellular) | Fast (cloud relay) | Slow (~25s) |
| Local notification speed | ~5.3s | ~2.9s |
| HomeKit Secure Video | Via Homebridge | Via Scrypted (more complex) |
| Maintenance burden | Low (appliance) | Medium (containers, drivers) |
| Vendor lock-in | Medium-high | Low |
| Setup complexity | Low | Medium-high |
| Matter (future) | Not announced | Not announced |

**The honest summary**: UniFi Protect buys polish and convenience; Reolink + Frigate buys cost savings and HA depth. Both are fully local.

#### What to Avoid

| Device/Brand | Reason |
|---|---|
| **Hikvision / Dahua** | On FCC Covered List; importation of new models prohibited in the US since 2022–2023. History of firmware backdoors and critical CVEs. Avoid. |
| **Amcrest** | Functionally a Dahua OEM — same concerns apply. |
| **Ring / Nest / Arlo** | Cloud-required recording subscription. No local NVR. Deal-breaker. |
| **Wyze** | Wi-Fi only, cloud-dependent, history of security incidents. |
| **Google Coral TPU** | Still supported in Frigate but officially deprioritized; stock issues for years. Use Hailo instead for new Frigate deployments. |
| **UniFi G6 Instant** | Wi-Fi only (no PoE). Fine if you need wireless, but defeats one of Protect's main advantages. |

---

#### Hybrid Path Worth Considering

UniFi Protect 5.0 added ONVIF ingestion. This opens a middle path:
- Use **UniFi cameras for high-priority spots** (front door, driveway) where Protect's UI and remote access matter most
- Use **Reolink PoE for secondary angles** — ingest into Protect via ONVIF for unified 24/7 recording and timeline view
- Run **Frigate against the Reolink cameras** in parallel for deep HA automation triggers (Protect's ONVIF ingestion has no AI; Frigate provides it)
- Add **AI Port** per Reolink camera only if Protect's AI on those cameras matters (at extra cost per camera)

This maximizes budget efficiency while keeping Protect's mobile UX and remote access for the cameras you look at most.

### 2026-09-13

**The first Matter 1.5 camera shipped, but HA can't use it as a Matter camera yet.** Aqara Camera Hub G350 ($139.99, Matter 1.5 certified 2026-02-10): dual-lens 4K, PTZ, with a built-in Zigbee hub and Thread border router ([Derek Seaman](https://www.derekseaman.com/2026/03/aqara-camera-hub-g350-worlds-first-matter-v1-5-camera.html)). As of mid-2026 HA does not create normal camera entities for a Matter 1.5 camera; PTZ works in the Open Home Foundation Matter Server, but the practical HA video path is still RTSP ([Tara Home, 2026-07](https://tarahome.ai/blog/matter-1-5-cameras-home-assistant-aqara-g350/)). It is an indoor Wi-Fi PTZ camera, not a PoE outdoor camera, so it changes nothing above.

If one is ever bought: its built-in Thread border router would run a Thread network of its own. Don't let it become part of our Thread setup by accident.

**Matter cameras: still not actionable here.** Recheck when HA release notes mention Matter camera entities.

**Frigate + Hailo on a Pi 5 works, with driver care.** Frigate supports Hailo-8 and Hailo-8L on the Pi 5; the 0.18 betas add a Hailo-10H detector. On Raspberry Pi OS Bookworm the kernel's bundled Hailo driver is incompatible with Frigate and must be replaced; on Trixie it installs via DKMS ([Frigate hardware docs](https://docs.frigate.video/frigate/hardware/), [Jeff Geerling, 2026](https://www.jeffgeerling.com/blog/2026/frigate-with-hailo-for-object-detection-on-a-raspberry-pi/)). These hosts run NixOS, not Raspberry Pi OS, so the driver would have to be built as an out-of-tree module against our `nixos-raspberrypi` kernel. Budget for that before choosing Frigate on a Pi; orthanc (x86) is the simpler Frigate host.

**Not re-checked in this pass:** UniFi Protect camera lineup and prices, Reolink models and prices, AI Port. Refresh the camera table before buying.

## Follow-ups

- [ ] 2026-03-18 — Verify UDM Pro storage adequacy: how many cameras + what retention with current HDD? May need UNVR.
- [ ] 2026-03-18 — Decide on NVR strategy before buying cameras (Protect-only vs. Frigate hybrid)
- [x] 2026-Q3 — Check for first Matter 1.5 certified cameras. Checked 2026-09-13: Aqara G350 is certified (indoor, Wi-Fi), but HA has no Matter camera entities yet. No compelling PoE Matter option. Recheck when HA ships Matter camera support.
- [ ] 2026-03-18 — If Frigate path: evaluate a dedicated RPi 5 with a Hailo HAT+ vs. rivendell (8GB) with a Hailo HAT+ vs. orthanc. **2026-09-13:** the Hailo driver is out-of-tree and would need building for the NixOS Pi kernel; factor that into the Pi options.
- [ ] 2026-09-13 — Before buying: refresh the UniFi and Reolink model and price tables (not re-checked since March).

## Decision

*(Fill in when a purchase is made)*

- **Chosen device**:
- **Date purchased**:
- **Where purchased**:
- **Installation notes**:
- **HA integration**:
