# modules/grafana.nix — Prometheus + Grafana for DNS observability
#
# Prometheus scrapes Blocky metrics from mirkwood (local) and rivendell.
# Grafana provides dashboards; native OIDC support pre-wired for Authelia.
#
# Ports: Grafana 3001 (3000 is Homepage), Prometheus 9090 (internal only).
#
# Required sops secret (secrets/mirkwood.yaml):
#   grafana_env — env file containing:
#                   GF_SECURITY_ADMIN_PASSWORD=<password>

{ config, pkgs, lib, ... }:

let
  # mirkwood scrapes itself over loopback; the rest by name.
  allHosts = [ "127.0.0.1" "rivendell" "pirateship" "orthanc" ];

  ntfyBase  = "http://10.0.1.9:2586";
  ntfyTopic = "homelab";

  # Stable datasource uid. Grafana generates a random one for a UI-created
  # datasource (this instance had PBFA97CFB590B2093), and the checked-in
  # dashboard JSON has to reference *something* — so pin a readable value here
  # and have dashboards/blocky.json refer to it. Provisioned datasources are
  # matched by name, so setting this updates the existing one in place.
  promDatasourceUid = "homelab-prometheus";

  # Every metric name below was read off the live exporters before the rule was
  # written, not guessed. A rule naming a metric that does not exist is not an
  # error in Prometheus — it is a rule that silently never fires, which is the
  # worst possible outcome for alerting. The nut exporter in particular does not
  # use a `nut_` prefix at all (it is `network_ups_tools_*`) and serves them on
  # a non-default path, so guessing would have produced exactly that.
  alertRules = {
    groups = [
      {
        name = "availability";
        rules = [
          {
            alert = "InstanceDown";
            expr = ''up == 0'';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "{{ $labels.job }} on {{ $labels.instance }} is down";
              description = "Prometheus has failed to scrape {{ $labels.instance }} ({{ $labels.job }}) for 5 minutes.";
            };
          }
        ];
      }
      {
        name = "node";
        rules = [
          {
            # Root filesystem, not every mount: the NFS media mounts on
            # pirateship and the erebor backup automount live at 90%+ by design
            # and would otherwise alert forever.
            alert = "DiskSpaceLow";
            expr = ''
              100 * node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|ramfs"}
                  / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|ramfs"} < 15
            '';
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.instance }} root filesystem below 15% free";
              description = "{{ $labels.instance }} has {{ $value | printf \"%.1f\" }}% free on /.";
            };
          }
          {
            alert = "DiskSpaceCritical";
            expr = ''
              100 * node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|ramfs"}
                  / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|ramfs"} < 5
            '';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "{{ $labels.instance }} root filesystem below 5% free";
              description = "{{ $labels.instance }} has {{ $value | printf \"%.1f\" }}% free on /. A full root filesystem breaks nix builds and deploys.";
            };
          }
          {
            # 30m, not 5m: rivendell legitimately runs hot during a CI aarch64
            # build, and that is not something to be woken for. Sustained
            # pressure for half an hour is.
            alert = "MemoryPressure";
            expr = ''
              100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 90
            '';
            "for" = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.instance }} memory above 90% for 30m";
              description = "{{ $labels.instance }} has under 10% available memory. rivendell wedged into swap-death this way on 2026-07-31.";
            };
          }
          {
            alert = "HostRebooted";
            expr = ''time() - node_boot_time_seconds < 600'';
            labels.severity = "info";
            annotations = {
              summary = "{{ $labels.instance }} rebooted";
              description = "{{ $labels.instance }} booted less than 10 minutes ago. Expected after a deploy; investigate if unexplained.";
            };
          }
        ];
      }
      {
        name = "disk-health";
        rules = [
          {
            # smartctl_device_smart_status: 1 = passing, 0 = failing.
            alert = "SmartFailure";
            expr = ''smartctl_device_smart_status == 0'';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "SMART failure on {{ $labels.instance }} {{ $labels.device }}";
              description = "{{ $labels.device }} on {{ $labels.instance }} reports SMART overall-health FAILED. Replace the drive.";
            };
          }
          {
            # NVMe wear indicator. 100 means the rated endurance is used up; it
            # is not a hard failure but it is the point to plan a replacement.
            alert = "NvmeWearHigh";
            expr = ''smartctl_device_percentage_used > 80'';
            "for" = "1h";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.instance }} {{ $labels.device }} at {{ $value }}% rated endurance";
              description = "NVMe wear indicator above 80%. Plan a replacement before it reaches 100%.";
            };
          }
          {
            # Spare blocks below the drive's own declared threshold is the
            # NVMe equivalent of reallocated-sector exhaustion.
            alert = "NvmeSpareLow";
            expr = ''
              smartctl_device_available_spare < smartctl_device_available_spare_threshold
            '';
            "for" = "15m";
            labels.severity = "critical";
            annotations = {
              summary = "{{ $labels.instance }} {{ $labels.device }} spare blocks below threshold";
              description = "Available spare has fallen under the drive's own threshold. Failure is imminent.";
            };
          }
        ];
      }
      {
        name = "systemd";
        rules = [
          {
            # Catches any failed unit, including the timers and oneshots the
            # bespoke ntfy scripts do not cover. The freshness dead-man's switch
            # only watches three specific units; this watches all of them.
            alert = "UnitFailed";
            expr = ''systemd_unit_state{state="failed"} == 1'';
            "for" = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "{{ $labels.name }} failed on {{ $labels.instance }}";
              description = "systemd unit {{ $labels.name }} has been in the failed state for 10 minutes.";
            };
          }
        ];
      }
      {
        name = "dns";
        rules = [
          {
            # Blocky's defining silent failure: when a blocklist download fails,
            # it logs an ERROR, stays `active`, and keeps answering with an EMPTY
            # denylist. No unit goes degraded and `blocky_blocking_enabled` still
            # reads 1, so nothing here would have caught it. On 2026-07-31
            # jsDelivr began 403ing the whole hagezi repo and ad blocking was off
            # for ~1.5 days; the only symptom was ads reappearing in iOS games.
            #
            # `blocky_denylist_cache_entries` is the one metric that tells the
            # truth. Broken reads 7 and 0 (the 7 being the inline Google apexes
            # and WPAD names, which parse without network) — which is exactly
            # what both hosts showed on 2026-08-09 when the hagezi account was
            # deleted outright. Thresholds sit far below normal but far above
            # the broken values, so they tolerate a maintainer resizing a list
            # without going quiet about a real failure.
            #
            # RETUNE THESE WHEN A SOURCE CHANGES. They are absolute counts tied
            # to whatever modules/dns.nix currently points at; the numbers below
            # are for oisd big (~253k) and Phishing Army extended (~156k). The
            # old malware threshold was `< 1000000`, sized for hagezi TIF's
            # ~2.16M entries — left unchanged it would have fired forever
            # against the smaller replacement feed.
            #
            # Scoped to group="ads" rather than summed over all groups so a
            # collapse of one list cannot be masked by another's entries.
            #
            # 30m, not 5m: a deploy restarts Blocky and re-downloading plus
            # parsing ~400k domains is not instant. A genuine failure still fires
            # long before the next 4h refresh could mask it.
            alert = "BlocklistEmpty";
            expr = ''blocky_denylist_cache_entries{group="ads"} < 100000'';
            "for" = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "Blocky ad blocklist collapsed on {{ $labels.instance }}";
              description = "{{ $labels.instance }} has only {{ $value }} entries in the 'ads' denylist (expected ~253k). Ad blocking is effectively off — check `journalctl -u blocky` for list download failures.";
            };
          }
          {
            alert = "ThreatBlocklistEmpty";
            expr = ''blocky_denylist_cache_entries{group="malware"} < 75000'';
            "for" = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "Blocky threat-intel blocklist collapsed on {{ $labels.instance }}";
              description = "{{ $labels.instance }} has only {{ $value }} entries in the 'malware' denylist (expected ~156k). The supplemental phishing feed is down — primary malware coverage still comes from oisd big in the 'ads' group, so check that alert too, then `journalctl -u blocky`.";
            };
          }
          {
            # Early warning, and the one that would actually have caught the
            # 2026-07-31 outage AT THE TIME. The entry-count alerts above are
            # lagging indicators: they only fire once a list has already
            # collapsed, which on that occasion meant after a restart, ~1.5 days
            # in. This counter increments on the very first failed download —
            # 02:31 on the day it broke.
            #
            # It also covers the case the entry counts structurally cannot see:
            # when a REFRESH fails for an already-loaded list, Blocky keeps
            # serving the previous copy. Entries stay at ~216k and look perfect
            # while the lists quietly rot.
            #
            # THRESHOLD AND WINDOW ARE BOTH LOAD-BEARING. This rule was
            # `increase(...[1h]) > 0` until 2026-08-04, which was wrong twice
            # over — it cried wolf, and then it lied about the recovery:
            #
            # 1. `> 0` counts ATTEMPTS, not failures. blocky_failed_downloads_total
            #    is incremented from retry-go's OnRetry callback
            #    (lists/downloader.go: onDownloadError inside logRetry), which
            #    fires on EVERY failed attempt. loading.downloads.attempts = 5 in
            #    modules/dns.nix, so a list that times out once and succeeds on
            #    the retry increments this by 1 while nothing at all is wrong.
            #    That is what happened on 2026-08-02: two lists blipped one
            #    attempt each, both recovered on attempt 2, the lists were
            #    complete and current — and this alert fired anyway.
            #    A list that genuinely fails burns all 5 attempts and increments
            #    by exactly 5 (retry-go v4.7.0 calls onRetry before the
            #    `n == attempts-1` break, so the last attempt counts too).
            #    `>= 5` is therefore the exact boundary between "recovered by
            #    Blocky's own retries" and "a group's refresh actually failed".
            #
            # 2. The 1h window is SHORTER THAN THE 4h REFRESH PERIOD, so the
            #    alert always resolved ~1h after a failure — before Blocky had
            #    even attempted another download. The "resolved" notification
            #    carried no information: it meant "the window rolled", never
            #    "the lists are current again". Worse, a sustained outage made it
            #    flap fire/resolve four times a day, training the alert to be
            #    ignored. The window MUST exceed the refresh period: at 6h, the
            #    counter can only fall back to zero if a later refresh cycle has
            #    since completed without burning retries. That makes the resolve
            #    mean what a resolve should mean.
            #
            # 3. 2026-08-19: `increase(...[6h]) >= 5` was itself unsound, and it
            #    false-fired for ~30h out of the 10 days after #566 swapped the
            #    blocklist sources. Fix (1) above is right about a single list,
            #    but blocky_failed_downloads_total is ONE UNLABELLED COUNTER
            #    summed over every list and every refresh cycle, so "5" is not
            #    the boundary once the window spans more than one cycle. A 6h
            #    window covers 1-2 of the 4h cycles, and each cycle has 2
            #    network-backed denylists (ads → oisd, malware → Phishing Army;
            #    the inline entries need no network) that can each blip
            #    independently. Recovered blips simply accumulate to 5. Measured
            #    at the time: max attempt reached over 3 days was 3/5 on both
            #    hosts, zero "Populating of group cache failed", lists refreshing
            #    on schedule and full — and the alert was firing anyway. The
            #    condition was never once true in the 20 days BEFORE the source
            #    swap, so this is the same class of bug as the entry-count
            #    thresholds: absolute numbers tuned against one set of upstreams,
            #    left alone when the upstreams changed.
            #
            #    Firing and resolving need windows of DIFFERENT lengths, which
            #    is why the expression is now two layers:
            #
            #      inner  (max_over_time - min_over_time) over [15m]
            #             = attempts burned inside ONE refresh cycle. 5 retries
            #               at 60s timeout + 10s cooldown span ~5 min and cycles
            #               are 4h apart, so a 15m window can only ever contain
            #               one cycle. max-min rather than increase() because
            #               increase() extrapolates to the window edges: a real
            #               burst of 5 read as 5.357, and that inflation applied
            #               to a benign 8 would clear the threshold on its own.
            #               max-min is the exact raw delta. A counter reset mid
            #               window (blocky restart) under-reports, i.e. fails
            #               safe.
            #
            #      >= 9   = at least one list exhausted its 5. THIS NUMBER IS
            #               DERIVED, NOT TUNED: with N network-backed denylists
            #               and `attempts` retries each, the most that can burn
            #               in one cycle without any single list failing is
            #               N * (attempts - 1) = 2 * 4 = 8. RECOMPUTE IT when a
            #               denylist is added or removed, or when
            #               loading.downloads.attempts changes in modules/dns.nix
            #               — nothing here fails loudly if you don't. For
            #               reference, the worst benign cycle actually observed
            #               in 30 days was 5.
            #
            #      outer  max_over_time(...[6h:5m])
            #             = latch the detection for 6h so point (2) above still
            #               holds. The alert resolves only once 6h have passed
            #               with no bad cycle, and since the refresh period is
            #               4h that guarantees at least one LATER cycle was
            #               observed and did not exhaust retries. Verified on
            #               live data: the series steps up at a burst, holds,
            #               and steps down only after subsequent clean cycles.
            #               5m subquery resolution is enough to catch a ~5 min
            #               burst inside a 15m inner window while keeping the
            #               subquery cheap on a Pi (72 evaluations).
            alert = "BlocklistDownloadFailing";
            expr = ''
              max_over_time(
                (
                    max_over_time(blocky_failed_downloads_total[15m])
                  - min_over_time(blocky_failed_downloads_total[15m])
                )[6h:5m]
              ) >= 9
            '';
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Blocky blocklist downloads are failing on {{ $labels.instance }}";
              description = "{{ $labels.instance }} burned {{ $value }} download attempts inside a single refresh cycle. Two network-backed denylists with 5 retries each can burn at most 8 without any one of them failing, so at least one list exhausted its retries and that group's refresh genuinely failed — it is now serving the previously-loaded copy. Blocking still works right now, but that group is no longer being updated. This clears ~6h after the last bad cycle, which means later cycles have been observed refreshing cleanly. Check `journalctl -u blocky | grep -iE 'download|status code|Populating of group cache failed'`.";
            };
          }
          {
            # The staleness backstop, and the only rule here whose resolution is
            # positive proof rather than the absence of a symptom: the gauge it
            # reads advances ONLY when a group's cache actually rebuilt
            # (lists/list_cache.go publishes BlockingCacheGroupChanged on the
            # success path only — a failed group logs "using existing cache" and
            # returns early without publishing). Blocky refreshes every 4h; if
            # every refresh fails it serves the old lists forever and no other
            # metric here moves. 9h is two missed cycles plus slack, so a single
            # transient failure stays quiet.
            #
            # This rule was DEAD from when it was written until 2026-08-04. The
            # gauge is global and unlabelled, so any ONE succeeding group
            # advances it for all of them — and the `local-noise` denylist group
            # was inline-only, needing no network, so it succeeded on every
            # cycle and pinned the gauge to "now" no matter what happened to the
            # hagezi downloads. The backstop documented above could not fire.
            # The fix was in modules/dns.nix, not here: local-noise was folded
            # into `ads` so that every remaining group depends on the network.
            # Adding an inline-only denylist group silently kills this rule
            # again — see the comment on those entries in dns.nix.
            #
            # Residual limit, accepted: a PARTIAL failure (ads fails, malware
            # succeeds) still advances the shared gauge and is invisible here.
            # Blocky exposes no per-group refresh timestamp, so that case is
            # covered by BlocklistDownloadFailing above and by the Gatus
            # ad-blocking canary in modules/gatus.nix, which asks the resolver
            # the question a client would actually ask.
            alert = "BlocklistStale";
            expr = ''time() - blocky_last_list_group_refresh_timestamp_seconds > 32400'';
            "for" = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "Blocky blocklists have not refreshed on {{ $labels.instance }}";
              description = "{{ $labels.instance }} last refreshed its blocklists {{ $value | humanizeDuration }} ago (refresh period is 4h). The lists still loaded are being served but are no longer being updated.";
            };
          }
        ];
      }
      {
        # ---------------------------------------------------------------------
        # VPN — see modules/vpn-killswitch.nix for why these metrics exist and
        # why none of the pre-existing checks could see a tunnel failure.
        #
        # These read textfile-collector metrics written by vpn-leak-check on
        # pirateship, so they arrive through the `node` job, not a job of their
        # own. That means an absent metric shows up as "no series" rather than a
        # down target — hence VpnLeakCheckStale, which is the only rule here
        # that can distinguish "no leaks" from "nothing is looking".
        # ---------------------------------------------------------------------
        name = "vpn";
        rules = [
          {
            # The stack has already stopped itself by the time this fires. This
            # is notification, not detection — but it repeats daily via
            # Alertmanager's repeat_interval, so a latched stack cannot be
            # forgotten about the way a single ntfy push can be missed.
            alert = "VpnKillSwitchTripped";
            expr = ''vpn_killswitch_tripped == 1'';
            "for" = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "arr stack latched OFF after a confirmed VPN leak";
              description = "pirateship stopped the entire arr stack because traffic was escaping the VPN. It will not restart until the latch is cleared. Read the reason with `cat /var/lib/vpn-killswitch/tripped`, then `sudo rm /var/lib/vpn-killswitch/tripped && sudo systemctl start podman-gluetun podman-qbittorrent podman-sabnzbd podman-radarr podman-sonarr podman-prowlarr podman-lidarr` — starting gluetun alone does not bring the consumers back.";
            };
          }
          {
            # Fires independently of the latch, so a leak is still reported even
            # if the automatic stop failed (podman wedged, systemctl refused).
            # Never rely solely on the actuator to tell you the actuator ran.
            alert = "VpnEgressLeak";
            expr = ''vpn_egress_matches_host == 1'';
            "for" = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "arr stack traffic is leaving via the home IP";
              description = "The gluetun netns reported the same public IP as pirateship itself — traffic is bypassing the tunnel. If the stack is still running, stop it now: `sudo systemctl stop podman-gluetun`.";
            };
          }
          {
            # Config drift, not runtime failure. 10m because a gluetun restart
            # briefly has no rules loaded while it rebuilds them.
            alert = "VpnFirewallDegraded";
            expr = ''vpn_firewall_intact == 0'';
            "for" = "10m";
            labels.severity = "critical";
            annotations = {
              summary = "gluetun kill-switch firewall is not in its expected shape";
              description = "Either the OUTPUT policy is no longer DROP, or an egress rule permits a destination outside the declared allowlist. Nothing may be leaking yet — the enforcement that would stop it is what has weakened. See `journalctl -u vpn-leak-check` and modules/vpn-killswitch.nix.";
            };
          }
          {
            # Warning, not critical: a dead tunnel is the kill switch working.
            # Nothing is at risk, the media stack is simply useless. 20m rides
            # out ProtonVPN server rotations and the gluetun-watchdog's own
            # 15m/30m restart cycle without duplicating its notification.
            alert = "VpnTunnelDown";
            expr = ''vpn_tunnel_up == 0 and vpn_killswitch_tripped == 0'';
            "for" = "20m";
            labels.severity = "warning";
            annotations = {
              summary = "arr stack VPN tunnel has been down for 20m";
              description = "The gluetun netns cannot reach the internet. This is fail-closed — nothing is leaking — but downloads are stalled. Check `journalctl -u podman-gluetun` and `journalctl -u gluetun-watchdog`.";
            };
          }
          {
            # The dead-man's switch on the detector itself. Without this, a
            # vpn-leak-check that stopped running is indistinguishable from a
            # network with no leaks — the exact failure shape that let the
            # blocklist outage run for a day and a half.
            #
            # `absent()` covers the metric never having existed at all (unit
            # never ran, textfile dir missing); the time comparison covers it
            # having stopped. Both are needed: neither catches the other.
            alert = "VpnLeakCheckStale";
            expr = ''absent(vpn_leak_check_timestamp_seconds) or (time() - vpn_leak_check_timestamp_seconds > 1800)'';
            "for" = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "VPN leak detector has stopped reporting";
              description = "vpn-leak-check on pirateship has not published a result in over 30m (it runs every 5m). The VPN kill switch is unmonitored — the other vpn alerts are silent because nothing is looking, not because nothing is wrong. Check `systemctl status vpn-leak-check.timer`.";
            };
          }
        ];
      }
      {
        name = "ups";
        rules = [
          {
            # OB = "on battery". Metrics are network_ups_tools_*, NOT nut_* —
            # verified against the live exporter.
            alert = "UpsOnBattery";
            expr = ''network_ups_tools_ups_status{flag="OB"} == 1'';
            "for" = "1m";
            labels.severity = "critical";
            annotations = {
              summary = "UPS is on battery";
              description = "Mains power lost. Battery at {{ with query \"network_ups_tools_battery_charge\" }}{{ . | first | value }}{{ end }}%.";
            };
          }
          {
            # LB is the UPS's own low-battery signal; the charge threshold is a
            # belt-and-braces second opinion in case the flag is not raised.
            alert = "UpsBatteryLow";
            expr = ''
              network_ups_tools_ups_status{flag="LB"} == 1
              or network_ups_tools_battery_charge < 50
            '';
            "for" = "1m";
            labels.severity = "critical";
            annotations = {
              summary = "UPS battery low";
              description = "UPS battery is low. Hosts will begin shutting down shortly.";
            };
          }
          {
            # A UPS that has been replacing-battery for a day is not urgent at
            # 03:00 but must not be forgotten either.
            alert = "UpsReplaceBattery";
            expr = ''network_ups_tools_ups_status{flag="RB"} == 1'';
            "for" = "1h";
            labels.severity = "warning";
            annotations = {
              summary = "UPS requests battery replacement";
              description = "The UPS has raised its replace-battery flag.";
            };
          }
        ];
      }
    ];
  };
