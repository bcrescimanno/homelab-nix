#!/usr/bin/env python3
"""Alert when a PR that is supposed to merge itself cannot.

Every Renovate PR in this repo sets automerge (renovate.json: lockFileMaintenance,
the nix packageRule, and the container-digest packageRule all do), so an open
Renovate PR is always either in flight or wedged. Nothing noticed the difference
until now.

WHAT WENT WRONG THAT THIS CATCHES
---------------------------------
2026-08-29: the Saturday lockFileMaintenance PR (#627) opened 22:14 PDT with
automerge armed. Its aarch64 gate failed 47s later — our own alertmanager elm
overlay had gone redundant, so a --replace-fail found nothing to replace. The PR
sat blocked. The 04:02-05:01 nightly upgrade then ran on all four hosts, in full
health, and deployed the same lock as the day before. Every existing signal was
green: upgrade success, backups fine, Gatus fine, and flake-freshness had nothing
to say because it only alarms at 10 days behind.

The gap is narrow and specific: between a PR failing to merge and the running
inputs being *provably* stale there is a week and a half of silence. This closes
that with the direct question — is anything armed to merge unable to?

WHY NOT AGE ALONE
-----------------
The tempting version is "alert if an automerge PR is open more than N hours".
That has to pick an N above a legitimate build, and renovate.json records the
measurement: a real nixpkgs bump costs 42 min on rivendell's aarch64 runner. Any
N safely above that is also above the ~5h46m a Saturday lock PR has between
opening and the nightly upgrade window, so an age-only rule would have reported
#627 *after* the hosts had already missed it.

So age is the backstop, not the signal. The signal is state:

  failing check   a required check concluded failure/timed_out/cancelled/
                  action_required. Terminal — automerge will never fire. This
                  is #627, and it is knowable within the hour.
  conflict        mergeable_state == dirty. Also terminal.
  no checks       automerge armed but not one check run exists on the head SHA
                  after CHECKS_GRACE_MIN. Distinct from "slow": a queued job
                  still has a check run, in state queued. This means the
                  workflow never triggered at all.
  not armed       an open Renovate PR with NO automerge request. Renovate is
                  configured to arm every PR it opens, so this means the arming
                  itself failed, which is invisible in exactly the same way.
  stalled         armed, nothing diagnosably wrong, still open past STALE_HOURS.

UNKNOWN IS NOT CLEAN
--------------------
Inherited verbatim from modules/flake-freshness.nix, which exists because
nixpkgs-watch.nix swallowed a 302 and reported success for months. Here: the PR
list failing to fetch, a per-PR fetch failing, and GitHub's asynchronously
computed `mergeable` coming back null are each reported as UNKNOWN and never
folded into "nothing stuck". A run that learned nothing exits non-zero so
OnFailure fires; it does not print an all-clear.

The repo is public, so this reads the API unauthenticated — no token to expire
or rotate, one less silent failure mode. That costs a 60 req/hr per-IP limit,
which an hourly run using 1 + one-per-open-PR requests does not approach. A 403
from the rate limiter is treated as UNKNOWN, not as an empty PR list.

STATE
-----
Alerting every hour about the same wedged PR would train the alert into
wallpaper, so each (pr, head_sha, reason) is announced once. A rebase moves the
head SHA and is genuinely new, so it re-announces. When a tracked PR merges or
closes, a low-priority note says so and the state is dropped — a stuck alert you
never see resolve is one you stop believing.
"""

import calendar
import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = os.environ.get("PR_WATCH_REPO", "bcrescimanno/homelab-nix")
NTFY_URL = os.environ.get("PR_WATCH_NTFY", "")
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/pr-automerge-watch")

# Above renovate.json's measured 42-min aarch64 lock build, with room for one
# PR to queue behind another, but low enough to still beat the 04:00 upgrade.
STALE_HOURS = 4
# A queued run already has a check run, so this only trips when nothing was
# created at all. Generous anyway: workflow dispatch is not instant.
CHECKS_GRACE_MIN = 60

