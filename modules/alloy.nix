# modules/alloy.nix — Grafana Alloy, the log shipper. Runs on every host.
#
# Ships the systemd journal to Loki on orthanc (modules/loki.nix). Blocky's
# query log is added by the same module on the DNS pair, gated on
# services.blocky.enable, because that is the only place the file exists.
#
# ALLOY IS A LOG SHIPPER HERE AND NOTHING ELSE. It can scrape and forward
# Prometheus metrics too, and it is deliberately not doing that: metrics
# collection stays exactly as it is, with Prometheus on mirkwood scraping the
# exporters in modules/monitoring.nix. One job, one owner.
#
# Promtail is NOT used — it reached end of life 2026-03-02 and Alloy is its
# supported replacement.
#
# ---------------------------------------------------------------------------
# Three things in here are load-bearing and fail QUIETLY if changed.
# ---------------------------------------------------------------------------
#
# 1. THE GROUP MEMBERSHIP IS THE WHOLE THING. Grafana's own documentation for
#    loki.source.journal is explicit: without membership in `systemd-journal`
#    and `adm`, "the component starts without error but collects no journal
#    entries". That is this lab's signature failure mode — a green unit
#    collecting nothing — so it is worth stating what proves otherwise:
#    a non-zero rate on `loki_source_journal_target_lines_total`, never
#    `systemctl is-active`.
#
#    The nixpkgs module hardcodes SupplementaryGroups = [ "systemd-journal" ],
#    so adding `adm` means mkForce'ing the whole list; a second definition of
#    the same serviceConfig key is a conflict, not a merge. Verified on orthanc
#    2026-09-20 that both groups exist (adm=55, systemd-journal=62) and that
#    the journal files carry an explicit `group:adm:r--` ACL.
#
# 2. LOKI IS ADDRESSED BY IP, NEVER BY NAME. Same reasoning as
#    modules/nut-secondary.nix: a resolver outage is precisely the event you
#    most want the logs for, and two of the four hosts shipping here ARE the
#    resolvers. Pointing this at `orthanc` by name would make log delivery fail
#    exactly when DNS breaks — and take Blocky's own query log down with it.
#
# 3. CARDINALITY IS BOUNDED ON PURPOSE. Stream labels are host, job, unit and
#    level and nothing else. Everything interesting and high-cardinality —
#    Blocky's client IP, the question, the PID — stays in the log line and is
#    parsed at query time. Loki's cost model is per-stream, so adding a label
#    like client_ip here multiplies streams by the number of devices in the
#    house and is the standard way to make a Loki install unusable.
#
# Alloy runs DynamicUser, so its journal cursor and file positions live under
# /var/lib/private/alloy, not /var/lib/alloy. Nothing should back that up or
# expect the unprefixed path to be a real directory — same trap as the restic
# one in modules/backup.nix.

{ config, pkgs, lib, ... }:

let
  hostName = config.networking.hostName;

  # orthanc's LAN address. See point 2 above before replacing this with a name.
  lokiEndpoint = "http://10.0.1.10:3100/loki/api/v1/push";

  # Alloy's own HTTP server: component health UI plus its /metrics endpoint.
  # Bound to all interfaces rather than loopback so Prometheus on mirkwood can
  # scrape it — that scrape is what turns "Alloy is shipping nothing" from an
  # invisible state into an alertable one, which given point 1 is the entire
  # reason this port is open. No secrets are rendered into the config it
  # serves.
  alloyPort = 12345;

  # NOT gated on services.blocky.enable, which is the obvious and wrong choice.
  #
  # Blocky runs DynamicUser, so its LogsDirectory is a symlink into
  # /var/log/private/ — a directory systemd keeps at 0700 root:root. Alloy is
  # also DynamicUser and cannot traverse into it, and NO group membership fixes
  # that: the barrier is the parent directory's mode, not the files (which are
  # 0644). `getent group blocky` on mirkwood does answer, but only because
  # nss-systemd synthesises the entry while blocky is running — resolving it
  # from another unit's SupplementaryGroups would make Alloy's start order
  # depend on Blocky's, for a group that buys no access anyway.
  #
  # Shipping the query log therefore REQUIRES giving Blocky a static user and
  # group first (lib/homelab.nix + DynamicUser = mkForce false), which turns
  # /var/log/blocky into a real directory this can be let into. That is a
  # separate, DNS-touching change; until it lands this stays off and the option
  # below is the interlock.
  shipBlocky = config.homelab.logging.blockyQueryLog;

  journalConfig = ''
    // ---------------------------------------------------------------------
    // systemd journal
    // ---------------------------------------------------------------------

    loki.relabel "journal" {
      // forward_to is required by the component but unused: this block exists
      // only to export .rules for the journal source below.
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      // Anything logged outside a unit — the kernel, audit, sudo, anything
      // from init.scope — has no _SYSTEMD_UNIT and would land in a single
      // unlabelled stream. This copies the syslog identifier into `unit` ONLY
      // when `unit` is still empty: the two source labels are joined with ";",
      // so an entry that already has a unit reads "blocky.service;blocky" and
      // fails the anchored regex, while one without reads ";kernel" and
      // matches.
      rule {
        source_labels = ["unit", "__journal_syslog_identifier"]
        separator     = ";"
        regex         = ";(.+)"
        replacement   = "$1"
        target_label  = "unit"
      }

      // error/warning/info/... rather than the raw 0-7 PRIORITY number.
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }
    }

    loki.source.journal "host" {
      forward_to    = [loki.write.default.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = { job = "journal", host = "${hostName}" }

      // Default is 7h. On a restart Alloy resumes from its stored cursor, but
      // with no cursor — first run, or state lost — this is how far back it
      // reads. 24h makes a day-long Alloy outage recoverable instead of
      // silently leaving a hole.
      max_age = "24h"
    }
  '';

  # Blocky writes one tab-separated file per day, named YYYY-MM-DD_ALL.log, and
  # keeps 30 days of them (queryLog.logRetentionDays in modules/dns.nix).
  # Columns, read off a live file on mirkwood rather than from the docs:
  #
  #   timestamp  client_ip  client_name  duration_ms  reason  question
  #   answer  response_code  response_type  question_type  instance
  #
  # They are NOT parsed here. Query-time `| pattern` keeps every one of those
  # fields — client IP especially — out of the stream label set. See point 3.
  blockyConfig = ''
    // ---------------------------------------------------------------------
    // Blocky query log (DNS hosts only)
    // ---------------------------------------------------------------------

    local.file_match "blocky" {
      path_targets = [{
        __path__ = "/var/log/blocky/*_ALL.log",
        job      = "blocky",
        host     = "${hostName}",
      }]
    }

    // Blocky stamps each line with its own LOCAL wall-clock time. Without
    // this, Loki would timestamp entries by when Alloy read them, which is
    // within a second while tailing live but badly wrong after any catch-up:
    // resuming from a stored position after an Alloy outage would replay an
    // hour of queries bunched at the restart instant, which is exactly the
    // shape the per-client DNS panels are meant to show over time.
    //
    // The regex uses [0-9] rather than \d purely to avoid backslash escaping
    // between Nix and Alloy's string syntax. Extracted values stay internal —
    // nothing here promotes `ts` to a label.
    loki.process "blocky" {
      forward_to = [loki.write.default.receiver]

      stage.regex {
        expression = "^(?P<ts>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})"
      }

      stage.timestamp {
        source   = "ts"
        format   = "2006-01-02 15:04:05"
        location = "${config.time.timeZone}"
      }
    }

    loki.source.file "blocky" {
      targets    = local.file_match.blocky.targets
      forward_to = [loki.process.blocky.receiver]

      // MANDATORY, not a preference. Blocky keeps 30 days of query log on disk
      // — ~805MB per DNS host, measured — and the glob above matches all of
      // it. Without this, a first start (or any loss of the positions file)
      // replays a month of expired lines at Loki, which rejects everything
      // past reject_old_samples_max_age and logs an error per batch while the
      // shipper looks healthy — and would trip this stack's own
      // AlloyWriteErrors alert on every rollout.
      //
      // Known, accepted cost: this also applies to each NEW file, and Blocky
      // rolls to YYYY-MM-DD_ALL.log at local midnight. A file with no stored
      // position is tailed from its end, so the queries written between
      // creation and discovery (one sync_period, 10s default) are skipped —
      // about 14 lines out of ~124,000 a day at the measured rate. The
      // alternative is a glob narrow enough to backfill safely, which cannot
      // be expressed statically because the filenames are dates.
      tail_from_end = true
    }
  '';
in
{
  options.homelab.logging.blockyQueryLog = lib.mkEnableOption ''
    shipping Blocky's query log to Loki from this host.

    Only meaningful on the DNS pair, and only once Blocky has been given a
    static user and group — see the shipBlocky comment in modules/alloy.nix.
    Enabling it against a DynamicUser Blocky yields a file source that matches
    nothing, silently
  '';

  config = {

  services.alloy = {
    enable = true;

    extraFlags = [
      "--server.http.listen-addr=0.0.0.0:${toString alloyPort}"
      # Alloy reports usage statistics to Grafana Labs by default.
      "--disable-reporting"
    ];
  };

  # The nixpkgs module expects the config at /etc/alloy/*.alloy rather than a
  # store path, and wires every file matching that into reloadTriggers — so a
  # config change reloads Alloy on nixos-rebuild instead of restarting it, and
  # the journal cursor is kept.
  environment.etc."alloy/config.alloy".text = ''
    logging {
      // Alloy at info narrates every target it discovers, which on the DNS
      // hosts means a line per query-log file per scan.
      level  = "warn"
      format = "logfmt"
    }

    loki.write "default" {
      endpoint {
        url = "${lokiEndpoint}"
      }
    }

    ${journalConfig}
    ${lib.optionalString shipBlocky blockyConfig}
  '';

  # See point 1 in the header. mkForce because the nixpkgs module already
  # defines this key, and two definitions of one serviceConfig attribute is an
  # eval conflict rather than a merge.
  systemd.services.alloy.serviceConfig.SupplementaryGroups = lib.mkForce (
    [ "systemd-journal" "adm" ] ++ lib.optional shipBlocky "blocky"
  );

  networking.firewall.allowedTCPPorts = [ alloyPort ];

  homelab.postUpgradeCheck.services = [ "alloy" ];

  };
}