in

{
  services.prometheus = {
    enable        = true;
    port          = 9090;
    retentionTime = "7d";
    scrapeConfigs = [
      {
        job_name       = "blocky";
        static_configs = [{
          targets = [
            "127.0.0.1:4000"        # mirkwood Blocky (local)
            "rivendell:4000"        # rivendell Blocky
          ];
        }];
      }
      {
        job_name       = "node";
        static_configs = [{
          targets = [
            "127.0.0.1:9100"           # mirkwood
            "rivendell:9100"
            "pirateship:9100"
            "orthanc:9100"
          ];
        }];
      }
      {
        job_name       = "systemd";
        static_configs = [{
          targets = map (h: "${h}:9558") allHosts;
        }];
      }
      {
        job_name       = "smartctl";
        static_configs = [{
          targets = map (h: "${h}:9633") allHosts;
        }];
      }
      {
        # rivendell only — it is the host with the UPS on USB.
        #
        # metrics_path MUST be /ups_metrics. This exporter serves Go runtime
        # self-metrics on the default /metrics and the actual UPS readings on
        # /ups_metrics. Scraping the default path yields a target that reports
        # perfectly "up" while carrying not one UPS metric — which is exactly
        # what happened when this job was first added (2026-08-01): the target
        # was green and `network_ups_tools_*` did not exist.
        job_name       = "nut";
        metrics_path   = "/ups_metrics";
        static_configs = [{ targets = [ "rivendell:9199" ]; }];
      }
    ];

    # ---------------------------------------------------------------------
    # Alerting
    #
    # Before 2026-08-01 Prometheus scraped four hosts and had ZERO rules and no
    # Alertmanager. Every alert in the homelab was a bespoke shell script
    # piping to ntfy (backup OnFailure, the freshness dead-man's switch, the
    # post-upgrade check, Gatus). Those cover the specific things someone
    # thought to write a script for; nothing watched the metrics that were
    # already being collected.
    #
    # Delivery reuses the same ntfy topic as everything else rather than
    # introducing a second notification channel, via alertmanager-ntfy as a
    # webhook receiver. Keeping one topic means one place to look.
    # ---------------------------------------------------------------------
    alertmanagers = [{
      static_configs = [{ targets = [ "127.0.0.1:9093" ]; }];
    }];

    rules = [ (builtins.toJSON alertRules) ];

    alertmanager = {
      enable = true;
      port = 9093;
      configuration = {
        route = {
          receiver = "ntfy";
          group_by = [ "alertname" "instance" ];
          group_wait = "30s";
          group_interval = "5m";
          # Re-send a still-firing alert daily. Long enough not to nag, short
          # enough that something broken cannot quietly scroll out of view.
          repeat_interval = "24h";
        };
        receivers = [{
          name = "ntfy";
          # Path MUST be /hook. alertmanager-ntfy serves the webhook there and
          # 404s everything else (verified by probing /, /webhook, /alerts,
          # /api/v1/alerts — all 404). Alertmanager does NOT retry a 404 into
          # anything visible: the alert simply never arrives, while Prometheus
          # shows it firing and Alertmanager shows it active, so both ends look
          # healthy. Found on 2026-08-01 only by firing a synthetic alert and
          # reading alertmanager-ntfy's own log, which showed
          # `{"status": 404, "path": "/alert"}`.
          webhook_configs = [{ url = "http://127.0.0.1:8000/hook"; }];
        }];
      };
    };
  };

  # Bridges Alertmanager webhooks onto the existing ntfy topic. Listens on
  # loopback only — it has no authentication of its own and nothing outside
  # this host should be able to inject notifications.
  services.prometheus.alertmanager-ntfy = {
    enable = true;
    settings = {
      http.addr = "127.0.0.1:8000";
      ntfy = {
        baseurl = ntfyBase;
        notification = {
          topic = ntfyTopic;
          # Firing alerts are high priority, resolved ones are quiet — a
          # recovery notice should not buzz a phone at 03:00.
          priority = ''status == "firing" ? "high" : "default"'';
          tags = [
            { tag = "rotating_light"; condition = ''status == "firing"''; }
            { tag = "white_check_mark"; condition = ''status == "resolved"''; }
          ];
        };
      };
    };
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3001;
        domain    = "grafana.theshire.io";
        root_url  = "https://grafana.theshire.io";
      };
      security = {
        admin_user     = "admin";
        admin_password = "$__env{GF_SECURITY_ADMIN_PASSWORD}";
        secret_key     = "$__env{GF_SECURITY_SECRET_KEY}";
      };
    };

    provision = {
      enable = true;
      # Grafana CANNOT change the uid of an existing datasource in place. Its
      # provisioning update path looks the datasource up by uid, so introducing
      # `uid` on a datasource that Grafana already created with a generated one
      # fails with:
      #
      #   Failed to provision data sources: "Datasource provisioning error:
      #   data source not found"
      #
      # and that failure is fatal — the provisioning module fails to start and
      # takes the whole process with it. Observed on mirkwood 2026-08-01: 248
      # restarts in a crash loop, never binding 3001, while systemd cheerfully
      # reported "active (running)" for the few hundred ms each attempt lasted.
      #
      # deleteDatasources runs before datasources are written, so the old
      # generated-uid record is removed and recreated with ours. It is keyed on
      # name and is idempotent: after the first run there is nothing to delete.
      # Safe because this datasource is fully declared here — nothing is lost by
      # recreating it.
      datasources.settings = {
        deleteDatasources = [{ name = "Prometheus"; orgId = 1; }];
        datasources = [{
          name      = "Prometheus";
          type      = "prometheus";
          uid       = promDatasourceUid;
          url       = "http://127.0.0.1:9090";
          isDefault = true;
          orgId     = 1;
        }];
      };

      # Dashboards are provisioned from the repo. Until 2026-08-01 only
      # datasources were provisioned and the single dashboard ("Blocky", uid
      # JvOqE4gR1) was UI-authored — living entirely in Grafana's sqlite, which
      # is the same "config lives in a database with no file equivalent"
      # pattern that got Uptime Kuma replaced by Gatus. It was recoverable only
      # via the /var/lib/grafana restic backup, and not reviewable in git.
      #
      # allowUiUpdates = false makes Grafana mark these read-only in the UI.
      # That is the point: it prevents a UI edit that would silently diverge
      # from the file and be lost on the next deploy. To change a dashboard,
      # edit it in the UI, export the JSON, and commit it.
      dashboards.settings.providers = [{
        name = "homelab";
        type = "file";
        allowUiUpdates = false;
        options.path = ./../dashboards;
        options.foldersFromFilesStructure = false;
      }];
    };
  };

  sops.secrets.grafana_env = {
    owner = "grafana";
  };

  systemd.services.grafana.serviceConfig.EnvironmentFile =
    config.sops.secrets.grafana_env.path;

  # Grafana on 3001 — Caddy on rivendell proxies it via mirkwood.local:3001
  # Port must be open so rivendell can reach it; not directly exposed externally
  networking.firewall.allowedTCPPorts = [ 3001 ];
  # Prometheus internal only — no firewall port opened

  homelab.postUpgradeCheck.services = [ "prometheus" "grafana" ];
}
