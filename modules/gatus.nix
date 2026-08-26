# modules/gatus.nix — Gatus service health monitor
#
# Declarative replacement for Uptime Kuma. All monitors are defined here
# in Nix — no web UI, no SQLite state, no restore script needed.
#
# Alerts publish to ntfy (127.0.0.1:2586, the homelab topic).
# Using the internal address directly avoids a dependency on Caddy being up.
#
# Port layout:
#   8080 — Gatus web UI / status page (proxied via Caddy at monitor.theshire.io)

{ config, pkgs, lib, ... }:

let
  githubRepo = "bcrescimanno/homelab-nix";

  mkHttp = { name, url, group }: {
    inherit name url group;
    interval = "1m";
    conditions = [ "[STATUS] == 200" ];
    alerts = [{ type = "ntfy"; }];
  };

  mkTcp = { name, host, group }: {
    inherit name group;
    url = "tcp://${host}:22";
    interval = "1m";
    conditions = [ "[CONNECTED] == true" ];
    alerts = [{ type = "ntfy"; }];
  };

  # DNS resolution check — verifies the resolver can actually resolve, not just that port 53 is open.
  # Uses cloudflare.com as a canary: it's globally routable, always available, and not in any blocklist.
  mkDns = { name, host, group }: {
    inherit name group;
    url = "${host}:53";
    dns = {
      "query-name" = "cloudflare.com";
      "query-type" = "A";
    };
    interval = "1m";
    conditions = [ "[DNS_RCODE] == NOERROR" ];
    alerts = [{ type = "ntfy"; }];
  };

  # Ad-blocking canary — the only end-to-end test of whether blocking WORKS.
  #
  # Every other signal is a proxy. `blocky_denylist_cache_entries` counts what
  # was loaded, and on 2026-08-01 it counted 216113 entries while
  # pagead2.googlesyndication.com resolved perfectly happily: the list had
  # loaded, it just used bare entries, which Blocky 0.34 matches as exact names
  # only. Entry-count alerting is structurally incapable of catching that class
  # of bug. Asking the resolver the question a client would ask is.
  #
  # This catches, in one check: empty lists, wrong matching semantics, blocking
  # switched off, a bad upstream, and the service being down.
  #
  # For A queries Gatus puts the resolved address in [BODY] (client.QueryDNS,
  # `case dns.TypeA`), and Blocky answers a blocked name with 0.0.0.0 NOERROR
  # — verified against both resolvers rather than assumed.
  #
  # The canary is a subdomain on purpose: an apex would pass even under the
  # bare-entry bug that prompted this. Ad-serving hosts are subdomains, so the
  # test should be one too.
  mkAdBlockCanary = { name, host, group }: {
    inherit name group;
    url = "${host}:53";
    dns = {
      "query-name" = "pagead2.googlesyndication.com";
      "query-type" = "A";
    };
    interval = "5m";
    conditions = [
      "[DNS_RCODE] == NOERROR"
      "[BODY] == 0.0.0.0"
    ];
    alerts = [{ type = "ntfy"; }];
  };

  # Self-hosted CI runner liveness — asks GitHub, not the host.
  #
  # As of PR #609 the two pre-build jobs are REQUIRED status checks on main, so
  # a runner that GitHub cannot reach does not fail a merge — it stops merges
  # happening at all. Jobs queue against a runner that never arrives, Renovate's
  # container-digest automerges quietly stop landing, and nothing else in the
  # homelab notices: the runner is not a listening port, has no health endpoint,
  # and its absence looks exactly like "no PRs opened today".
  #
  # WHY THE API AND NOT THE UNIT. `systemctl is-active github-runner-*` would be
  # cheaper and needs no token, but it answers the wrong question. The runner
  # holds a long-poll connection out to GitHub; it can be `active` with an
  # expired credential, a revoked token, or a dead connection, and GitHub will
  # still report it offline and route nothing to it. `replace = true` means it
  # re-registers on every restart, so deregistration is a live failure mode too.
  # This asks the only party whose opinion decides whether a job runs.
  #
  # WHY ?name= AND NOT AN INDEX. The unfiltered endpoint returns both runners in
  # an array whose order GitHub does not document (it came back orthanc-first,
  # id 22 before id 21 — so not registration order and not id order). Gatus'
  # JSONPath is index-only: jsonpath.go runs strconv.Atoi on whatever is between
  # the brackets, so `runners[*]` returns nil and `runners[0]` would silently
  # monitor whichever runner GitHub felt like listing first. `?name=` narrows the
  # array to one element, which makes index 0 unambiguous.
  #
  # Verified against gatus 5.36.0 with synthetic bodies rather than assumed —
  # `runners[0]` on an empty array could plausibly have resolved to something
  # falsy-but-passing. Measured, per condition:
  #
  #   body                       total_count == 1   runners[0].status == online
  #   status:"online"            PASS               PASS            → healthy
  #   status:"offline"           PASS               FAIL (offline)  → caught
  #   total_count:0, runners:[]  FAIL (0)           FAIL (INVALID)  → caught
  #
  # So the offline case is caught only by the status condition, and the
  # deregistered case trips both. total_count is therefore redundant for
  # DETECTION and kept for DIAGNOSIS: Gatus reports the failing condition with
  # its resolved value, so the alert distinguishes "GitHub cannot reach it"
  # from "it is no longer registered" without anyone opening a browser.
  #
  # 5m × the default 3-failure threshold = ~15 min before alerting. That is
  # deliberate headroom: deploying to either host restarts its runner, and with
  # `replace = true` it briefly deregisters. A shorter threshold would alarm on
  # every deploy.
  #
  # BLIND SPOT, by construction: Gatus runs on rivendell, so it cannot alert on
  # rivendell's own runner while rivendell is down. That case is already covered
  # by the `rivendell` SSH check above — this one catches the narrower and far
  # more likely failure where the host is fine and only the runner is not.
  #
  # The token is expanded by Gatus itself, not Nix: config.go:287 runs
  # os.ExpandEnv over the whole config file after reading it, and the value
  # comes from environmentFile below. NB that ExpandEnv touches the ENTIRE
  # config — any literal `$` added anywhere in this file must be written `$$`
  # or it will be eaten. Nothing here contains one today.
  mkRunner = { name, runner, group }: {
    inherit name group;
    url = "https://api.github.com/repos/${githubRepo}/actions/runners?name=${runner}";
    headers = {
      "Accept"               = "application/vnd.github+json";
      "X-GitHub-Api-Version" = "2022-11-28";
      "Authorization"        = "Bearer \${GATUS_GITHUB_TOKEN}";
    };
    interval = "5m";
    conditions = [
      "[STATUS] == 200"
      "[BODY].total_count == 1"
      "[BODY].runners[0].status == online"
    ];
    alerts = [{ type = "ntfy"; }];
  };
