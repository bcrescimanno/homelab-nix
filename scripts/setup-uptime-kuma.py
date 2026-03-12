#!/usr/bin/env python3
# scripts/setup-uptime-kuma.py — Restore Uptime Kuma configuration
#
# Recreates all monitors, the ntfy notification channel, and the status page
# from scratch. Idempotent — safe to re-run; skips anything that already exists.
#
# Requirements:
#   pip install uptime-kuma-api
#
# Usage:
#   python3 scripts/setup-uptime-kuma.py <password>
#
# Example:
#   python3 scripts/setup-uptime-kuma.py 'mypassword'
#
# Connects directly to the internal port (3001) to avoid NPM redirect issues.
# Run from the dev machine; rivendell must be reachable on the LAN.

import sys
from uptime_kuma_api import UptimeKumaApi, MonitorType, NotificationType

UPTIME_KUMA_URL = "http://rivendell:3001"  # internal port; Caddy proxies monitor.theshire.io → here
USERNAME = "brian"
PASSWORD = sys.argv[1] if len(sys.argv) > 1 else input("Uptime Kuma password: ")

NTFY_URL   = "https://ntfy.theshire.io"
NTFY_TOPIC = "homelab"

api = UptimeKumaApi(UPTIME_KUMA_URL)
api.login(USERNAME, PASSWORD)
print(f"Connected to Uptime Kuma {api.info()['version']}")

# ---------------------------------------------------------------------------
# Notification channel
# ---------------------------------------------------------------------------

existing_notifs = {n["name"]: n["id"] for n in api.get_notifications()}

if "Homelab alerts" in existing_notifs:
    print("Notification 'Homelab alerts' already exists, skipping.")
    notif_ids = [existing_notifs["Homelab alerts"]]
else:
    r = api.add_notification(
        name="Homelab alerts",
        type=NotificationType.NTFY,
        isDefault=True,
        applyExisting=True,
        ntfyServerUrl=NTFY_URL,
        ntfyTopic=NTFY_TOPIC,
        ntfyPriority=4,
    )
    notif_ids = [r["id"]]
    print(f"Created notification channel (id={r['id']})")

# ---------------------------------------------------------------------------
# Monitors
# ---------------------------------------------------------------------------

existing_monitors = {m["name"] for m in api.get_monitors()}

def add_http(name, url):
    if name in existing_monitors:
        print(f"  SKIP (exists): {name}")
        return
    api.add_monitor(
        type=MonitorType.HTTP,
        name=name,
        url=url,
        interval=60,
        notificationIDList=notif_ids,
    )
    print(f"  HTTP: {name} -> {url}")

def add_port(name, hostname, port=22):
    if name in existing_monitors:
        print(f"  SKIP (exists): {name}")
        return
    api.add_monitor(
        type=MonitorType.PORT,
        name=name,
        hostname=hostname,
        port=port,
        interval=60,
        notificationIDList=notif_ids,
    )
    print(f"  TCP:{port}: {name} -> {hostname}")

print("\nAdding monitors...")
add_http("Homepage",       "https://home.theshire.io")
add_http("Home Assistant", "https://ha.theshire.io")
add_http("Jellyfin",       "https://jellyfin.theshire.io")
add_http("Transmission",   "https://dl.theshire.io")
add_http("SABnzbd",        "https://sabnzbd.theshire.io")
add_http("Radarr",         "https://movies.theshire.io")
add_http("Sonarr",         "https://tv.theshire.io")
add_http("Prowlarr",       "https://prowlarr.theshire.io")
add_http("Lidarr",         "https://music.theshire.io")
add_http("Grafana",        "https://grafana.theshire.io")
add_http("ntfy",           "https://ntfy.theshire.io")
add_http("Uptime Kuma",    "https://monitor.theshire.io")
add_port("pirateship", "pirateship")
add_port("rivendell",  "rivendell")
add_port("mirkwood",   "mirkwood")

# ---------------------------------------------------------------------------
# Status page
# ---------------------------------------------------------------------------

# Re-fetch monitor IDs (may have just been created above)
all_monitors = {m["name"]: m["id"] for m in api.get_monitors()}

def ids(*names):
    return [{"id": all_monitors[n]} for n in names if n in all_monitors]

existing_pages = {p["slug"] for p in api.get_status_pages()}

if "homelab" in existing_pages:
    print("\nStatus page 'homelab' already exists, skipping.")
else:
    api.add_status_page("homelab", "The Shire")
    api.save_status_page(
        slug="homelab",
        title="The Shire",
        description="Homelab service status",
        theme="dark",
        published=True,
        showTags=False,
        domainNameList=[],
        customCSS="",
        footerText="theshire.io",
        showPoweredBy=True,
        publicGroupList=[
            {"name": "Infrastructure",   "monitorList": ids("pirateship", "rivendell", "mirkwood")},
            {"name": "Network & DNS",    "monitorList": ids("ntfy", "Uptime Kuma")},
            {"name": "Home",             "monitorList": ids("Homepage", "Home Assistant")},
            {"name": "Media",            "monitorList": ids("Jellyfin", "Transmission", "SABnzbd", "Radarr", "Sonarr", "Prowlarr", "Lidarr")},
            {"name": "Observability",    "monitorList": ids("Grafana")},
        ],
    )
    print("\nStatus page created: https://monitor.theshire.io/status/homelab")

api.disconnect()
print("\nDone.")
