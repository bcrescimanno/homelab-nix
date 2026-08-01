#!/usr/bin/env python3
"""Reconcile qBittorrent share limits and seeding priority against tracker class.

Two classes, keyed on the torrent's own `private` flag:

  private  -> ratio limit -1 (seed forever), action Stop, upload uncapped
  public   -> ratio limit N (default 1.0), action RemoveWithContent, upload capped

Idempotent: it compares current state and only calls the API for torrents that
actually differ, so a steady-state run issues zero writes.

Run with --dry-run to print the plan without touching anything.
"""
import json
import re
import sys
import urllib.parse
import urllib.request
import http.cookiejar

# Per-torrent share-limit sentinels: -2 "use global", -1 "no limit". ratioLimit
# is a float, but seedingTimeLimit and inactiveSeedingTimeLimit are integer
# MINUTES -- posting "-1.0" for those is rejected with HTTP 400.
NO_LIMIT = -1.0
NO_TIME_LIMIT = -1

# WebAPI >= 2.15 requires shareLimitAction on every setShareLimits call, and it
# is a STRING. Two traps, both verified against this build (qBittorrent 5.2.3):
#
#   1. Integers are accepted with HTTP 200 and silently coerced to "Default".
#   2. So is any unrecognised string -- "Pause" and "DeleteFiles" both return
#      200 and leave the torrent on "Default".
#
# So a typo here does not fail, it quietly falls back to the global action.
# apply_limits() therefore reads the value back and refuses to continue if it
# did not stick. Valid vocabulary, confirmed by round-trip:
ACTION_DEFAULT = "Default"
ACTION_STOP = "Stop"
ACTION_REMOVE = "Remove"
ACTION_REMOVE_WITH_CONTENT = "RemoveWithContent"
ACTION_SUPER_SEEDING = "EnableSuperSeeding"
VALID_ACTIONS = {ACTION_DEFAULT, ACTION_STOP, ACTION_REMOVE,
                 ACTION_REMOVE_WITH_CONTENT, ACTION_SUPER_SEEDING}

# Global max_ratio_act, read off this build's own WebUI markup:
#   0 Stop torrent   1 Remove torrent   3 Remove torrent and its files
#   2 Enable super seeding for torrent
# Note 3 and 2 are NOT in the order you would guess. We deliberately set the
# GLOBAL action to Stop and put deletion only on individually classified public
# torrents -- see the comment in the preferences block.
GLOBAL_ACT_STOP = 0


def log(msg):
    print(msg, flush=True)


class QBit:
    def __init__(self, base, username, password):
        self.base = base.rstrip("/")
        cj = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
        self.op.open(urllib.request.Request(
            self.base + "/api/v2/auth/login",
            data=urllib.parse.urlencode(
                {"username": username, "password": password}).encode(),
            headers={"Referer": self.base}), timeout=20)

    def get(self, path):
        return self.op.open(self.base + path, timeout=90).read().decode()

    def post(self, path, params):
        return self.op.open(urllib.request.Request(
            self.base + path,
            data=urllib.parse.urlencode(params).encode(),
            headers={"Referer": self.base}), timeout=90).read().decode()

    def torrents(self):
        return json.loads(self.get("/api/v2/torrents/info"))


