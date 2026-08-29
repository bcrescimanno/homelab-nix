# modules/flake-freshness.nix — alert when the inputs we are BUILDING FROM go stale
#
# The blind spot this closes: every existing freshness signal proves a job RAN,
# not that it had anything new to do. Through the 26 days flake.lock sat frozen
# (01 Aug → 25 Aug 2026) the nightly upgrade ran every night, succeeded every
# night, stamped /var/lib/homelab-freshness every night, and rebuilt the
# identical closure every night. Backups green, upgrades green, Gatus green.
# Nothing anywhere was capable of saying "you have not actually updated in
# three weeks."
#
# -----------------------------------------------------------------------------
# IT MEASURES WHAT IS RUNNING, NOT WHAT IS COMMITTED
#
# The input revisions are read from flake.lock at EVAL time and baked into the
# script below. That is not a shortcut around fetching them at runtime — it is
# the point. These values come from the flake that built THIS system, so the
# check cannot be fooled by a lock that has moved on main while a host failed to
# deploy. If rivendell is running a fortnight-old closure, this says so, even
# though main is current.
#
# Reading flake.lock also means the owner/repo/ref for each input come from the
# lock itself rather than a hand-maintained table here, so adding or repointing
# an input cannot leave this module quietly checking the wrong branch.
#
# -----------------------------------------------------------------------------
# WHY IT COMPARES REVISIONS AND NOT JUST AGE
#
# Age alone false-alarms on slow-moving inputs. disko's lock entry was two
# months old on 2026-08-26 and perfectly current — upstream simply had not
# committed since 2026-06-10. So an input is only stale if its locked rev
# DIFFERS from upstream's branch head; only then does age mean anything.
#
# -----------------------------------------------------------------------------
# A FETCH FAILURE IS NOT AN ALL-CLEAR
#
# This module replaced modules/nixpkgs-watch.nix, which had never once executed
# its logic: it fetched a 302 URL with `curl -sf` and no -L, got an empty body
# with exit 0, and its own `[ -z "$REV" ] && exit 0` guard swallowed that. The
# unit reported success daily for months while checking nothing.
#
# So every fetch here uses -L, and unreachable inputs are counted and REPORTED
# rather than skipped. If GitHub is unreachable for all of them the check says
# that out loud instead of finishing quietly, because "I could not find out"
# and "everything is fine" must never look the same again.
#
# Deliberately NOT gated on "and a lock PR has been open >48h", which is how
# this was first sketched. That AND would miss the failure where Renovate stops
# opening PRs at all — no PR, no alarm, indefinitely. Staleness of the running
# inputs is the direct question and catches every route to it: automerge broken,
# a PR blocked on a hash mismatch, Renovate's cron dead, or a host that stopped
# deploying.
#
# What it does NOT give is speed, and that is the tradeoff, not an oversight.
# Ten days is right for "are the running inputs stale" and useless for catching
# a single blocked lock PR before the next nightly upgrade. On 2026-08-29 #627
# was blocked at 22:15 PDT and the hosts rebuilt the old lock at 04:02; this
# check would have said so on 2026-09-08. modules/pr-automerge-watch.nix asks
# the narrow, hourly version of the question — is anything armed to merge unable
# to — and the two are complements: it is blind to Renovate never opening a PR,
# which is exactly what this one sees.

{ config, pkgs, lib, ... }:

let
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host = config.networking.hostName;

  # Alert once an input is this far behind. Twice the intended Tue/Sat lock
  # cadence plus slack, so a single skipped window is not an alarm but a
  # genuinely wedged pipeline is.
  maxAgeDays = 10;

  lock = builtins.fromJSON (builtins.readFile ../flake.lock);

  # Direct inputs only. Transitive ones move when their parent moves and are not
  # independently actionable, so alarming on them would be noise nobody can fix.
  trackedInputs = lib.mapAttrs (_name: node: {
    inherit (lock.nodes.${node}.locked) rev lastModified;
    owner = lock.nodes.${node}.original.owner or "";
    repo  = lock.nodes.${node}.original.repo or "";
    ref   = lock.nodes.${node}.original.ref or "";
  }) lock.nodes.root.inputs;

  inputsJson = pkgs.writeText "tracked-inputs.json" (builtins.toJSON trackedInputs);
