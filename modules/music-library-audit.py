#!/usr/bin/env python3
"""Repair and report Lidarr artist folders that have drifted from the disk.

Lidarr derives an artist's folder from its canonical MusicBrainz name
(artistFolderFormat = {Artist Name}, with illegal characters substituted), which
is frequently not the folder a CD rip was copied into. When they disagree the
artist keeps working -- its track files were attached once by a Library Import --
but `artist.path` points at a directory that does not exist, and every subsequent
scan silently skips it. The only trace is a missing line in the log: a healthy
artist logs "Scanning /media/music/X" before "Completed scanning disk for X".

That is a permanent, silent hole: new albums ripped into that folder are never
seen again. 11 of 99 artists were in this state when this was written, e.g.
artist "AC/DC" pointing at /media/music/AC+DC while the files live in ACDC/.

So this does two things:

  * Repairs what it can prove. If an artist's path is missing but all of its
    track files sit under one folder, that folder is the artist's real home;
    repoint `path` there with moveFiles=false. No data moves and the operation
    is idempotent.

  * Reports what it cannot. Folders that belong to no artist need a Library
    Import, because Lidarr has no way to guess the MusicBrainz artist by itself.
    Artists with a missing path AND no track files cannot be inferred either --
    a same-name suggestion is offered but never applied, since attaching the
    wrong folder to an artist is far worse than leaving it broken.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SPEC = sys.argv[1]

with open(SPEC) as fh:
    spec = json.load(fh)

ROOT = spec["musicRoot"]
LIDARR = spec["lidarr"]
LROOT = LIDARR["lidarrRoot"]

changed, warnings = [], []


def http(url, method="GET", headers=None, data=None, timeout=60):
    req = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw and raw[:1] in b"[{" else raw


def to_host(p):
    """Translate a Lidarr path to the host's view of the same file."""
    rel = os.path.relpath(p.rstrip("/"), LROOT)
    return os.path.join(ROOT, rel)


def norm(s):
    """Loose key for *suggesting* a match. Never used to apply one."""
    return re.sub(r"[^a-z0-9]", "", s.lower())


with open(LIDARR["configPath"]) as fh:
    key = re.search(r"<ApiKey>([^<]+)</ApiKey>", fh.read()).group(1)
base = "http://127.0.0.1:%d/api/v1" % LIDARR["port"]
hdr = {"X-Api-Key": key, "Content-Type": "application/json"}

artists = http(base + "/artist", headers=hdr)
disk = sorted(d.name for d in os.scandir(ROOT) if d.is_dir(follow_symlinks=False))


# ------------------------------------------------------- repair missing paths
broken = [a for a in artists if not os.path.isdir(to_host(a["path"]))]
unresolved = []
repointed = []

for a in broken:
    files = http(base + "/trackfile?" + urllib.parse.urlencode({"artistId": a["id"]}),
                 headers=hdr)
    # The artist folder is whatever sits directly under the root, so take the
    # first path component rather than computing a common prefix -- that keeps a
    # stray file elsewhere in the tree from widening the answer to the root.
    tops = {os.path.relpath(f["path"], LROOT).split(os.sep, 1)[0] for f in files}
    tops = {t for t in tops if t not in (".", "..", os.sep)}

    if len(tops) != 1:
        unresolved.append((a, sorted(tops)))
        continue

    folder = tops.pop()
    want = os.path.join(LROOT, folder)
    body = dict(a)
    body["path"] = want
    # moveFiles=false: the files are already where they belong. This only
    # corrects Lidarr's idea of where that is.
    http("%s/artist/%d?moveFiles=false" % (base, a["id"]), "PUT", hdr,
         json.dumps(body).encode())
    repointed.append(folder)
    changed.append("repointed %r: %s -> %s" % (a["artistName"], a["path"], want))


# --------------------------------------------------------------- report gaps
owned = set(repointed)
for a in artists:
    p = a["path"].rstrip("/")
    if os.path.dirname(p) == LROOT:
        owned.add(os.path.basename(p))

orphan_dirs = [d for d in disk if d not in owned]
if orphan_dirs:
    warnings.append("%d folder(s) belong to no Lidarr artist (need Library Import): %s"
                    % (len(orphan_dirs), ", ".join(orphan_dirs)))

by_norm = {}
for d in orphan_dirs:
    by_norm.setdefault(norm(d), []).append(d)

for a, tops in unresolved:
    hint = by_norm.get(norm(a["artistName"]), [])
    detail = "%r has no folder and %s" % (
        a["artistName"],
        "no track files to infer one from" if not tops
        else "track files spread over %s" % ", ".join(tops),
    )
    if len(hint) == 1:
        detail += " -- did you mean %r? (not applied automatically)" % hint[0]
    warnings.append(detail)


# ---------------------------------------------------------------------- output
for line in changed:
    print(line)
for line in warnings:
    print("WARN " + line)
if not changed and not warnings:
    print("up to date: %d artists, %d folders, all paths resolve" % (len(artists), len(disk)))

if warnings and spec.get("ntfyUrl"):
    body = "%s\n\n%s" % (spec["host"], "\n\n".join(warnings))
    if changed:
        body += "\n\nAuto-repaired:\n" + "\n".join(changed)
    try:
        http(spec["ntfyUrl"], "POST",
             {"Title": "Lidarr music library needs attention",
              "Priority": "3", "Tags": "musical_note"},
             body.encode())
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        # Losing the notification should not fail the unit -- the findings are
        # already in the journal, and OnFailure would then alert about the
        # alerting rather than about the library.
        print("WARN could not reach ntfy: %s" % e, file=sys.stderr)