def approx(a, b):
    if a is None or b is None:
        return False
    return abs(float(a) - float(b)) < 1e-6


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    spec = json.load(open(args[0]))

    creds = open(spec["credentialsFile"]).read()
    user = re.search(r"QBT_USERNAME=(.*)", creds).group(1).strip()
    pw = re.search(r"QBT_PASSWORD=(.*)", creds).group(1).strip()

    public_ratio = float(spec["publicRatio"])
    public_up_limit = int(spec["publicUploadLimitBytes"])

    qb = QBit(spec["url"], user, pw)
    log("qBittorrent %s (api %s)%s" % (qb.get("/api/v2/app/version"),
                                       qb.get("/api/v2/app/webapiVersion"),
                                       "  [DRY RUN]" if dry else ""))

    torrents = qb.torrents()

    # ---------------------------------------------------------------- safety
    # Everything below hangs off `private`. If the field is missing -- an older
    # WebAPI, or a build that dropped it -- every Redacted torrent would fall
    # through to the public branch and be deleted with its content at ratio 1.0.
    # Refuse the whole run rather than risk that: seeding too long is
    # recoverable, a deleted private torrent and the ratio hit is not.
    unknown = [t for t in torrents if not isinstance(t.get("private"), bool)]
    if unknown:
        log("FATAL: %d/%d torrents have no boolean `private` field; refusing to "
            "apply any policy. First: %r" % (len(unknown), len(torrents),
                                             unknown[0].get("name", "?")[:60]))
        return 1

    private = [t for t in torrents if t["private"]]
    public = [t for t in torrents if not t["private"]]
    log("torrents: %d total  %d private  %d public"
        % (len(torrents), len(private), len(public)))

    # ----------------------------------------------------------- preferences
    prefs = json.loads(qb.get("/api/v2/app/preferences"))
    want = {
        # The GLOBAL action is the one that applies to torrents this unit has
        # not classified yet -- a fresh grab sits at the -2 "use global"
        # sentinel with action Default until the next run. Stop keeps that
        # default harmless; deletion is attached per-torrent, only to torrents
        # positively identified as public.
        "max_ratio_act": GLOBAL_ACT_STOP,
        # Deliberately OFF, for the same reason: with a global ratio limit
        # enabled, anything still on the -2 sentinel inherits it. Off means the
        # unclassified default is "seed forever", so this service dying costs
        # disk space rather than a wiped private torrent.
        "max_ratio_enabled": False,
    }
    delta = {k: v for k, v in want.items() if prefs.get(k) != v}
    if delta:
        log("preferences: %d change(s)" % len(delta))
        for k, v in sorted(delta.items()):
            log("    %-22s %s -> %s" % (k, prefs.get(k), v))
        if not dry:
            qb.post("/api/v2/app/setPreferences", {"json": json.dumps(delta)})
    else:
        log("preferences: already correct")

    # --------------------------------------------------------- share limits
    classes = (
        ("private", private, NO_LIMIT, ACTION_STOP),
        ("public", public, public_ratio, ACTION_REMOVE_WITH_CONTENT),
    )

    def needs(t, ratio, action):
        return not (approx(t.get("ratio_limit"), ratio)
                    and approx(t.get("seeding_time_limit"), NO_TIME_LIMIT)
                    and approx(t.get("inactive_seeding_time_limit"), NO_TIME_LIMIT)
                    and t.get("share_limit_action") == action)

    changed = 0
    applied = []
    for label, group, ratio, action in classes:
        assert action in VALID_ACTIONS, "bad action %r" % action
        stale = [t for t in group if needs(t, ratio, action)]
        if not stale:
            log("%s share limits: all %d already ratio=%s action=%s"
                % (label, len(group), ratio, action))
            continue
        log("%s share limits: updating %d/%d to ratio=%s action=%s"
            % (label, len(stale), len(group), ratio, action))
        for t in stale[:8]:
            log("    %-48s ratio %s->%s  action %s->%s"
                % (t["name"][:48], t.get("ratio_limit"), ratio,
                   t.get("share_limit_action"), action))
        if len(stale) > 8:
            log("    ... and %d more" % (len(stale) - 8))
        changed += len(stale)
        if not dry:
            # Batched: one call per class, not per torrent.
            qb.post("/api/v2/torrents/setShareLimits", {
                "hashes": "|".join(t["hash"] for t in stale),
                "ratioLimit": ratio,
                "seedingTimeLimit": NO_TIME_LIMIT,
                "inactiveSeedingTimeLimit": NO_TIME_LIMIT,
                "shareLimitAction": action,
            })
            applied.append((label, {t["hash"] for t in stale}, ratio, action))

    # Read back, because an unrecognised action is a silent no-op (see above).
    if applied:
        after = {t["hash"]: t for t in qb.torrents()}
        bad = 0
        for label, hashes, ratio, action in applied:
            for h in hashes:
                t = after.get(h)
                if t is None:
                    continue  # removed in the meantime; fine
                if needs(t, ratio, action):
                    bad += 1
                    if bad <= 5:
                        log("VERIFY FAIL [%s] %-40s ratio=%s action=%s"
                            % (label, t["name"][:40], t.get("ratio_limit"),
                               t.get("share_limit_action")))
        if bad:
            log("FATAL: %d torrent(s) did not take the requested share limits" % bad)
            return 1
        log("verified: all %d updated torrent(s) read back correctly"
            % sum(len(h) for _, h, _, _ in applied))

    # -------------------------------------------------------------- priority
    # qBittorrent has no notion of "prefer this tracker", and the obvious lever
    # -- the upload queue -- does not exist for seeders. MEASURED on this build:
    # with max_active_uploads forced to 1 and three torrents actively uploading,
    # not one seeding torrent was ever given a queue position over 60s; only the
    # single *downloading* torrent had one. qBittorrent keeps finished torrents
    # out of the queue, so `priority` is 0 for every seeder and topPrio has
    # nothing to order. Do not reintroduce a queue-position scheme here without
    # re-running that test -- and note that observing "no positions" while
    # nothing is contending proves nothing, which is why the test forces the cap
    # to 1 first.
    #
    # What is left is bandwidth. Capping non-private torrents leaves headroom
    # that private ones can always claim. It is an approximation, not a
    # guarantee: N public torrents can still add up. The tradeoff is deliberate
    # -- a throttled public torrent takes longer to reach 1.0 and so lingers
    # longer before removal.
    priv_uncapped = [t for t in private if (t.get("up_limit") or 0) != 0]
    pub_uncapped = [t for t in public if (t.get("up_limit") or 0) != public_up_limit]

    if priv_uncapped:
        log("upload limits: lifting cap on %d private torrent(s)" % len(priv_uncapped))
        changed += len(priv_uncapped)
        if not dry:
            qb.post("/api/v2/torrents/setUploadLimit", {
                "hashes": "|".join(t["hash"] for t in priv_uncapped), "limit": 0})
    else:
        log("upload limits: all %d private torrents uncapped" % len(private))

    if pub_uncapped:
        log("upload limits: capping %d public torrent(s) at %d B/s"
            % (len(pub_uncapped), public_up_limit))
        changed += len(pub_uncapped)
        if not dry:
            qb.post("/api/v2/torrents/setUploadLimit", {
                "hashes": "|".join(t["hash"] for t in pub_uncapped),
                "limit": public_up_limit})
    else:
        log("upload limits: all %d public torrents already at %d B/s"
            % (len(public), public_up_limit))

    log("done: %d change(s)%s"
        % (changed, " (dry run, nothing applied)" if dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