in

{
  services.gatus = {
    enable = true;

    # Supplies GATUS_GITHUB_TOKEN for the CI runner checks. systemd reads
    # EnvironmentFile as root before dropping to gatus' DynamicUser, so the
    # sops default of 0400 root:root is exactly right here — do NOT set an
    # owner on that secret, the dynamic UID does not exist at activation.
    environmentFile = config.sops.secrets.gatus_github_token.path;

    settings = {
      web.port = 8080;

      alerting.ntfy = {
        url             = "http://127.0.0.1:2586";
        topic           = "homelab";
        priority        = 3;
        "default-alert" = {
          enabled             = true;
          "failure-threshold" = 3;
          "success-threshold" = 2;
        };
      };

      endpoints = [
        # Infrastructure — SSH reachability
        (mkTcp { name = "pirateship"; host = "pirateship"; group = "Infrastructure"; })
        (mkTcp { name = "rivendell";  host = "rivendell";  group = "Infrastructure"; })
        (mkTcp { name = "mirkwood";   host = "mirkwood";   group = "Infrastructure"; })
        (mkTcp { name = "orthanc";    host = "orthanc";    group = "Infrastructure"; })

        # DNS — resolution checks (port 53 open is not enough; verify actual recursive resolution)
        (mkDns { name = "mirkwood DNS"; host = "mirkwood"; group = "Infrastructure"; })
        (mkDns { name = "rivendell DNS"; host = "rivendell"; group = "Infrastructure"; })

        (mkAdBlockCanary { name = "mirkwood ad blocking";  host = "mirkwood";  group = "Infrastructure"; })
        (mkAdBlockCanary { name = "rivendell ad blocking"; host = "rivendell"; group = "Infrastructure"; })

        # CI — the merge gate depends on both of these being reachable by GitHub.
        (mkRunner { name = "CI runner — rivendell (aarch64)"; runner = "rivendell"; group = "CI"; })
        (mkRunner { name = "CI runner — orthanc (x86_64)";    runner = "orthanc";   group = "CI"; })

        # Home
        (mkHttp { name = "Homepage";       url = "https://homepage.theshire.io"; group = "Home"; })
        (mkHttp { name = "Home Assistant"; url = "https://ha.theshire.io";   group = "Home"; })

        # Media
        (mkHttp { name = "Jellyfin";    url = "https://jellyfin.theshire.io"; group = "Media"; })
        # TCP check on gluetun's control port. This is a LIVENESS check for the
        # container and nothing more — it is NOT a tunnel check, despite the name.
        # gluetun's control server listens on `:::8000` inside the netns and does
        # not touch tun0, so this stays green with the VPN completely down.
        # Measured 2026-08-02; the control server's status routes would answer the
        # real question but every one of them returns `Unauthorized` (gluetun now
        # requires an auth config, and /var/lib/gluetun/auth/config.toml is empty).
        #
        # Whether the tunnel is actually up, and whether anything is escaping it,
        # is answered by vpn-leak-check on pirateship — see modules/vpn-killswitch.nix
        # and the `vpn` alert group in modules/grafana.nix. Keep this check for what
        # it is good at: a direct LAN path that does not depend on Caddy or DNS.
        {
          name = "gluetun VPN";
          url = "tcp://pirateship:8000";
          group = "Media";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [{ type = "ntfy"; }];
        }
        (mkHttp { name = "qBittorrent";  url = "https://dl.theshire.io";      group = "Media"; })
        (mkHttp { name = "SABnzbd";     url = "https://nzb.theshire.io";      group = "Media"; })
        (mkHttp { name = "Radarr";      url = "https://movies.theshire.io";   group = "Media"; })
        (mkHttp { name = "Sonarr";      url = "https://tv.theshire.io";       group = "Media"; })
        (mkHttp { name = "Prowlarr";    url = "https://prowlarr.theshire.io"; group = "Media"; })
        (mkHttp { name = "Lidarr";      url = "https://music.theshire.io";    group = "Media"; })
        (mkHttp { name = "Music Assistant"; url = "https://listen.theshire.io"; group = "Media"; })

        # Gaming
        {
          name = "Minecraft — Prominence II";
          url = "tcp://orthanc:25565";
          group = "Gaming";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [{ type = "ntfy"; }];
        }
        {
          name = "Minecraft — Abyssal Ascent";
          url = "tcp://orthanc:25566";
          group = "Gaming";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [{ type = "ntfy"; }];
        }

        # Invidious — availability, then a real playback probe.
        #
        # The availability check alone is close to worthless here: the way this
        # service fails is companion's po_token going stale, after which the
        # unit stays active, every page still renders, and only the stream URLs
        # come back empty. That is the same "healthy while broken" shape as the
        # alertmanager /alert 404 and the NUT /metrics path. So the probe below
        # asserts on the streams themselves.
        (mkHttp { name = "Invidious"; url = "https://invidious.theshire.io"; group = "Media"; })
        {
          name = "Invidious playback";
          # Stable, not age- or region-restricted. If this video ever goes away
          # the monitor will false-alarm — swap the ID, don't weaken the
          # conditions.
          url = "https://invidious.theshire.io/api/v1/videos/dQw4w9WgXcQ";
          group = "Media";

          # MUST stay above 10 minutes. src/invidious/videos.cr:298-317 only
          # re-fetches from YouTube when the cached row is older than 10min;
          # anything faster is answered from the `videos` table and would pass
          # happily while live extraction is completely broken. 15m guarantees
          # every run exercises the real companion path. (On a failed refresh
          # Invidious deletes the cached row and re-raises, so there is no stale
          # fallback to mask it.)
          interval = "15m";

          # Verified with a NEGATIVE test against a video that returns 200 with
          # an empty body — [STATUS] PASSED while both body conditions FAILED
          # (`len([BODY].adaptiveFormats) (0) > 10`). A status-only check, i.e.
          # every other mkHttp in this file, calls that broken case healthy.
          conditions = [
            # Catches a hard failure: the API returns 500 + error_json when
            # fetch_video raises "Invidious companion is not available".
            "[STATUS] == 200"

            # Status is NOT sufficient on its own — see the negative test above.
            "len([BODY].adaptiveFormats) > 10"

            # The actual Piped failure signature, encoded: video streams present
            # but ZERO audio streams. A format list without any audio/* entry
            # means nothing can play, and that is exactly what a dead extractor
            # produces.
            "[BODY] == pat(*audio/*)"
          ];
          alerts = [{ type = "ntfy"; }];
        }

        # Observability
        (mkHttp { name = "Grafana";     url = "https://grafana.theshire.io";  group = "Observability"; })
        (mkHttp { name = "ntfy";        url = "https://ntfy.theshire.io";     group = "Observability"; })

        # Nix binary cache — functional probe via the standard nix-cache-info
        # endpoint. Asserts StoreDir is correct so signing key mismatches,
        # wrong cache name, and atticd config drift all surface as alerts.
        {
          name = "Nix Cache";
          url = "https://cache.theshire.io/nixpkgs/nix-cache-info";
          group = "Observability";
          interval = "5m";
          conditions = [
            "[STATUS] == 200"
            "[BODY] == pat(*nix/store*)"
          ];
          alerts = [{ type = "ntfy"; }];
        }
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];

  homelab.postUpgradeCheck.services = [ "gatus" ];
}
