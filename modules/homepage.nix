# modules/homepage.nix — Homepage dashboard (mirkwood, port 3000)
#
# Uses the native NixOS service module instead of a container, so config
# is declared entirely in Nix. No environment.etc, no volume mounts.
#
# WHAT THIS PAGE IS FOR — and what it deliberately is not
#
# This lab already has three strong operational surfaces, and Homepage must
# not duplicate any of them:
#
#   * ntfy      — push alerts. Anything genuinely broken pages a phone.
#   * Gatus     — up/down for ~25 endpoints (`modules/gatus.nix`).
#   * Grafana   — history, and ~30 alert rules (`modules/grafana.nix`).
#
# The gap those three leave is AMBIENT STATE: numbers that are normal, never
# fire an alert, and yet are the first thing you want on opening a browser —
# how full erebor is, whether last night's backup actually ran, what the UPS
# is doing, how the resolvers are behaving. The old version of this file
# answered none of that: it was a link directory plus twelve Glances widgets
# showing instantaneous CPU/memory/network, which is precisely the data
# Grafana graphs better and alerts on already.
#
# So: the Overview tab is ambient state, the Services tab is the launcher.
#
# EVERY TILE IS PROMETHEUS, ON LOCALHOST
#
# Homepage runs on mirkwood, and so does Prometheus. Prometheus deliberately
# does not listen on the LAN (see `modules/grafana.nix`), but 127.0.0.1:9090
# is reachable from this process. That is the whole trick behind this file:
# the Overview tab needs no API keys, no new sops secrets, and no firewall
# change, because every number already exists as a scraped series.
#
# `prometheusmetric` renders AT MOST 4 metrics per tile (it slices the list),
# so each tile below is capped at four on purpose. Adding a fifth silently
# does nothing.
#
# FORMATTING TRAP: Homepage's `percent` format is Intl.NumberFormat percent
# style, which expects a FRACTION — feed it 78.7 and it renders "7,871%".
# Every ratio here therefore uses `type = "number"` with `suffix = "%"` and
# the query already scaled to 0-100. Unambiguous, and it survives upgrades.
#
# INSTANCE LABELS ARE NOT HOSTNAMES: mirkwood scrapes itself over loopback,
# so its node_exporter instance label is `127.0.0.1:9100`, not `mirkwood:9100`.
# The other three are `<host>:9100`. Getting this wrong yields a blank tile,
# not an error.
#
# `systemd_unit_state` / `systemd_timer_last_trigger_seconds` come from the
# systemd exporter (job "systemd", port 9558) and are NOT prefixed `node_`.
# `node_systemd_*` does not exist here and silently matches nothing.
#
# BACKUP TILE HONESTY: `systemd_timer_last_trigger_seconds` is the last time
# the timer FIRED, not the last time restic SUCCEEDED. That is why the tile
# pairs the age with a count of failed restic units — age alone would stay
# green through a week of failing backups.
#
# NO "DAYS UNTIL FULL" TILE, ON PURPOSE: predicting from a 3d window (7d is
# all the retention there is) yields ~14,000 days whenever the library is
# flat. A number that precise and that wrong is worse than no number, so the
# storage tile shows honest 3-day growth in bytes and leaves the trend line
# to Grafana, where a graph belongs.
#
# NEVER ADD THE `minecraft` WIDGET. Homepage ships one, and it works by
# opening a TCP connection to the server port. On orthanc that connection IS
# the knock that resumes the SIGSTOPped JVM (`modules/minecraft.nix`), so a
# dashboard tile would defeat autopause every time someone loaded the page —
# the same reason `modules/gatus.nix` keeps its Gaming group empty. Minecraft
# liveness is the MinecraftServerDown Prometheus alert and nothing else.
#
# Icons resolve from CDN (dashboard-icons for `*.png`, @mdi/svg for `mdi-*`);
# nothing is vendored, so a broken icon is cosmetic only.
#
# See https://gethomepage.dev/configs/services/ for the full schema.

{ config, pkgs, lib, ... }:

