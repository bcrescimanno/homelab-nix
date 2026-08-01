#!/usr/bin/env python3
"""Trigger targeted library rescans when the music tree changes.

Every filesystem watcher on /var/lib/media/music is inert: the share is NFS from
erebor and the writers are elsewhere (an arr container on pirateship, or a CD rip
copied straight onto the NAS), so inotify never delivers events. Lidarr's
RootFolderWatchingService, Navidrome's scanner watcher and Music Assistant all
end up relying on their own schedules -- 1 day, 1 hour and 12 hours respectively.

This replaces that with change detection cheap enough to run every two minutes:
stat the directories (not the files) and compare mtimes. Any file added, removed
or renamed bumps its parent directory's mtime, so ~278 stats cover a 2000-track
library in well under a second.

Nothing is scanned while the library is idle. When something does change, only
the artists that actually changed are refreshed.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

SPEC = sys.argv[1]

with open(SPEC) as fh:
    spec = json.load(fh)

ROOT = spec["musicRoot"]
STATE = spec["statePath"]
notes = []


def http(url, method="GET", headers=None, data=None, timeout=30):
    req = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw and raw[:1] in b"[{" else raw


def fingerprint():
    """Map every directory under ROOT to its mtime.

    Directories only. A track file's own mtime is irrelevant -- what matters is
    whether the set of files changed, and that always shows up as a bump on the
    containing directory. Tag edits in place are the one thing this misses; those
    come from Lidarr, which rescans the artist itself as part of the edit.
    """
    out = {}
    stack = [ROOT]
    while stack:
        d = stack.pop()
        try:
            st = os.stat(d)
            entries = list(os.scandir(d))
        except (FileNotFoundError, NotADirectoryError, PermissionError):
            # Raced with a write, or vanished mid-walk. Skipping it means this
            # pass records a different fingerprint than the next one will, which
            # just defers the trigger by one tick -- exactly what we want while
            # the tree is still moving.
            continue
        out[os.path.relpath(d, ROOT)] = st.st_mtime_ns
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
            except OSError:
                continue
    return out


def load_state():
    try:
        with open(STATE) as fh:
            s = json.load(fh)
        return s.get("pending") or {}, s.get("synced") or {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}, {}


def save_state(pending, synced):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"pending": pending, "synced": synced}, fh)
    os.replace(tmp, STATE)


# ------------------------------------------------------------------ detection
cur = fingerprint()
if not cur:
    sys.exit("music root %r is empty or unreadable -- refusing to act on it" % ROOT)

pending, synced = load_state()

if not pending and not synced:
    # First run. Adopt the current tree as the baseline instead of treating all
    # 99 artists as changed; anything added before this point is picked up by
    # music-library-audit and Lidarr's own daily rescan.
    save_state(cur, cur)
    print("baseline recorded (%d dirs)" % len(cur))
    sys.exit(0)

if cur != pending:
    # Something is moving. Wait for it to settle rather than scanning a
    # half-copied album -- this debounce is the reason the timer is short.
    save_state(cur, synced)
    print("change detected, waiting for the tree to settle")
    sys.exit(0)

if cur == synced:
    print("no change")
    sys.exit(0)

# Stable for a full interval and different from what we last synced.
changed_top = set()
for path in set(cur) | set(synced):
    if cur.get(path) == synced.get(path):
        continue
    top = path.split(os.sep, 1)[0]
    if top != ".":
        changed_top.add(top)

print("settled; changed top-level dirs: %s" % (sorted(changed_top) or "(root only)"))


# --------------------------------------------------------------------- lidarr
def sync_lidarr(cfg):
    with open(cfg["configPath"]) as fh:
        key = re.search(r"<ApiKey>([^<]+)</ApiKey>", fh.read()).group(1)
    base = "http://127.0.0.1:%d/api/v1" % cfg["port"]
    hdr = {"X-Api-Key": key, "Content-Type": "application/json"}

    artists = http(base + "/artist", headers=hdr)
    # Lidarr sees the share at a different prefix: the container bind-mounts
    # /var/lib/media at /media, so its artist paths read /media/music/<Artist>.
    by_name = {}
    for a in artists:
        p = a["path"].rstrip("/")
        if os.path.dirname(p) == cfg["lidarrRoot"]:
            by_name[os.path.basename(p)] = a

    hit, miss = [], []
    for name in sorted(changed_top):
        a = by_name.get(name)
        if a is None:
            miss.append(name)
            continue
        # RefreshArtist, not RescanArtist. RescanArtist only scans disk, and a
        # freshly ripped album that Lidarr's DB has no release for cannot be
        # attached to anything -- the album entity comes from MusicBrainz on
        # refresh. mediamanagement has rescanAfterRefresh=always, so a refresh
        # rescans the disk too. This only fires for artists that changed.
        http(base + "/command", "POST", hdr,
             json.dumps({"name": "RefreshArtist", "artistId": a["id"]}).encode())
        hit.append(a["artistName"])

    if hit:
        notes.append("lidarr  refreshed %d artist(s): %s" % (len(hit), ", ".join(hit)))
    if miss:
        # Not an error. Lidarr cannot adopt a folder on its own -- it has no way
        # to guess the MusicBrainz artist -- so these need a Library Import.
        # music-library-audit is what nags about them.
        notes.append("lidarr  %d changed dir(s) belong to no artist: %s"
                     % (len(miss), ", ".join(miss)))


# ------------------------------------------------------------ music assistant
# Navidrome is deliberately absent here. Its own quick scan is already an mtime
# walk that finishes in under a second, so it just needed a shorter schedule
# (see modules/navidrome.nix) rather than a push: 0.63.2 does not advertise the
# apiKeyAuthentication OpenSubsonic extension, so triggering it over the API
# would mean storing a user's password to save a couple of minutes.
def sync_music_assistant(cfg):
    with open(cfg["tokenFile"]) as fh:
        token = fh.read().strip()
    # providers is deliberately omitted so every provider syncs. The filesystem
    # one is incremental (it compares a per-file mtime checksum) and the rest are
    # builtin and finish in milliseconds.
    http(cfg["url"] + "/api", "POST",
         {"Authorization": "Bearer " + token, "Content-Type": "application/json"},
         json.dumps({"command": "music/sync", "message_id": "music-sync", "args": {}}).encode())
    notes.append("mass    triggered music/sync")


failed = []
for label, fn, cfg in (
    ("lidarr", sync_lidarr, spec.get("lidarr")),
    ("music-assistant", sync_music_assistant, spec.get("musicAssistant")),
):
    if not cfg:
        continue
    try:
        fn(cfg)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError) as e:
        failed.append("%s: %s" % (label, e))

print("\n".join(notes) if notes else "nothing to do")

if failed:
    # Leave `synced` alone so the next tick retries. `pending` is already `cur`,
    # so a retry fires immediately rather than waiting for another change.
    save_state(cur, synced)
    sys.exit("failed to notify: %s" % "; ".join(failed))

save_state(cur, cur)