FAILED_CONCLUSIONS = {"failure", "timed_out", "cancelled", "action_required"}
API = "https://api.github.com"


class Unknown(Exception):
    """The check could not determine an answer. Never an all-clear."""


def get(path):
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "homelab-pr-automerge-watch",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        # 403/429 here is the rate limiter, which must not read as "no PRs".
        raise Unknown(f"GET {path} -> HTTP {e.code}") from e
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        raise Unknown(f"GET {path} -> {e}") from e


def age_minutes(iso):
    # timegm, not mktime: GitHub timestamps are UTC and mktime would read them
    # as local. time.timezone does not account for DST either, so the naive fix
    # is an hour wrong for half the year on a PDT host.
    t = calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    return (time.time() - t) / 60


def is_renovate(pr):
    login = (pr.get("user") or {}).get("login", "")
    return login.startswith("renovate")


def diagnose(pr):
    """Return (reason_key, human_text) or None if the PR is fine.

    Raises Unknown if this PR's state could not be established.
    """
    num = pr["number"]
    armed = pr.get("auto_merge") is not None
    mins = age_minutes(pr["created_at"])

    if not armed:
        # Renovate arms every PR it opens here; a human PR is not this job's
        # business, so only flag the bot's.
        if is_renovate(pr) and mins > CHECKS_GRACE_MIN:
            return ("not-armed", "opened by Renovate but automerge was never armed")
        return None

    runs = get(f"/repos/{REPO}/commits/{pr['head']['sha']}/check-runs?per_page=100")
    check_runs = runs.get("check_runs")
    if check_runs is None:
        raise Unknown(f"#{num}: check-runs response had no check_runs key")

    failed = sorted(
        r["name"] for r in check_runs if r.get("conclusion") in FAILED_CONCLUSIONS
    )
    if failed:
        return ("failed-check", f"required check failed: {', '.join(failed)}")

    if not check_runs and mins > CHECKS_GRACE_MIN:
        return (
            "no-checks",
            f"no check run exists {int(mins)}m after opening — the workflow never triggered",
        )

    # mergeable_state is computed asynchronously and is absent from the list
    # endpoint, so it needs the single-PR fetch. "unknown" means GitHub has not
    # finished; that is not evidence of health.
    detail = get(f"/repos/{REPO}/pulls/{num}")
    state = detail.get("mergeable_state")
    if state == "dirty":
        return ("conflict", "merge conflict — automerge cannot fire")

    if mins > STALE_HOURS * 60:
        if state in (None, "unknown"):
            raise Unknown(f"#{num}: open {int(mins/60)}h, mergeable_state still unknown")
        return (
            "stalled",
            f"armed but still open after {int(mins / 60)}h (mergeable_state={state})",
        )

    return None


def notify(title, priority, tags, body):
    if not NTFY_URL:
        print(f"[ntfy skipped] {title}: {body}")
        return True
    req = urllib.request.Request(
        NTFY_URL,
        data=body.encode(),
        headers={"Title": title, "Priority": str(priority), "Tags": tags},
    )
    try:
        urllib.request.urlopen(req, timeout=30).close()
        return True
    except (urllib.error.URLError, TimeoutError) as e:
        # A push we could not deliver must not look like a push we did not need
        # to send (#620). But it must ALSO not fail this unit: ntfy restarts
        # during a deploy, and a timer-driven oneshot that fails inside the
        # activation window makes switch-to-configuration exit non-zero, which
        # trips deploy-rs autoRollback. That is not hypothetical — it is exactly
        # how unbound-health-check rolled back the 2026-08-29 deploy.
        #
        # So: report false, and the caller declines to record the alert as
        # announced. The finding is retried next run rather than lost or fatal.
        print(f"ntfy delivery FAILED for {title!r}: {e}", file=sys.stderr)
        return False