let
  # Prometheus, same host, loopback only. See header.
  prom = "http://127.0.0.1:9090";

  # node_exporter instance labels. mirkwood self-scrapes over loopback.
  instances = {
    mirkwood   = "127.0.0.1:9100";
    rivendell  = "rivendell:9100";
    pirateship = "pirateship:9100";
    orthanc    = "orthanc:9100";
  };

  # A ratio already scaled 0-100 by its query. See the percent trap above.
  pct = decimals: {
    type = "number";
    suffix = "%";
    options.maximumFractionDigits = decimals;
  };

  countFmt = {
    type = "number";
    options.maximumFractionDigits = 0;
  };

  hoursFmt = {
    type = "number";
    suffix = "h";
    options.maximumFractionDigits = 0;
  };

  bytesFmt = { type = "bytes"; };

  mkTile = { icon, href, description, metrics, refresh ? 30000 }: {
    inherit icon href description;
    widget = {
      type = "prometheusmetric";
      url = prom;
      refreshInterval = refresh;
      inherit metrics;
    };
  };

  # One tile per host: the four numbers that actually characterise a box.
  # Replaces three Glances widgets per host with one, and adds uptime and
  # root-disk usage, neither of which the old page showed at all.
  mkHost = name: instance: {
    ${name} = mkTile {
      icon = "glances.png";
      href = "https://${name}-stats.theshire.io";
      description = "CPU, memory, disk, uptime";
      metrics = [
        {
          label = "CPU";
          query = ''100 * (1 - avg(rate(node_cpu_seconds_total{instance="${instance}",mode="idle"}[5m])))'';
          format = pct 0;
        }
        {
          label = "RAM";
          query = ''100 * (1 - node_memory_MemAvailable_bytes{instance="${instance}"} / node_memory_MemTotal_bytes{instance="${instance}"})'';
          format = pct 0;
        }
        {
          label = "Disk";
          query = ''100 * (1 - node_filesystem_avail_bytes{instance="${instance}",mountpoint="/"} / node_filesystem_size_bytes{instance="${instance}",mountpoint="/"})'';
          format = pct 0;
        }
        {
          label = "Up";
          query = ''(time() - node_boot_time_seconds{instance="${instance}"}) / 86400'';
          format = { type = "number"; suffix = "d"; options.maximumFractionDigits = 0; };
        }
      ];
    };
  };

  # erebor is mounted by several hosts and therefore scraped several times.
  # Pin one instance so the tile shows a single value, not four identical ones.
  ereborMedia = ''{instance="${instances.orthanc}",mountpoint="/var/lib/media"}'';
