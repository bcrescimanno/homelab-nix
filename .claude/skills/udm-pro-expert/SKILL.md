---
name: udm-pro-expert
description: This skill should be used when the user asks about UniFi, UDM Pro, UniFi Network, UniFi switches, UniFi access points, UniFi console, network configuration, VLANs, firewall rules, routing, DHCP, DNS, traffic rules, or anything related to the UniFi ecosystem. Provides expert guidance while accounting for UniFi's rapidly changing management UI and network software versions.
version: 1.0.0
---

# UniFi Dream Machine Pro Expert

UniFi Network's management interface changes significantly across releases. Menus move, features are renamed, and workflows are restructured. Treat all prior knowledge — including your own training data and community resources — as potentially outdated until verified against the user's running version.

## Version Verification Protocol

### When to trigger

Trigger this protocol the moment the user says any of the following:
- The UI doesn't look like you described
- A menu, option, or setting isn't where you said it would be
- A feature name doesn't match
- "I don't see that"
- Any indication that your instructions don't match what they're seeing

### Step 1: Get the running version

Ask the user for their UniFi Network version. It is found at:
> **UniFi Network → Settings → System → Application Configuration → Version**

Or it may appear in the footer of the Settings page depending on the release.

Record the full version string (e.g. `8.4.59`, `9.0.114`).

### Step 2: Establish the release date

Use web search to find the official UniFi Network release notes for that version:
- Search: `site:community.ui.com "UniFi Network" "<version>" release`
- Or: `site:ui.com UniFi Network "<version>" release notes`

Identify the release date. This becomes your **trust cutoff date**.

### Step 3: Source filtering rules

Apply these rules to all community sources (Reddit, UI Community forums, YouTube, blog posts, etc.):

| Source type | Trust if… |
|---|---|
| Community post/thread | Published on or after the trust cutoff date |
| Community post/thread | Explicitly references the running version or a newer one |
| Official UI documentation | Always prefer; treat as authoritative for the running version |
| Official release notes | Always authoritative |
| Older community source | Discard or explicitly flag as potentially outdated |

When citing a source, note its date and whether it meets the trust criteria. If you cannot verify a source's date, treat it as suspect and say so.

### Step 4: Rebuild the answer

Re-research the question using only trusted sources. If official docs cover the topic, lead with that. Supplement with qualifying community sources. If no trusted sources exist yet (e.g. a very recent release), say so explicitly and offer to reason from first principles or adjacent release notes.

## General Guidance Principles

### UI navigation changes to watch for

UniFi frequently restructures navigation across major releases. Common patterns:
- Features move between **Settings → Network**, **Settings → Routing**, **Settings → Security**, and **Settings → Profiles**
- "Traffic Rules" and "Firewall Rules" have been split, merged, and renamed across releases
- VLAN configuration has moved between Network creation flow and standalone interfaces
- The distinction between "New UI" and "Classic Settings" (legacy) may still affect some installs

Always confirm which UI generation the user is on if navigation instructions are failing.

### Homelab integration context

This homelab uses the UDM Pro (`10.0.1.1`) as:
- Default gateway and primary router
- DHCP server for the main LAN
- DNS upstream for Blocky's `.theshire.io` conditional forwarding
- UniFi switch and AP controller
- IoT VLAN (VLAN 4, `10.0.12.0/22`) management

When proposing changes that touch DNS, DHCP, VLANs, or firewall rules, cross-reference impact on:
- Blocky+Unbound DNS on rivendell (10.0.1.9) and mirkwood — changes to upstream DNS or VLAN routing may affect resolution
- Home Assistant on rivendell — relies on IoT VLAN access and mDNS
- NFS mounts from erebor (10.0.1.22) to pirateship — sensitive to routing changes

### When proposing firewall or traffic rules

- State whether the rule belongs in **LAN In / LAN Out / LAN Local** (or the equivalent in the user's UI version)
- Note the order sensitivity — UniFi evaluates rules top-down; placement matters
- Prefer traffic rules over raw firewall rules where the UI offers both, as traffic rules are less likely to be broken by UI version changes

## Research Workflow

When researching a UniFi question:

1. Start with official sources: `unifi.ui.com` docs, `help.ui.com`, and the UI Community release notes thread for the running version
2. Search community sources and filter by date/version before trusting them
3. If the answer requires web UI navigation, verify the path matches the running version before presenting it
4. If uncertain, present the answer with explicit confidence level and source dates
