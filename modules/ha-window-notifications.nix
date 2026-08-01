# modules/ha-window-notifications.nix — passive-cooling window prompts in HA
#
# Three household notifications, driven by the outdoor temperature at the house:
#
#   1. Morning  — outdoor temp climbs above 68°F  → "close the windows"
#   2. Evening  — outdoor temp falls below 72°F   → "open the windows"
#   3. If today's forecast high is below 75°F, 1 and 2 are suppressed entirely
#      and a single 08:00 notification says "Today is a windows open day!"
#
# ---------------------------------------------------------------------------
# Why a local sensor and not Weather Underground
# ---------------------------------------------------------------------------
#
# Weather Underground only issues API keys to accounts that already own a PWS
# actively uploading observations, so there is no supported path to reading a
# neighbour's station. Buying hardware is unavoidable either way, and once you
# are buying hardware a sensor in your own yard beats a station a mile off.
#
# The target sensor is an Eve Weather (Matter-over-Thread, IPX4, no cloud and no
# account). rivendell already runs OTBR + the Matter integration, so it pairs
# with no new coordinator and no new integration — see
# devices/temperature-humidity-sensors.md, which already picked it for outdoor
# use. MOUNT IT IN PERMANENT SHADE: an outdoor sensor in direct sun reads
# 10–20°F high, which would fire "close the windows" every clear morning.
#
# ---------------------------------------------------------------------------
# How this reaches Home Assistant
# ---------------------------------------------------------------------------
#
# HA runs as a container with an imperative /config volume, and the five
# existing automations are UI-authored and live in automations.yaml. Rather than
# fight that, this module renders a HA *package* into a read-only store path
# mounted at /config/nix-packages. Packages merge additively with the top-level
# `automation: !include automations.yaml`, so the UI-authored automations are
# untouched and remain UI-editable, while these are reproducible from the flake.
#
# The trade-off the packages mechanism buys us: a package can declare `template:`
# as well as `automation:`, which a bare automation include cannot. That matters
# because both sensors below are templates.
#
# The one line of configuration.yaml this needs is added by an idempotent
# preStart hook (same reconcile-in-place pattern as the qBittorrent preStart),
# rather than by mounting a Nix-rendered configuration.yaml over the live one.
# A bad render there would leave HA unable to start, and deploy-rs would NOT
# catch it — the container starts fine, HA fails inside it.
#
# ---------------------------------------------------------------------------
# Indirection through sensor.outdoor_temperature
# ---------------------------------------------------------------------------
#
# The automations never name the hardware. They read sensor.outdoor_temperature,
# a template sensor whose source is `outdoorSensor` below. Until the Eve is
# paired that is null and the sensor falls back to the met.no forecast, so the
# logic can be deployed and watched now; swapping in the real hardware is then a
# one-line change and the automations do not move.
#
# The fallback is deliberately NOT a silent runtime failover. Once outdoorSensor
# names a real entity, that entity going unavailable makes
# sensor.outdoor_temperature unavailable too — it does not quietly revert to
# forecast data and keep issuing confident-looking prompts. The dead-battery
# case is caught by the fourth automation, which alerts to ntfy after 2h.

{ config, pkgs, lib, ... }:

