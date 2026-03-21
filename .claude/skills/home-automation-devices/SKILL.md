---
name: home-automation-devices
description: This skill should be used when the user asks about home automation devices, smart home hardware, sensors, switches, bulbs, locks, thermostats, plugs, presence detection, cameras, doorbells, or any connected home device. Provides recommendations based on defined selection criteria prioritizing Matter, Thread, local control, and HomeKit/Home Assistant compatibility.
version: 1.1.0
---

# Home Automation Device Advisor

This skill governs how to evaluate and recommend home automation devices. Apply all criteria below consistently. Never recommend a device that fails a hard requirement, and always surface trade-offs when a device only partially meets a criterion.

---

## Agent Behavior

### Web Search Authorization

Web searches are a core part of device research. **Never ask permission before performing web searches.** Search proactively and liberally — checking manufacturer pages, HA community forums, Reddit (r/homeassistant, r/homekit, r/smarthome), and tech reviews is expected and required for accurate recommendations. The Matter/Thread ecosystem moves fast; always verify current status from recent sources.

### Check Existing Documentation First

Before researching a device category, **always check `devices/` in the repo root for an existing file covering that category** (e.g., `devices/thermostats.md`, `devices/switches-dimmers.md`). If a file exists:
- Use it as the baseline — do not re-research what is already documented
- Note the research date(s) and consider whether the information may be stale (>6 months old in this fast-moving ecosystem warrants a re-check)
- Extend the existing file rather than replacing it

If no file exists for the category, create one using the template at `devices/_template.md`.

### Auto-Document All Recommendations

**Whenever making device recommendations, write or update the corresponding `devices/<category>.md` file.** This is not optional — documentation is part of completing the task.

- Use `devices/_template.md` as the structure guide
- Follow the format established in existing files (see `devices/thermostats.md` and `devices/switches-dimmers.md` as canonical examples)
- Include the research date, a candidates table, what-to-avoid section, follow-up items, and a decision section
- If updating an existing file, append a new dated Research section rather than overwriting prior research

---

## Selection Criteria

Apply these in priority order. Higher criteria override lower ones.

### 1. Matter protocol preferred (highest priority)

Always prefer devices that implement the Matter protocol. Matter provides:
- Interoperability across ecosystems without bridges
- Local control by design
- Native HomeKit and Home Assistant support via the Matter integration
- Future-proofing as the industry converges on it

If a Matter device exists for the use case, it should be the default recommendation unless a specific trade-off justifies otherwise. Always note whether a device is Matter-certified or only Matter-planned/roadmap.

### 2. Thread preferred over Wi-Fi; battery devices must not use Wi-Fi

**Thread** is the preferred radio for devices that need a mesh network (sensors, locks, buttons, etc.):
- Low power, mesh routing, no Wi-Fi congestion
- Works with the Thread border router on rivendell (Home Assistant Connect ZBT-2, pending setup)

**Wi-Fi** is acceptable for mains-powered devices where Thread is not available, but flag the trade-offs (network congestion, router association limits, higher power draw).

**Hard rule**: Any device running on user-replaceable batteries (AA, AAA, CR2032, etc.) must not use Wi-Fi. Recommend Thread, Zigbee, or Z-Wave for battery-powered devices. No exceptions.

Zigbee and Z-Wave are acceptable fallbacks when Matter/Thread is not available — they support local control and work well with Home Assistant. Note they require a coordinator hub.

### 3. Local-only operation strongly preferred

Prefer devices that operate entirely on the local network with no cloud dependency:
- **Fully local**: ideal — all control, automation, and status works without internet
- **Cloud for updates only**: acceptable — if the cloud is used solely for firmware/OTA updates and all runtime operation is local, this is a reasonable trade-off. Flag it explicitly so the user knows.
- **Cloud required for operation**: avoid — if the device requires a cloud service for basic function (on/off, status, automations), do not recommend it as a primary option. If it's the only option for a niche use case, present it with a clear warning and note any local-only alternatives or workarounds (e.g., custom firmware like Tasmota/ESPHome).

### 4. Must work with HomeKit or Home Assistant (preferably both)

Every recommended device must have confirmed, working integration with at least one of:
- **Apple HomeKit** — native HomeKit certification or via Matter
- **Home Assistant** — native integration, Matter, Zigbee/Z-Wave via coordinator, or community integration

Prefer devices that work with **both**. Matter devices inherently satisfy both. For non-Matter devices, verify the integration is well-maintained and not dependent on a cloud API that could be revoked.

### 5. Avoid proprietary ecosystems unless uniquely justified

Proprietary ecosystems (e.g., Lutron Caseta/RA3, Aqara hub-only, Samsung SmartThings, Philips Hue bridge-required) should be avoided unless:
- The ecosystem offers a specific capability not available elsewhere (e.g., Lutron's reliability and neutral-wire-free dimming)
- The device has a supported bridge/integration that doesn't compromise local control
- The trade-off is explicitly acknowledged

When recommending a proprietary device, state the specific benefit and whether it can be migrated away from in the future.

### 6. UniFi devices always considered as an option

UniFi Protect (cameras, doorbells, access control) and UniFi networking devices should always be surfaced as an option when relevant, even if they don't meet criteria 1–5 strictly:
- UniFi integrates with Home Assistant via the UniFi Protect integration
- Offers tight network-level visibility and control (device isolation, VLAN assignment)
- Cloud dependency: UniFi can operate fully locally with a self-hosted controller (already the case with this homelab's UDM Pro)

UniFi should not be the only recommendation — always present it alongside other options that meet the criteria more fully. Note that UniFi's HA integration requires the Protect application and may have feature gaps compared to native Matter/Thread devices.

---

## Recommendation Format

When recommending devices, structure the response as follows:

1. **Primary recommendation**: best device(s) that meet the most criteria, with a brief rationale
2. **Alternatives**: other options with trade-offs clearly stated
3. **UniFi option**: surface the UniFi equivalent if one exists, even if it's not the top pick
4. **What to avoid**: flag any popular devices in the category that fail the criteria (e.g., cloud-required, Wi-Fi battery devices), so the user knows what not to buy
5. **Open questions**: note anything that depends on the user's specific situation (e.g., neutral wire availability, existing hub, Thread border router status)

---

## Homelab Context

- **Home Assistant** runs on rivendell (10.0.1.9) as a container with host networking and `--privileged` for USB access
- **Matter Server** is already running on rivendell alongside HA
- **Thread border router**: Home Assistant Connect ZBT-2 ordered but not yet set up — Thread devices will work once OTBR is configured on rivendell
- **Zigbee**: no coordinator currently configured — Zigbee devices would need a coordinator added before they work
- **Z-Wave**: no controller currently configured
- **IoT VLAN**: VLAN 4 (`10.0.12.0/22`) exists on rivendell — new IoT devices should be placed on this VLAN for network isolation
- **UniFi controller**: UDM Pro at 10.0.1.1 manages the network; UniFi Protect available if UniFi cameras/doorbells are deployed

---

## Research Guidance

When researching specific devices or categories:
- Check the [Works with Matter](https://www.apple.com/home-app/accessories/) directory and the Matter product database for certified devices
- Check the Home Assistant integrations directory for integration quality and local vs. cloud status
- Prefer community sources that are recent (within the last 12 months) — the Matter/Thread ecosystem is evolving rapidly and older reviews may reflect pre-Matter firmware
- If a device claims "Matter support coming", treat it as Wi-Fi/cloud until Matter is actually shipping
- Search without asking for permission — web searches are always pre-authorized for this skill
