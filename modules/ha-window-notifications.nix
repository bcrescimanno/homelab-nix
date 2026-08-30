# modules/ha-window-notifications.nix — passive-cooling window prompts in HA
#
# Three household notifications, driven by the outdoor temperature at the house:
#
#   1. Morning  — outdoor temp climbs above 68°F  → "close the windows"
#   2. Evening  — outdoor temp falls below 72°F   → "open the windows"
#   3. If today's forecast high is below 75°F, 1 and 2 are suppressed entirely
#      and a single 08:00 notification says "Today is a windows open day!"
#
# "Today's forecast high" is sensor.forecast_high_today, which LATCHES the day's
# maximum rather than reading met.no live — met.no's daily figure decays to the
# current temperature as the day burns down, which silently made rule 2 unable
# to fire at all. See the long comment on that sensor before touching it.
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
# The sensor is an Eve Weather (Matter-over-Thread, IPX4, no cloud and no
# account), paired 2026-08-30 as Matter node 7 on rivendell's existing OTBR +
# Matter integration — no new coordinator, no new integration. See
# devices/temperature-humidity-sensors.md, which picked it for outdoor use.
#
# MOUNT IT IN PERMANENT SHADE: an outdoor sensor in direct sun reads 10–20°F
# high, which would fire "close the windows" every clear morning — and because
# sensor.forecast_high_today folds the observed temperature into its latch, a
# sunlit reading also poisons the open-day suppression for the rest of the day.
#
# ---------------------------------------------------------------------------
# How this reaches Home Assistant
# ---------------------------------------------------------------------------
#
# The existing household automations are UI-authored and live in
# automations.yaml. Rather than fight that, this module declares a HA *package*,
# which merges additively with the top-level `automation: !include
# automations.yaml` — so the UI-authored automations are untouched and remain
# UI-editable, while these are reproducible from the flake.
#
# The trade-off the packages mechanism buys us: a package can declare `template:`
# as well as `automation:`, which a bare automation include cannot. That matters
# because both sensors below are templates.
#
# HISTORY, because it explains why this file used to be much longer: under the
# HA container this had to render the package to a store path, bind-mount it at
# /config/nix-packages, and append the `homeassistant: packages:` key to the
# live configuration.yaml from a podman-homeassistant preStart hook — the
# container's /config was imperative and Nix had no other way in. Since HA went
# native (2026-08-01) configuration.yaml is itself Nix-rendered, so the package
# is simply another attribute in it. All of that machinery is gone; do not
# reintroduce it.
#
# ---------------------------------------------------------------------------
# Indirection through sensor.outdoor_temperature
# ---------------------------------------------------------------------------
#
# The automations never name the hardware. They read sensor.outdoor_temperature,
# a template sensor whose source is `outdoorSensor` below. That indirection is
# what made the 2026-08-30 hardware swap a one-line change with no automation
# edits; keep it. Setting outdoorSensor back to null restores the met.no
# forecast fallback, which is the way to keep the prompts running if the Eve
# ever has to come down.
#
# The fallback is deliberately NOT a silent runtime failover. Once outdoorSensor
# names a real entity, that entity going unavailable makes
# sensor.outdoor_temperature unavailable too — it does not quietly revert to
# forecast data and keep issuing confident-looking prompts. The dead-battery
# case is caught by the fourth automation, which alerts to ntfy after 2h.

{ config, pkgs, lib, ... }:

let
  # ---- Configuration ------------------------------------------------------

  # Entity ID of the physical outdoor temperature sensor. Set to the Eve Weather
  # 2026-08-30. Set back to null to fall back to the met.no forecast.
  #
  # NOT sensor.eve_weather_20ebs9901_temperature — the entities carrying the
  # serial in their ID are the Matter diagnostics (thread channel, reboot count,
  # radio faults) and every one of them is disabled_by: integration. The
  # measurement entities have the bare name.
  #
  # HA converts this for us: the Matter cluster reports Celsius, but the entity
  # registry has unit_of_measurement = °F because HA is configured
  # us_customary, so states() already returns °F. No conversion anywhere below.
  outdoorSensor = "sensor.eve_weather_temperature";

  # HA is configured us_customary, so every temperature below is already °F and
  # no conversion is needed anywhere in this file.
  #
  # Back to 68 on 2026-08-30, with the Eve Weather as the source. This sat at 66
  # from 2026-08-01, and the 2°F was pure margin for met.no's coarseness, not a
  # comfort judgement: met.no published WHOLE DEGREES on a ~56 min cadence, and
  # one morning it stepped 61 -> 68 in a single update. `above` is a strict
  # greater-than in HA, so a reading of exactly 68.0 satisfied neither the
  # trigger nor the condition, and the close prompt never fired on a day whose
  # forecast high was 96°F. Landing exactly on an integer threshold is routine
  # against a whole-degree source, not an edge case.
  #
  # The Eve removes the premise. Measured from the recorder the afternoon it was
  # paired: 78.08, 78.8, 79.16, 79.7, 80.06, 80.6, 80.528, 80.96, 81.5, 81.86 —
  # hundredths of a degree, every 30–90s. A sample cannot step over a threshold
  # band that is 0.5°F wide in practice, and exact-68.0 is now vanishingly
  # unlikely rather than routine. Compare the same window from met.no, which is
  # what the 66 was compensating for: 57, 62, 66, 71, 75, 80.
  #
  # If this ever reverts to the met.no fallback (outdoorSensor = null), put the
  # margin back — the trigger is only safe at 68 because the source is fine.
  closeAboveF = 68;   # morning: warmer than this outside → shut the house up

  # This carried the mirror of the bug described above — `below` is likewise
  # strict, so exactly 72.0 fires nothing and an hourly step from 75 -> 72 was
  # missed the same way. It was left at 72 pending a decision, because the fix
  # would have been to RAISE it (to ~74), and that is a real behaviour change:
  # windows get opened earlier and warmer.
  #
  # RESOLVED 2026-08-30 by the source change rather than by a threshold change.
  # The Eve's fractional 30–90s samples cross 72 continuously, so the crossing
  # the trigger needs is now always there to detect. 72 is the comfort number we
  # actually wanted, and it no longer needs padding to work.
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

  # "Today is not a windows-open day." A `>=` test so that exactly-75 lands on
  # the normal-rules side, matching the spec ("below 75" is the open-day case).
  #
  # Written as a template condition and NOT as `condition: not` wrapping a
  # numeric_state, which is what this used to be. That construction does the
  # opposite of what it looks like: a numeric_state condition on an `unknown` or
  # `unavailable` entity raises ConditionError, and HA's `not` collects those
  # errors and RE-RAISES rather than treating the inner check as false. An
  # unavailable forecast sensor would therefore have blocked both temperature
  # automations outright — silence, not degradation. The `float(999)` default
  # makes the intended behaviour real: no forecast reading → not an open day →
  # the temperature rules still run.
  notAnOpenDay = {
    condition = "template";
    value_template =
      "{{ states('sensor.forecast_high_today') | float(999) >= ${toString openAllDayBelowF} }}";
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

      # Today's high, LATCHED: the running maximum since local midnight of
      # (a) what met.no still forecasts for today and (b) what has actually been
      # measured outside. Trigger-based because the daily figure only comes back
      # from the weather.get_forecasts action and a plain template sensor cannot
      # call actions. Re-read every 30 min (so it is populated well before the
      # 08:00 announcement even if HA restarted at 07:50) and whenever met.no
      # itself updates; the /30 pattern also lands on 00:00, which is the reset.
      #
      # THE LATCH IS THE WHOLE POINT — do not simplify it back to a plain read of
      # the daily forecast. Diagnosed 2026-08-22, after the evening "open the
      # windows" prompt had never fired even once (last_triggered was still null
      # weeks after deployment, while the morning prompt fired daily).
      #
      # met.no's daily forecast entry for TODAY reports the maximum over the
      # hours REMAINING in the day, not the calendar day's high. So it decays as
      # the day burns down, and from roughly 16:00 onward it is numerically
      # identical to the current outdoor temperature. Measured on rivendell's
      # recorder, 2026-08-21:
      #
      #     time    outdoor   "forecast high"
      #     16:18     83            83
      #     18:14     77            77
      #     20:10     69            69
      #     21:08     67            67
      #
      # That made the evening automation structurally unfireable. It needs
      # outdoor < 72 AND notAnOpenDay (high >= 75) to hold at the same instant,
      # but the decayed "high" tracks the temperature exactly — so the moment the
      # temperature condition passed, the open-day suppression killed the run.
      # Not a threshold that needed tuning: the two conditions were mutually
      # exclusive by construction, on every single day.
      #
      # Latching to the daily max fixes it because the value the evening rule
      # reads is then the same one the 08:00 announcement decided on, which is
      # what "is today a windows-open day" actually means. Folding in the
      # observed outdoor temperature closes the mirror hole: a day forecast at
      # 74 (open day) that really hits 79 now un-suppresses itself and gets its
      # close prompt, instead of the house cooking behind an 08:00 all-clear.
      #
      # Revising the forecast DOWN mid-day cannot lower the latch. That is the
      # right failure direction and matches closeAboveF above: a redundant
      # prompt costs nothing, a missed one costs a hot house.
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
          # high_for_date scopes the latch to one calendar day. It is compared
          # against `this`, which is the state BEFORE this update, so a restart
          # carries the day's high across (trigger-based template entities
          # restore) while a rollover past midnight discards it.
          #
          # Select today by date rather than trusting forecast[0] — after
          # met.no's daily rollover index 0 is already tomorrow, and late in the
          # day today drops out of the list entirely. Every conversion carries an
          # explicit default: HA's float/int filters RAISE without one, which in
          # a state template means the sensor goes unavailable.
          state = ''
            {% set days = forecasts['${forecastEntity}'].forecast %}
            {% set today_str = now().strftime('%Y-%m-%d') %}
            {% set today = days | selectattr('datetime', 'search', today_str) | list %}
            {% set forecast_high = (today[0].temperature | float(-999) | round(0) | int) if today else -999 %}
            {% set latched = (this.state | int(-999)) if this.attributes.get('high_for_date') == today_str else -999 %}
            {% set observed = states('sensor.outdoor_temperature') | float(-999) | round(0) | int %}
            {% set best = [forecast_high, latched, observed] | max %}
            {{ best if best > -999 else (days[0].temperature | float(0) | round(0) | int) }}
          '';
          attributes.high_for_date = "{{ now().strftime('%Y-%m-%d') }}";
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
          # most (already above the threshold at first light, so no crossing
          # follows).
          { trigger = "sun"; event = "sunrise"; offset = "00:05:00"; }

          # Standing-state re-evaluation. Added 2026-08-01 after the prompt
          # failed to fire on a 96°F day even with the threshold at 66.
          #
          # A crossing is not a dependable signal against this data source, and
          # the sunrise trigger only covers the once-daily case. Two ways the
          # crossing is lost:
          #
          #   1. HA restarts after sunrise while already warm. Measured that
          #      day: the sensor's FIRST value after restart was 68.0, i.e.
          #      already above 66, so there was no below->above transition to
          #      detect, and the following 68.0 -> 74.0 step is above->above.
          #      The automation had no live trigger for the rest of the day.
          #      Auto-upgrade restarts at 04:20 (pre-sunrise, harmless), but any
          #      daytime deploy reopens this hole.
          #   2. met.no publishes whole degrees roughly hourly, so it can step
          #      clean over a threshold band between two samples.
          #
          # Polling every 30 min sidesteps both. It is safe because it changes
          # nothing about WHEN the prompt is allowed — the conditions below still
          # gate on temperature, sunrise, the noon cutoff, the open-day check,
          # and oncePerDay, so the worst case remains exactly one prompt per day.
          { trigger = "homeassistant"; event = "start"; }
          { trigger = "time_pattern"; minutes = "/30"; }
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
          # Same standing-state re-evaluation as the morning rule — see the long
          # comment there. The 16:00 trigger is the evening's equivalent of
          # sunrise and has the same weakness: it fires once, so an HA restart
          # after 16:00 on an already-cool evening leaves no live trigger.
          { trigger = "homeassistant"; event = "start"; }
          { trigger = "time_pattern"; minutes = "/30"; }
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
      # LIVE as of 2026-08-30 — it could never fire while outdoorSensor was
      # null, because the met.no fallback is always available.
      #
      # The 2h window is doing real work now: the Eve sits at the edge of Thread
      # range (-93 dBm, Link Quality 1 of 3, and rivendell's border router is
      # the only router in the mesh), so brief dropouts are plausible and should
      # NOT page anyone. Two hours of silence is a flat battery or a dead link;
      # ninety seconds is weather. Do not shorten this without first adding a
      # Thread router to the mesh.
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

in
{
  # Declared inline as a Home Assistant *package*, which merges additively with
  # the top-level `automation: !include automations.yaml` in
  # modules/homeassistant.nix — so the UI-authored automations are untouched and
  # remain UI-editable, while these are reproducible from the flake.
  #
  # A package rather than a bare automation list because a package can also
  # declare `template:`, and both sensors above are templates.
  services.home-assistant.config.homeassistant.packages.windows = windowsPackage;
}