in
{
  services.homepage-dashboard = {
    enable = true;
    listenPort = 3000;
    openFirewall = true;
    allowedHosts = "mirkwood.home.theshire.io:3000,mirkwood:3000,10.0.1.8:3000,homepage.theshire.io";

    settings = {
      title = "Homelab";
      theme = "dark";
      color = "slate";
      headerStyle = "boxedWidgets";
      statusStyle = "dot";
      hideVersion = true;
      useEqualHeights = true;

      # A LIST, not an attribute set. Nix sorts attrset keys alphabetically,
      # which would scramble both the group order and the tab assignment;
      # Homepage 2.x accepts an ordered list of single-key maps and folds it
      # back into an object itself, so order survives. Do not "tidy" this
      # into `layout = { ... }`.
      layout = [
        { Lab     = { tab = "Overview"; style = "row"; columns = 4; }; }
        { Storage = { tab = "Overview"; style = "row"; columns = 4; }; }
        { Power   = { tab = "Overview"; style = "row"; columns = 4; }; }
        { DNS     = { tab = "Overview"; style = "row"; columns = 4; }; }
        { Hosts   = { tab = "Overview"; style = "row"; columns = 4; }; }

        { Media          = { tab = "Services"; style = "row"; columns = 4; }; }
        { Downloads      = { tab = "Services"; style = "row"; columns = 4; }; }
        { Home           = { tab = "Services"; style = "row"; columns = 4; }; }
        { Infrastructure = { tab = "Services"; style = "row"; columns = 4; }; }
      ];
    };

    widgets = [
      {
        datetime = {
          text_size = "xl";
          format = { timeStyle = "short"; dateStyle = "short"; hour12 = true; };
        };
      }
      { search = { provider = "duckduckgo"; target = "_blank"; }; }
    ];

    services = [
      # ---------------------------------------------------------------
      # Overview — ambient state. No API keys; every value is Prometheus.
      # ---------------------------------------------------------------
      {
        Lab = [
          {
            Health = mkTile {
              icon = "mdi-heart-pulse";
              href = "https://grafana.theshire.io";
              description = "Alerts, failed units, hosts, backup age";
              metrics = [
                {
                  label = "Alerts";
                  # `or vector(0)` so an empty result renders 0, not a blank.
                  query = ''sum(ALERTS{alertstate="firing"}) or vector(0)'';
                  format = countFmt;
                }
                {
                  label = "Failed";
                  query = ''sum(systemd_unit_state{state="failed"}) or vector(0)'';
                  format = countFmt;
                }
                {
                  label = "Hosts";
                  query = ''count(up{job="node"} == 1)'';
                  format = { type = "number"; suffix = "/4"; options.maximumFractionDigits = 0; };
                }
                {
                  label = "Backup";
                  # Oldest local restic run across all hosts, in hours.
                  query = ''max((time() - systemd_timer_last_trigger_seconds{name="restic-backups-local.timer"}) / 3600)'';
                  format = hoursFmt;
                }
              ];
            };
          }
        ];
      }

      {
        Storage = [
          {
            "Media (erebor)" = mkTile {
              icon = "mdi-harddisk";
              href = "https://grafana.theshire.io";
              description = "erebor RAID 6 over NFS";
              metrics = [
                {
                  label = "Free";
                  query = ''node_filesystem_avail_bytes${ereborMedia}'';
                  format = bytesFmt;
                }
                {
                  label = "Used";
                  query = ''100 * (1 - node_filesystem_avail_bytes${ereborMedia} / node_filesystem_size_bytes${ereborMedia})'';
                  format = pct 1;
                }
                {
                  label = "3d growth";
                  # Negative delta on "available" is growth of the library.
                  query = ''-delta(node_filesystem_avail_bytes${ereborMedia}[3d])'';
                  format = bytesFmt;
                }
                {
                  label = "Size";
                  query = ''node_filesystem_size_bytes${ereborMedia}'';
                  format = bytesFmt;
                }
              ];
            };
          }
          {
            Backups = mkTile {
              icon = "mdi-backup-restore";
              href = "https://grafana.theshire.io";
              description = "restic local + offsite";
              metrics = [
                {
                  label = "Local";
                  query = ''max((time() - systemd_timer_last_trigger_seconds{name="restic-backups-local.timer"}) / 3600)'';
                  format = hoursFmt;
                }
                {
                  label = "Offsite";
                  query = ''max((time() - systemd_timer_last_trigger_seconds{name="restic-backups-offsite.timer"}) / 3600)'';
                  format = hoursFmt;
                }
                {
                  label = "Failed";
                  # Timer age alone stays green through failing backups; this
                  # is the half that actually notices. See header.
                  #
                  # `\\.` is not a typo. PromQL string literals use Go escape
                  # rules, where `\.` is an *invalid* escape and the query is
                  # rejected with HTTP 400 — the regex needs a literal
                  # backslash, so the source must carry two.
                  query = ''sum(systemd_unit_state{name=~"restic-.*\\.service",state="failed"}) or vector(0)'';
                  format = countFmt;
                }
                {
                  label = "Hosts";
                  # Deliberately not "free space on the repo": /var/backup/erebor
                  # and /var/lib/media are different exports of the SAME erebor
                  # pool, so that tile would just restate the Storage one.
                  # A host whose timer stopped existing is the failure this
                  # catches, and nothing else here would.
                  query = ''count(systemd_timer_last_trigger_seconds{name="restic-backups-local.timer"})'';
                  format = { type = "number"; suffix = "/4"; options.maximumFractionDigits = 0; };
                }
              ];
            };
          }
        ];
      }

      {
        Power = [
          {
            UPS = mkTile {
              icon = "mdi-power-plug";
              href = "https://grafana.theshire.io";
              description = "Tripp Lite SMC15002URM";
              # battery.runtime is NOT exported by this exporter for this UPS
              # (only charge/load/voltage are), so there is no runtime tile.
              # Measured runtime figures live in CLAUDE.md's power table.
              metrics = [
                { label = "Battery"; query = ''network_ups_tools_battery_charge''; format = pct 0; }
                { label = "Load"; query = ''network_ups_tools_ups_load''; format = pct 0; }
                {
                  label = "Input";
                  query = ''network_ups_tools_input_voltage'';
                  format = { type = "number"; suffix = "V"; options.maximumFractionDigits = 0; };
                }
                {
                  label = "Mains";
                  # OL = on line. 1 = running on mains, 0 = on battery.
                  query = ''network_ups_tools_ups_status{flag="OL"}'';
                  format = countFmt;
                }
              ];
            };
          }
        ];
      }

      {
        DNS = [
          {
            Blocky = mkTile {
              icon = "mdi-dns";
              href = "https://grafana.theshire.io";
              description = "Both resolvers, combined";
              metrics = [
                {
                  label = "Queries/min";
                  query = ''sum(rate(blocky_query_total[5m])) * 60'';
                  format = countFmt;
                }
                {
                  label = "Blocked";
                  query = ''100 * sum(rate(blocky_response_total{response_type="BLOCKED"}[24h])) / clamp_min(sum(rate(blocky_response_total[24h])), 0.001)'';
                  format = pct 0;
                }
                {
                  label = "Cache hit";
                  query = ''100 * sum(rate(blocky_cache_hits_total[1h])) / clamp_min(sum(rate(blocky_cache_hits_total[1h])) + sum(rate(blocky_cache_misses_total[1h])), 0.001)'';
                  format = pct 0;
                }
                {
                  label = "Denylist";
                  # Per-GROUP gauge, so a bare max() reports the largest single
                  # group rather than the blocklist. Sum within a resolver,
                  # then take the fuller of the two.
                  query = ''max(sum by (instance) (blocky_denylist_cache_entries))'';
                  format = countFmt;
                }
              ];
            };
          }
        ];
      }

      {
        Hosts = [
          (mkHost "mirkwood" instances.mirkwood)
          (mkHost "rivendell" instances.rivendell)
          (mkHost "pirateship" instances.pirateship)
          (mkHost "orthanc" instances.orthanc)
        ];
      }

      # ---------------------------------------------------------------
      # Services — the launcher.
      #
      # These are plain links today. Homepage ships live widgets for every
      # one of the arr apps, qBittorrent, SABnzbd and Jellyfin, which would
      # turn this tab into a real queue view — but each needs that service's
      # API key, and Homepage runs on mirkwood while the keys live in
      # secrets/pirateship.yaml and secrets/orthanc.yaml. Enabling them is a
      # deliberate second step; see the block at the bottom of this file.
      # ---------------------------------------------------------------
      {
        Media = [
          { Jellyfin = { href = "https://jellyfin.theshire.io"; description = "Media server"; icon = "jellyfin.png"; }; }
          { YouTube = { href = "https://yt.theshire.io"; description = "Invidious (Materialious UI)"; icon = "invidious.png"; }; }
          { "Music Assistant" = { href = "https://listen.theshire.io"; description = "Multi-room audio"; icon = "music-assistant.png"; }; }
          { Navidrome = { href = "https://stream.theshire.io"; description = "Music server"; icon = "navidrome.png"; }; }
        ];
      }
      {
        Downloads = [
          { qBittorrent = { href = "https://dl.theshire.io"; description = "Torrent client"; icon = "qbittorrent.png"; }; }
          { SABnzbd = { href = "https://nzb.theshire.io"; description = "Usenet client"; icon = "sabnzbd.png"; }; }
          { Radarr = { href = "https://movies.theshire.io"; description = "Movie manager"; icon = "radarr.png"; }; }
          { Sonarr = { href = "https://tv.theshire.io"; description = "TV manager"; icon = "sonarr.png"; }; }
          { Prowlarr = { href = "https://prowlarr.theshire.io"; description = "Indexer manager"; icon = "prowlarr.png"; }; }
          { Lidarr = { href = "https://lidarr.theshire.io"; description = "Music manager"; icon = "lidarr.png"; }; }
          { Bazarr = { href = "https://subtitles.theshire.io"; description = "Subtitle manager"; icon = "bazarr.png"; }; }
        ];
      }
      {
        Home = [
          { "Home Assistant" = { href = "https://ha.theshire.io"; description = "Home automation"; icon = "home-assistant.png"; }; }
          { Vaultwarden = { href = "https://vault.theshire.io"; description = "Password manager"; icon = "vaultwarden.png"; }; }
        ];
      }
      {
        Infrastructure = [
          { Grafana = { href = "https://grafana.theshire.io"; description = "Metrics & alert rules"; icon = "grafana.png"; }; }
          {
            Gatus = {
              href = "https://monitor.theshire.io";
              description = "Service health monitor";
              icon = "gatus.png";
              # Read-only HTTP against Gatus's own API — it probes nothing
              # itself, so this adds no traffic to any monitored service.
              widget = {
                type = "gatus";
                url = "https://monitor.theshire.io";
              };
            };
          }
          { ntfy = { href = "https://ntfy.theshire.io"; description = "Push notifications"; icon = "ntfy.png"; }; }
          { "Nix cache" = { href = "https://cache.theshire.io"; description = "attic binary cache"; icon = "nixos.png"; }; }
        ];
      }
    ];

    bookmarks = [
      {
        Homelab = [
          { "GitHub Repo" = [ { href = "https://github.com/bcrescimanno/homelab-nix"; icon = "github.png"; } ]; }
        ];
      }
    ];
  };

  homelab.postUpgradeCheck.services = [ "homepage-dashboard" ];
}