let
  # ---- Configuration ------------------------------------------------------

  # Entity ID of the physical outdoor temperature sensor. Set this once the Eve
  # Weather is paired — it will be something like "sensor.eve_weather_temperature"
  # (confirm the exact ID in Developer Tools → States after commissioning).
  # While null, sensor.outdoor_temperature reads the met.no forecast instead.
  outdoorSensor = null;

  # HA is configured us_customary, so every temperature below is already °F and
  # no conversion is needed anywhere in this file.
  closeAboveF = 68;   # morning: warmer than this outside → shut the house up
  openBelowF = 72;    # evening: cooler than this outside → let the night in
  openAllDayBelowF = 75;  # forecast high under this → skip 1 & 2 entirely

  # Sun-relative morning, clock-bounded evening.
  morningEndsAt = "12:00:00";
  eveningStartsAt = "16:00:00";
  eveningEndsAt = "22:00:00";
  openDayAnnouncementAt = "08:00:00";

  # A threshold has to hold this long before firing, so a sensor that jitters
  # across the line on a gusty morning does not produce a burst of prompts.
  sustainedFor = "00:10:00";

  # Household push targets. These are actionable prompts for whoever is home,
  # so they go to phones — not to the ntfy homelab topic, which carries infra
  # alerts (backups, upgrades, freshness) and would be diluted by them.
  phones = [ "notify.brians_iphone_14" "notify.queen_s_iphone14_pro" ];

  # Infrastructure alerting, for the sensor-health automation only.
  infraNotify = "notify.homelab_alerts";

  forecastEntity = "weather.forecast_home";  # met.no

  # ---- Derived ------------------------------------------------------------

  # These must go through notify.send_message targeting the notify ENTITY, not
  # `action: notify.<entity>`. mobile_app registers its legacy services under a
  # different name than its entity (notify.mobile_app_brians_iphone_14 vs the
  # entity notify.brians_iphone_14), and the ntfy integration registers no legacy
  # service at all — so naming the entity as if it were a service fails at run
  # time, per-action, with nothing but a log line. Verified against
  # /api/services on rivendell rather than assumed.
  notify = title: message:
    map (target: {
      action = "notify.send_message";
      target.entity_id = target;
      data = { inherit title message; };
    }) phones;

  # Only fire once per calendar day. `last_triggered` is set when the actions
  # actually run (i.e. after conditions pass), so this reads as "we have not
  # already said this today". It is stored UTC; as_local() is required or the
  # guard misbehaves for the eight hours either side of local midnight.
  oncePerDay = {
    condition = "template";
    value_template = ''
      {{ this.attributes.last_triggered is none
         or as_local(this.attributes.last_triggered).date() != now().date() }}
    '';
  };

  # "Today is not a windows-open day." Written as a negated `below` rather than
  # `above: 75` so that exactly-75 lands on the normal-rules side, matching the
  # spec ("below 75" is the open-day case). If the forecast sensor is unknown
  # the inner check is false and this passes — an unavailable forecast degrades
  # to running the temperature rules, not to silence.
  notAnOpenDay = {
    condition = "not";
    conditions = [{
      condition = "numeric_state";
      entity_id = "sensor.forecast_high_today";
      below = openAllDayBelowF;
    }];
  };

  outdoorTemperatureSensor =
    if outdoorSensor == null then {
      name = "Outdoor Temperature";
      unique_id = "homelab_outdoor_temperature";
      device_class = "temperature";
      state_class = "measurement";
      unit_of_measurement = "°F";
      availability = "{{ state_attr('${forecastEntity}', 'temperature') is not none }}";
      state = "{{ state_attr('${forecastEntity}', 'temperature') | round(1) }}";
      attributes.source = "${forecastEntity} (forecast — no hardware sensor configured)";
    } else {
      name = "Outdoor Temperature";
      unique_id = "homelab_outdoor_temperature";
      device_class = "temperature";
      state_class = "measurement";
      unit_of_measurement = "°F";
      availability = "{{ states('${outdoorSensor}') not in ['unknown', 'unavailable'] }}";
      state = "{{ states('${outdoorSensor}') | float | round(1) }}";
      attributes.source = outdoorSensor;
    };

  windowsPackage = {
    template = [
      { sensor = [ outdoorTemperatureSensor ]; }

      # Today's forecast high. This has to be trigger-based: the daily high only
      # comes back from the weather.get_forecasts action, and a plain template
      # sensor cannot call actions. Re-read every 30 min (so it is populated well
      # before the 08:00 announcement even if HA restarted at 07:50) and whenever
      # met.no itself updates.
      {
        triggers = [
          { trigger = "time_pattern"; minutes = "/30"; }
          { trigger = "homeassistant"; event = "start"; }
          { trigger = "state"; entity_id = forecastEntity; }
        ];
        actions = [{
          action = "weather.get_forecasts";
          target.entity_id = forecastEntity;
          data.type = "daily";
          response_variable = "forecasts";
        }];
        sensor = [{
          name = "Forecast High Today";
          unique_id = "homelab_forecast_high_today";
          device_class = "temperature";
          state_class = "measurement";
          unit_of_measurement = "°F";
          # Select by date rather than trusting forecast[0] to be today — after
          # met.no's daily rollover index 0 can already be tomorrow, which would
          # silently drive the open-day decision off the wrong day.
          state = ''
            {% set days = forecasts['${forecastEntity}'].forecast %}
            {% set today = days | selectattr('datetime', 'search', now().strftime('%Y-%m-%d')) | list %}
            {{ (today[0].temperature if today else days[0].temperature) | round(0) | int }}
          '';
        }];
      }
    ];

    automation = [
      # 1. Open-all-day announcement.
      {
        id = "homelab_windows_open_day";
        alias = "Windows: open-all-day announcement";
        mode = "single";
        triggers = [{ trigger = "time"; at = openDayAnnouncementAt; }];
        conditions = [{
          condition = "numeric_state";
          entity_id = "sensor.forecast_high_today";
          below = openAllDayBelowF;
        }];
        actions = notify "Windows open day"
          "Today is a windows open day! Forecast high {{ states('sensor.forecast_high_today') }}°F.";
      }

      # 2. Morning warm-up → close up.
      {
        id = "homelab_windows_close_morning";
        alias = "Windows: close (morning warm-up)";
        mode = "single";
        # The sunrise trigger is not redundant with the numeric_state one. A
        # numeric_state trigger fires only on a *crossing*, so after a warm night
        # that never dipped below 68°F there is no crossing to catch and the
        # prompt would never be sent. Sunrise re-evaluates the standing state;
        # the matching condition below keeps that trigger honest.
        triggers = [
          {
            trigger = "numeric_state";
            entity_id = "sensor.outdoor_temperature";
            above = closeAboveF;
            "for" = sustainedFor;
          }
          # +5min offset, not bare sunrise: firing at the exact instant of
          # sunrise races the `after: sunrise` condition below, and losing that
          # race silently drops the prompt on precisely the mornings that matter
          # most (already above 68°F at first light, so no crossing follows).
          { trigger = "sun"; event = "sunrise"; offset = "00:05:00"; }
        ];
        conditions = [
          {
            condition = "numeric_state";
            entity_id = "sensor.outdoor_temperature";
            above = closeAboveF;
          }
          { condition = "sun"; after = "sunrise"; }
          { condition = "time"; before = morningEndsAt; }
          notAnOpenDay
          oncePerDay
        ];
        actions = notify "Close the windows"
          "It's {{ states('sensor.outdoor_temperature') }}°F outside and climbing — shut the windows to hold the cool air. High of {{ states('sensor.forecast_high_today') }}°F today.";
      }

      # 3. Evening cool-down → open up.
      {
        id = "homelab_windows_open_evening";
        alias = "Windows: open (evening cool-down)";
        mode = "single";
        # Same reasoning as above, mirrored: on a day that peaked at 78°F and
        # dropped under 72°F at 15:30, the crossing happens before the evening
        # window opens and would otherwise be missed entirely. The 16:00 trigger
        # re-checks the standing state at the moment the window opens.
        triggers = [
          {
            trigger = "numeric_state";
            entity_id = "sensor.outdoor_temperature";
            below = openBelowF;
            "for" = sustainedFor;
          }
          { trigger = "time"; at = eveningStartsAt; }
        ];
        conditions = [
          {
            condition = "numeric_state";
            entity_id = "sensor.outdoor_temperature";
            below = openBelowF;
          }
          { condition = "time"; after = eveningStartsAt; before = eveningEndsAt; }
          notAnOpenDay
          oncePerDay
        ];
        actions = notify "Open the windows"
          "It's dropped to {{ states('sensor.outdoor_temperature') }}°F outside — open the windows and let the house cool down.";
      }

      # 4. Dead-man's switch on the temperature source.
      #
      # Without this, a flat Eve battery looks exactly like a stretch of days
      # where no threshold happened to be crossed: silence. Silence cannot
      # distinguish "working" from "broken and mute", so the broken case has to
      # announce itself. Goes to the infra topic, not to phones — this is an
      # operator problem, not a household one.
      #
      # NOTE: while outdoorSensor is null this can never fire, because the
      # met.no fallback is always available. It becomes live with the hardware.
      {
        id = "homelab_outdoor_temp_unavailable";
        alias = "Windows: outdoor temperature sensor unavailable";
        mode = "single";
        triggers = [{
          trigger = "state";
          entity_id = "sensor.outdoor_temperature";
          to = [ "unavailable" "unknown" ];
          "for" = "02:00:00";
        }];
        actions = [{
          action = "notify.send_message";
          target.entity_id = infraNotify;
          data = {
            title = "Outdoor temperature sensor is down";
            message = "sensor.outdoor_temperature has been unavailable for 2h — the window open/close notifications are not running. Check the Eve Weather battery.";
          };
        }];
      }
    ];
  };

  packagesDir = pkgs.runCommand "ha-nix-packages" { } ''
    mkdir -p $out
    cp ${(pkgs.formats.yaml { }).generate "windows.yaml" windowsPackage} $out/windows.yaml
  '';