# A run that learned nothing is not an all-clear — but neither is one blip a
# reason to fail the unit. A timer-driven oneshot that fails inside a deploy's
# activation window makes switch-to-configuration exit non-zero and trips
# deploy-rs autoRollback; on 2026-08-29 unbound-health-check did exactly that
# and rolled back a good deploy because ntfy was mid-restart. GitHub being
# briefly unreachable is the same shape of non-event.
#
# So an unknown run is counted, not swallowed: it logs, and only once the
# blindness PERSISTS does the unit fail and OnFailure fire. Three consecutive
# hourly runs is far longer than any activation window and still same-morning.
UNKNOWN_STREAK_LIMIT = 3


def _streak_file():
    return os.path.join(STATE_DIR, "unknown-streak")


def clear_unknown_streak():
    try:
        os.remove(_streak_file())
    except FileNotFoundError:
        pass


def escalate_unknown(detail):
    """Record an inconclusive run. Return the process exit code."""
    try:
        with open(_streak_file()) as f:
            n = int(f.read().strip() or 0)
    except (FileNotFoundError, ValueError):
        n = 0
    n += 1
    with open(_streak_file(), "w") as f:
        f.write(str(n))

    if n < UNKNOWN_STREAK_LIMIT:
        print(
            f"INCONCLUSIVE run {n}/{UNKNOWN_STREAK_LIMIT} (not yet alerting): {detail}",
            file=sys.stderr,
        )
        return 0

    notify(
        "PR automerge watch is blind",
        3,
        "warning",
        f"{n} consecutive runs could not determine whether any automerge PR is "
        f"stuck, so automerge health is UNKNOWN — not confirmed fine. {detail}",
    )
    return 1


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    unknowns = []

    try:
        prs = get(f"/repos/{REPO}/pulls?state=open&per_page=100")
    except Unknown as e:
        # Nothing at all is known this run.
        print(f"could not list PRs: {e}", file=sys.stderr)
        return escalate_unknown(f"could not list open PRs for {REPO}: {e}")

    open_numbers = set()
    stuck = []

    for pr in prs:
        num = pr["number"]
        open_numbers.add(num)
        try:
            verdict = diagnose(pr)
        except Unknown as e:
            unknowns.append(str(e))
            continue

        statefile = os.path.join(STATE_DIR, f"pr-{num}")
        if verdict is None:
            # Healthy now. If it had been reported stuck, close the loop.
            if os.path.exists(statefile):
                os.remove(statefile)
            continue

        reason, text = verdict
        stuck.append(f"#{num} {reason}")
        marker = f"{pr['head']['sha']}:{reason}"
        prior = None
        if os.path.exists(statefile):
            with open(statefile) as f:
                prior = f.read().strip()
        if prior == marker:
            continue  # already announced this exact state

        if notify(
            "PR automerge is stuck",
            4,
            "rotating_light",
            f"{REPO} #{num} ({pr['title']}) will not merge on its own: {text}. "
            f"https://github.com/{REPO}/pull/{num}",
        ):
            with open(statefile, "w") as f:
                f.write(marker)

    # Anything we had flagged that is no longer open got resolved somehow.
    for name in os.listdir(STATE_DIR):
        if not name.startswith("pr-"):
            continue
        num = int(name[3:])
        if num in open_numbers:
            continue
        if notify(
            "PR automerge unstuck",
            2,
            "white_check_mark",
            f"{REPO} #{num} is no longer open — the stuck automerge cleared.",
        ):
            os.remove(os.path.join(STATE_DIR, name))

    print(
        f"checked {len(prs)} open PRs; stuck:{','.join(stuck) or 'none'}; "
        f"unknown:{'; '.join(unknowns) or 'none'}"
    )
    if unknowns:
        return escalate_unknown("; ".join(unknowns))
    clear_unknown_streak()
    return 0


if __name__ == "__main__":
    sys.exit(main())
