#!/usr/bin/env python3
"""Sync declared custom formats and their profile scores into Lidarr.

Lidarr has no TRaSH guide and no Recyclarr support, so this plays the role
Recyclarr plays for Radarr/Sonarr: the desired state lives in Nix, this script
reconciles the running instance to it. Idempotent - a no-op run prints nothing
but "up to date".

Only formats named in the spec file are managed; anything else in Lidarr is
left alone, so hand-made formats survive.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request

SPEC = sys.argv[1] if len(sys.argv) > 1 else "/etc/lidarr-formats.json"
CONFIG = sys.argv[2] if len(sys.argv) > 2 else "/var/lib/lidarr/config/config.xml"
BASE = "http://localhost:8686/api/v1"

with open(SPEC) as fh:
    spec = json.load(fh)

with open(CONFIG) as fh:
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", fh.read())
if not m:
    sys.exit(f"no <ApiKey> found in {CONFIG}")
KEY = m.group(1)


def api(path, method="GET", body=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


# Lidarr may still be starting: the container comes up before the API binds.
for attempt in range(60):
    try:
        api("/system/status")
        break
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        time.sleep(2)
else:
    sys.exit("lidarr API did not become reachable within 120s")


def payload(fmt):
    return {
        "name": fmt["name"],
        "includeCustomFormatWhenRenaming": False,
        "specifications": [{
            "name": fmt["name"],
            "implementation": "ReleaseTitleSpecification",
            "implementationName": "Release Title",
            "negate": False,
            "required": False,
            # Lidarr rejects the object form the wiki shows for UI imports;
            # the REST API only accepts fields as a list of {name, value}.
            "fields": [{"name": "value", "value": fmt["regex"]}],
        }],
    }


def regex_of(cf):
    """Pull the configured regex back out of an existing custom format."""
    for s in cf.get("specifications") or []:
        f = s.get("fields")
        if isinstance(f, dict):
            return f.get("value")
        for field in f or []:
            if field.get("name") == "value":
                return field.get("value")
    return None


existing = {c["name"]: c for c in api("/customformat")}
changed = []

for fmt in spec["formats"]:
    cur = existing.get(fmt["name"])
    if cur is None:
        new = api("/customformat", "POST", payload(fmt))
        existing[fmt["name"]] = new
        changed.append(f"created  {fmt['name']}")
    elif regex_of(cur) != fmt["regex"]:
        body = payload(fmt)
        body["id"] = cur["id"]
        existing[fmt["name"]] = api(f"/customformat/{cur['id']}", "PUT", body)
        changed.append(f"updated  {fmt['name']}  regex -> {fmt['regex']}")

# Apply scores to the target quality profile.
profiles = api("/qualityprofile")
prof = next((p for p in profiles if p["name"] == spec["profile"]), None)
if prof is None:
    sys.exit(f"quality profile {spec['profile']!r} not found in Lidarr")

want_scores = {f["name"]: f["score"] for f in spec["formats"]}
have = {i["name"]: i for i in prof.get("formatItems") or []}

items = []
for name, cf in existing.items():
    if name in want_scores:
        items.append({"format": cf["id"], "name": name, "score": want_scores[name]})
    elif name in have:
        items.append(have[name])  # preserve scores for unmanaged formats

score_drift = any(have.get(n, {}).get("score") != s for n, s in want_scores.items())
min_drift = prof.get("minFormatScore") != spec["minFormatScore"]

if score_drift or min_drift or len(items) != len(prof.get("formatItems") or []):
    prof["formatItems"] = items
    prof["minFormatScore"] = spec["minFormatScore"]
    api(f"/qualityprofile/{prof['id']}", "PUT", prof)
    changed.append(f"profile  {spec['profile']}  scores applied, "
                   f"minFormatScore={spec['minFormatScore']}")

if changed:
    for line in changed:
        print(line)
else:
    print("up to date")