in
{
  virtualisation.oci-containers.containers.homeassistant.volumes = [
    "${packagesDir}:/config/nix-packages:ro"
  ];

  # Add the packages include to configuration.yaml if it is not already there.
  #
  # This appends a top-level `homeassistant:` block, so it refuses to run if one
  # already exists — a duplicate top-level key is a YAML error that would stop HA
  # from starting. Failing the deploy is recoverable; corrupting configuration.yaml
  # on a host whose HA config is not otherwise in git is not.
  systemd.services.podman-homeassistant.preStart = ''
    CFG=/var/lib/homeassistant/config/configuration.yaml

    if [ ! -f "$CFG" ]; then
      echo "configuration.yaml not found at $CFG — is the HA config volume mounted?" >&2
      exit 1
    fi

    if ${pkgs.gnugrep}/bin/grep -qE '^[[:space:]]*packages:[[:space:]]*!include_dir_named[[:space:]]+nix-packages' "$CFG"; then
      exit 0
    fi

    if ${pkgs.gnugrep}/bin/grep -qE '^homeassistant:' "$CFG"; then
      echo "configuration.yaml already declares a top-level 'homeassistant:' block." >&2
      echo "Add this under it by hand, then redeploy:" >&2
      echo "  packages: !include_dir_named nix-packages" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/cp -a "$CFG" "$CFG.bak-$(${pkgs.coreutils}/bin/date +%Y%m%d%H%M%S)"
    ${pkgs.coreutils}/bin/cat >> "$CFG" <<'EOF'

# Added by NixOS — modules/ha-window-notifications.nix
# Nix-rendered packages are mounted read-only at /config/nix-packages.
homeassistant:
  packages: !include_dir_named nix-packages
EOF
  '';
}
