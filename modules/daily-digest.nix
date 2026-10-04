# modules/daily-digest.nix — the morning digest page on rivendell
#
# One static page at https://digest.theshire.io: weather, today's calendar,
# chores, markets (workdays only) and five Claude-summarized stories each of US, world
# and tech news. Built by modules/daily-digest.py on a timer, served by Caddy,
# and announced by a Home Assistant push (modules/ha-daily-digest.nix).
#
# SCHEDULE
#
#   workday  build 07:25, push 07:45
#   weekend  build 08:10, push 08:30     (Saturdays, Sundays AND holidays)
#
# Both timers fire every day. The script decides whether today is a workday
# and exits as a no-op when the slot does not match, so the holiday calendar
# lives in exactly one place (`holidays` below) and HA never computes it. HA
# pushes only when latest.json names today and the matching slot.
#
# Deliberately NOT tied to the phone alarm: there is no alarm on weekends, and
# on weekdays the digest is wanted later than the alarm.
#
# WHAT LEAVES THE LAB
#
# Only news headlines and RSS descriptions go to the Claude API. The calendar,
# chores, weather and markets are rendered as fetched, so calendar contents never reach
# a model. Claude returns candidate IDs, not URLs, and the script maps each ID
# back to its feed link, so a summary cannot carry an invented link.
#
# Gossip is kept out at two layers: the feeds are section feeds of serious
# outlets (never front pages, which is where celebrity coverage leaks in), and
# `exclude` below is handed to Claude as a hard rule.
#
# FAILURE BEHAVIOUR
#
# Each section degrades on its own and is listed under "Problems" on the page
# and in the push. If Claude is unavailable the news falls back to the newest
# headlines, unfiltered, and says so. The unit fails — and OnFailure pushes to
# ntfy — only when the page could not be written at all. A digest that never
# appears is caught by HA's 08:45 check (see modules/ha-daily-digest.nix).
#
# WORK CALENDAR (not wired, 2026-10-03)
#
# The work Google Workspace blocks every self-serve route: secret iCal is
# disabled by the admin, OAuth returns `Error 400: access_not_configured`
# (unconfigured third-party apps restricted), and external sharing is
# free/busy only. Do NOT make the calendar public to use its "public address".
# If IT approves the OAuth client, it becomes a second entry in `calendars`
# with a new source type in daily-digest.py; nothing else changes. The OAuth
# app must be set to "In production" — Testing-mode refresh tokens expire after
# 7 days.
#
# MARKET DATA
#
# Yahoo's chart endpoint is unofficial and keyless; it is used because it is
# the only free source with INDEX levels (Finnhub's free tier has stocks and
# ETFs but not indexes; Alpha Vantage allows 25 requests/day). ~5 requests a
# day. If it breaks for good, a free Finnhub key with SPY/QQQ/DIA as proxies
# gives the same percentage moves without the levels.
#
# CHORES
#
# Read from Home Assistant's sensor.chores (modules/ha-chores.nix), which owns
# the list of chores and the latching that rides out the Roborock's cloud
# flaps. This script only renders what that sensor says; an HA it cannot reach
# is a problem line, never an empty list.
#
# Required sops secrets (secrets/rivendell.yaml), all env-file format:
#   digest_anthropic_env   ANTHROPIC_API_KEY=sk-ant-...
#   digest_ha_env          HA_TOKEN=<long-lived access token>
#     (HA profile → Security → Long-lived access tokens; it acts as the user
#     who created it, so read-only use is a matter of what this script does)
#   digest_icloud_env      ICLOUD_USERNAME=<Apple ID email>
#                          ICLOUD_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
#     (an app-specific password from account.apple.com → Sign-In and
#     Security → App-Specific Passwords; the Apple ID password will not work)
#
# Rebuild now, whatever the day (does not push — HA pushes on its schedule):
#   sudo systemctl start daily-digest@today
#
# The vhost is in modules/caddy.nix with the others; it serves /var/lib/daily-digest/www.

{ config, pkgs, lib, ... }:

let
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host = config.networking.hostName;
  outputDir = "/var/lib/daily-digest/www";

  digestConfig = {
    timezone = config.time.timeZone;
    inherit outputDir;
    url = "https://digest.theshire.io/";

    holidays = {
      country = "US";
      # Which python-holidays names count as a day off. Exact names; each also
      # matches its "(observed)" variant (a Saturday July 4th is observed on
      # Friday the 3rd). Every US
      # federal holiday except Columbus Day, which is a workday.
      observe = [
        "New Year's Day"
        "Martin Luther King Jr. Day"
        "Washington's Birthday"           # Presidents Day
        "Memorial Day"
        "Juneteenth National Independence Day"
        "Independence Day"
        "Labor Day"
        "Veterans Day"
        "Thanksgiving Day"
        "Christmas Day"
      ];
      # Days off relative to a holiday whose date moves: the Wednesday before
      # and the Friday after Thanksgiving.
      adjacent = {
        "Thanksgiving Day" = [ (-1) 1 ];
      };
      # Extra days off that follow the weekend schedule (company holidays,
      # PTO). ISO dates. Past dates are harmless; prune whenever.
      extra = [ ];
    };

    weather = {
      # NWS forecast grid cell for home (2.5 km square), derived from HA's home
      # location via api.weather.gov/points. Not the coordinates themselves.
      gridpoint = "MTR/99,77";
      station = "KSJC";   # current conditions; also the reference station
                          # used to score forecast accuracy elsewhere
    };

    calendars = [
      {
        type = "caldav";
        url = "https://caldav.icloud.com/";
        usernameEnv = "ICLOUD_USERNAME";
        passwordEnv = "ICLOUD_APP_PASSWORD";
        # Display names, matched exactly. A missing one is reported as a
        # problem with the server's actual list in the journal.
        names = [
          "Travel and Events"
          "Family"
          "Home schedule- recurring events"
        ];
      }
    ];

    chores = {
      url = "http://127.0.0.1:8123/api/states/sensor.chores";
      tokenEnv = "HA_TOKEN";
    };

    markets = {
      indexes = [
        { symbol = "^GSPC"; name = "S&P 500"; }
        { symbol = "^IXIC"; name = "Nasdaq"; }
        { symbol = "^DJI"; name = "Dow"; }
      ];
      tickers = [ "AAPL" "SHOP" ];
    };

    news = {
      model = "claude-opus-5-5";
      effort = "low";
      itemsPerSection = 5;
      perFeed = 12;        # newest N per feed go to Claude
      maxAgeHours = 36;

      sections = [
        {
          id = "us";
          title = "US";
          feeds = [
            { name = "NPR";          url = "https://feeds.npr.org/1003/rss.xml"; }
            { name = "PBS NewsHour"; url = "https://www.pbs.org/newshour/feeds/rss/nation"; }
            { name = "The Guardian"; url = "https://www.theguardian.com/us-news/rss"; }
          ];
        }
        {
          id = "world";
          title = "World";
          feeds = [
            { name = "BBC";          url = "https://feeds.bbci.co.uk/news/world/rss.xml"; }
            { name = "The Guardian"; url = "https://www.theguardian.com/world/rss"; }
            { name = "NPR";          url = "https://feeds.npr.org/1004/rss.xml"; }
          ];
        }
        {
          id = "tech";
          title = "Tech";
          feeds = [
            { name = "Phoronix";    url = "https://www.phoronix.com/rss.php"; }
            { name = "LWN";         url = "https://lwn.net/headlines/rss"; }
            { name = "Hacker News"; url = "https://hnrss.org/frontpage?points=150"; }
          ];
        }
      ];

      # Handed to Claude verbatim as "never choose items about".
      exclude = [
        "celebrities, celebrity relationships and gossip"
        "reality television and entertainment-industry news (box office, TV ratings, awards shows, music charts)"
        "royal families"
        "lifestyle, horoscopes, viral social-media trends and human-interest fluff"
        "shopping guides, deals and product roundups"
      ];
    };
  };

  configFile = pkgs.writeText "daily-digest.json" (builtins.toJSON digestConfig);

  python = pkgs.python3.withPackages (ps: with ps; [
    anthropic
    caldav
    feedparser
    holidays
    icalendar
    recurring-ical-events
  ]);

  mkTimer = slot: time: {
    description = "Build the daily digest (${slot} schedule)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* ${time}";
      Unit = "daily-digest@${slot}.service";
      # A late build still updates the page; HA's push window is what it is.
      Persistent = true;
    };
  };
in

{
  users.users.daily-digest = { isSystemUser = true; group = "daily-digest"; };
  users.groups.daily-digest = { };

  sops.secrets.digest_anthropic_env = { };
  sops.secrets.digest_icloud_env = { };
  sops.secrets.digest_ha_env = { };

  # Template unit: %i is the slot (weekday|weekend|today). Static user rather than
  # DynamicUser: a DynamicUser StateDirectory lives under /var/lib/private,
  # which is 0700 and would keep Caddy from reading the page.
  systemd.services."daily-digest@" = {
    description = "Build the daily digest (%i)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;

    serviceConfig = {
      Type = "oneshot";
      User = "daily-digest";
      Group = "daily-digest";
      TimeoutStartSec = "15m";
      StateDirectory = "daily-digest";
      StateDirectoryMode = "0755";
      EnvironmentFile = [
        config.sops.secrets.digest_anthropic_env.path
        config.sops.secrets.digest_icloud_env.path
        config.sops.secrets.digest_ha_env.path
      ];
      ExecStart = "${python}/bin/python3 ${./daily-digest.py} --config ${configFile} %i";

      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };

    unitConfig.OnFailure = "daily-digest-notify-failure.service";
  };

  systemd.services.daily-digest-notify-failure = {
    description = "Notify ntfy that the daily digest failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.curl}/bin/curl -s --connect-timeout 5 --max-time 30 \
          --retry 3 --retry-delay 10 --retry-all-errors \
          -H 'Title: Daily digest FAILED' \
          -H 'Priority: 3' \
          -H 'Tags: warning' \
          -d '${host} could not write the daily digest — check journalctl -u "daily-digest@*"' \
          ${ntfyUrl}
      '';
    };
  };

  systemd.timers.daily-digest-weekday = mkTimer "weekday" "07:25:00";
  systemd.timers.daily-digest-weekend = mkTimer "weekend" "08:10:00";
}