in

{
  systemd.services.flake-freshness-check = {
    description = "Check that the flake inputs this system was built from are current";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "10m";
    };
    script = ''
      set -uo pipefail
      export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils ]}:$PATH"

      NOW=$(date +%s)
      STALE=""
      UNREACHABLE=""
      CHECKED=0

      # `sha=` selects the branch; omitting it uses the repo's default branch,
      # which is exactly right for the inputs pinned without an explicit ref.
      for name in $(jq -r 'keys[]' ${inputsJson}); do
        owner=$(jq -r --arg n "$name" '.[$n].owner' ${inputsJson})
        repo=$(jq -r  --arg n "$name" '.[$n].repo'  ${inputsJson})
        ref=$(jq -r   --arg n "$name" '.[$n].ref'   ${inputsJson})
        rev=$(jq -r   --arg n "$name" '.[$n].rev'   ${inputsJson})
        lm=$(jq -r    --arg n "$name" '.[$n].lastModified' ${inputsJson})

        [ -n "$owner" ] && [ -n "$repo" ] || continue
        CHECKED=$((CHECKED + 1))

        url="https://api.github.com/repos/$owner/$repo/commits?per_page=1"
        [ -n "$ref" ] && url="$url&sha=$ref"

        # -L is load-bearing; see the header. -f so a 4xx/5xx is a failure
        # rather than an empty body that parses as "no news".
        head_rev=$(curl -sfL --connect-timeout 10 --max-time 30 \
          -H "Accept: application/vnd.github+json" "$url" \
          | jq -r '.[0].sha // empty' 2>/dev/null)

        if [ -z "$head_rev" ]; then
          UNREACHABLE="$UNREACHABLE $name"
          continue
        fi

        # Current: our rev IS upstream's head, whatever its age.
        [ "$head_rev" = "$rev" ] && continue

        age_days=$(( (NOW - lm) / 86400 ))
        if [ "$age_days" -gt ${toString maxAgeDays} ]; then
          STALE="$STALE $name(''${age_days}d)"
        fi
      done

      if [ -n "$STALE" ]; then
        curl -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors \
          -H "Title: Flake inputs are stale" \
          -H "Priority: 4" \
          -H "Tags: rotating_light" \
          -d "${host} is running inputs more than ${toString maxAgeDays} days behind upstream:$STALE. Every other check stays green in this state — lock automerge or the deploy chain is wedged." \
          ${ntfyUrl}
        echo "stale:$STALE" >&2
      fi

      # Total unreachability means the check learned nothing. Saying so is the
      # entire lesson of the module this replaced.
      if [ -n "$UNREACHABLE" ] && [ "$CHECKED" -gt 0 ]; then
        n_unreachable=$(echo $UNREACHABLE | wc -w)
        if [ "$n_unreachable" -eq "$CHECKED" ]; then
          curl -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors \
            -H "Title: Flake freshness check could not run" \
            -H "Priority: 3" \
            -H "Tags: warning" \
            -d "${host} could not reach GitHub for any of $CHECKED inputs, so input staleness is UNKNOWN — not confirmed fine." \
            ${ntfyUrl}
        fi
        echo "unreachable:$UNREACHABLE" >&2
      fi

      echo "checked $CHECKED inputs; stale:''${STALE:-none}; unreachable:''${UNREACHABLE:-none}"
    '';
  };

  systemd.timers.flake-freshness-check = {
    description = "Daily flake input freshness check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # After the 04:00–05:00 upgrade window, so it judges today's closure.
      OnCalendar = "09:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
