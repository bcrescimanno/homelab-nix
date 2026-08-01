#!/usr/bin/env python3
"""Refresh Music Assistant artists whose metadata is missing but already stamped.

MA ships a daily "Scan missing artist metadata" task, and it cannot fix these.
Its query is

    (no images OR no description) AND last_refresh IS NULL

so the moment an artist is refreshed once, it is excluded forever -- even if the
refresh returned nothing and the artist still has no image and no biography.
121 of 221 library artists were in exactly that state when this was written,
stamped back in March and April, and the task completed in 2.9s finding zero
work to do. (Compare the equivalent playlist task, which correctly uses
`last_refresh < now - REFRESH_INTERVAL`. The artist query looks like an
oversight.)

Nothing else fills the gap on its own: MA fetches metadata lazily when you open
an artist page, which is why the library looks half-populated -- whatever you
have browsed to has data and the rest does not.

`_update_artist_metadata` guards only on REFRESH_INTERVAL (90 days), so these
artists are perfectly eligible; nobody ever asks. This asks, in bounded batches
so the backlog drains over a few days rather than hammering MusicBrainz,
TheAudioDB and fanart.tv in one burst. Once drained it is a no-op.
"""
import json
import sys
import time
import urllib.error
import urllib.request

SPEC = sys.argv[1]

with open(SPEC) as fh:
    spec = json.load(fh)

URL = spec["url"]
LIMIT = spec["batchSize"]
with open(spec["tokenFile"]) as fh:
    TOKEN = fh.read().strip()
HDR = {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}


def cmd(command, args=None, timeout=120):
    body = json.dumps({"command": command, "message_id": "backfill", "args": args or {}})
    req = urllib.request.Request(URL + "/api", method="POST", data=body.encode(), headers=HDR)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def incomplete(item):
    m = item.get("metadata") or {}
    return not (m.get("images") or []) or m.get("description") is None


artists = cmd("music/artists/library_items", {"limit": 5000})
if isinstance(artists, dict):
    artists = artists.get("items", artists.get("result", []))

stuck = [a for a in artists if incomplete(a)]
if not stuck:
    print("up to date: %d artists, all have images and a description" % len(artists))
    sys.exit(0)

batch = stuck[:LIMIT]
print("%d/%d artists missing metadata; refreshing %d this run"
      % (len(stuck), len(artists), len(batch)))

fixed = unchanged = failed = 0
for a in batch:
    name = a.get("name") or "?"
    uri = a.get("uri") or "library://artist/%s" % a.get("item_id")
    before = a.get("metadata") or {}
    try:
        res = cmd("metadata/update_metadata", {"item": uri})
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        print("  FAIL    %-34s %s" % (name[:34], e))
        failed += 1
        continue
    after = (res or {}).get("metadata") or {}
    gained_images = len(after.get("images") or []) - len(before.get("images") or [])
    gained_desc = bool(after.get("description")) and not bool(before.get("description"))
    if gained_images > 0 or gained_desc:
        fixed += 1
        print("  updated %-34s%s%s" % (
            name[:34],
            " +%d images" % gained_images if gained_images > 0 else "",
            " +description" if gained_desc else ""))
    else:
        # Genuinely absent upstream (obscure or non-Latin-script artists are the
        # usual case). Nothing to do about it; it will be retried next run, which
        # is cheap because the providers answer from cache.
        unchanged += 1
    time.sleep(1)

print("updated=%d no-data=%d failed=%d remaining=%d"
      % (fixed, unchanged, failed, len(stuck) - len(batch)))

# Deliberately exit 0 when providers simply had nothing: that is not a fault and
# should not trip OnFailure. A transport failure is.
if failed and not fixed:
    sys.exit("every refresh in this batch failed to reach Music Assistant")
