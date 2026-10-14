# modules/ha-window-notifications.nix — passive-cooling window prompts in HA
#
# Three household notifications, driven by the outdoor temperature at the house:
#
#   1. Warming  — outdoor temp climbs above 68°F after sunrise, while the day
#                 has NOT yet peaked → "close the windows"
#   2. Cooling  — outdoor temp falls below 72°F once the day HAS peaked (no
#                 crossing by 21:00 means no prompt that night)
#                 → "open the windows"
#   3. If today's forecast high is below 75°F, 1 and 2 are suppressed entirely
#      and a single 08:00 notification says "Today is a windows open day!"
#
# Rule 3's verdict is published as binary_sensor.windows_open_day so that
# nothing else contradicts it: modules/ha-hvac-openings.nix reads it to hold
# back its warm-side "Close up the house" reminder, which fires above 72°F and
# so used to nag four times on 2026-10-13, an announced open day that peaked
# at 73.2°F.
#
# "Peaked" is binary_sensor.outdoor_past_peak, judged from the measured
# temperature curve — see the comment on it. Until 2026-10-11 rules 1 and 2
# were gated on clock windows instead (before 12:00 / 16:00–21:00), which were
# a stand-in for "is it still warming up" from the met.no era.
#
# 1 and 2 are also held back while the house is ALREADY in the state they would
# ask for — every sensor in lib/ha-openings.nix reporting closed (1) or open
# (2). See `notAlready` below.
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
# PLACEMENT: SHADE IS NECESSARY BUT NOT SUFFICIENT — IT NEEDS AIRFLOW.
#
# Measured 2026-08-30 with the Eve mounted under a low roof eave: fully shaded,
# off metal, and still badly wrong. Delta against met.no across the day:
#
#     14:04  +6.2    17:13  -0.2    20:22  +1.0
#     15:07  +7.9    18:16  -2.2    21:25  +2.2
#     16:10  +6.5    19:19  -0.7    22:28  +2.1
#
# Two distinct errors. A sharp afternoon radiant load peaking near 15:00 at
# +7.9°F, which vanished within an hour of the sun leaving the wall — it fell
# 8.6°F in one hour while ambient fell 2°F. Then a steady +2.1°F overnight
# offset that appears after sunset and plateaus: the structure releasing stored
# heat into the still air trapped under the eave.
#
# The device itself is fine. At 17:13, between the two regimes, it read -0.2°F.
# A miscalibrated sensor cannot be right at one moment and 8°F wrong two hours
# earlier. Corroborated independently against local Weather Underground
# stations, which read 81-85°F while the Eve read 91.2°F.
#
# So: open air on all sides, on a post or railing, away from walls and roof.
# North-facing if there is a choice; a radiation shield is the proper answer.
#
# FIX PLACEMENT, NEVER THE THRESHOLDS. No threshold compensates for an error
# that swings 10°F over an afternoon. And the damage is not limited to one
# prompt: sensor.forecast_high_today folds the observed temperature into its
# daily latch, so an inflated afternoon reading raises the latch for the rest of
# the day — on 2026-08-30 it pushed the latch to 94 against met.no's 88, which
# on a borderline day flips the open-day suppression. The overnight offset is
# the more insidious one, because it peaks near dawn, which is exactly where
# closeAboveF is evaluated.
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
# because all four of its sensors are templates.
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
  # The Eve removes the premise, and RESOLUTION is why, not cadence. Measured
  # from the recorder the afternoon it was paired: 78.08, 78.8, 79.16, 79.7,
  # 80.06, 80.6, 80.528, 80.96, 81.5, 81.86 — hundredths of a degree. Against
  # met.no over the same window: 57, 62, 66, 71, 75, 80. A source with two
  # decimal places cannot step clean over a threshold, so landing on exactly
  # 68.0 goes from routine to vanishingly unlikely.
  #
  # Do not restate the cadence as "every 30-90s" — that was this device
  # EQUILIBRATING after being carried outdoors. Matter temperature reporting is
  # change-driven, so the interval is proportional to how fast the value is
  # moving: ~30-90s while it climbs, ~5 min once it settles (measured 3 reports
  # in the 15 min after the 13:01 cutover, while the raw entity sat near 83.6).
  #
  # That is a STRONGER guarantee than a fixed poll, and it is the real argument:
  # a change-driven source emits a report BECAUSE the value changed, so a
  # threshold crossing generates its own sample by construction. met.no's timer
  # had no such relationship to the data and could sleep straight through one.
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

  # "The day has peaked" = all three of:
  #
  #   - the sun is past solar noon (sun.sun `rising` is false). The daily
  #     maximum lags solar noon, so a dip before it is a cloud, not a peak;
  #   - the measured temperature is at least peakDropF below today's measured
  #     high (sensor.outdoor_high_today);
  #   - met.no's hourly forecast does not expect the rest of today to climb
  #     more than forecastRiseF above its own current hour. This catches a
  #     cloudy noon followed by a sunny afternoon, which the first two would
  #     misread as the peak.
  #
  # The forecast check compares met.no WITH ITSELF, never with the Eve. On
  # 2026-10-11 at 15:45 met.no's current hour said 74 while the Eve read 72.1;
  # comparing across the two sources would turn their offset into a fake
  # "still rising" signal. Its shape is trustworthy even where its level is
  # not.
  #
  # Replaced the old clock windows (close before 12:00, open after 16:00) on
  # 2026-10-11. Measured that day: peak 74.5°F at ~13:30, already 72.1 by 15:19,
  # so the open prompt was held to 16:00 for no reason; and the close prompt
  # fired at 11:49, 11 minutes before its cutoff would have dropped it.
  #
  # 2°F, not less: with hundredths resolution, a breeze moves the Eve by a
  # degree on its own. Not more either: on a borderline day (peak ~74) a
  # larger drop pushes the open prompt noticeably below openBelowF, because
  # both have to hold before it fires.
  peakDropF = 2;
  forecastRiseF = 1;   # met.no hourly is whole degrees; 1 absorbs rounding

  # Local time (America/Los_Angeles). eveningEndsAt moved 22:00 -> 21:00 on
  # 2026-10-03: an evening that is still above openBelowF at 9pm is not worth
  # opening up for. That is a comfort cutoff, not a stand-in for the peak, so
  # it survived the 2026-10-11 move to peak detection.
  eveningEndsAt = "21:00:00";
  openDayAnnouncementAt = "08:00:00";

  # A threshold has to hold this long before firing, so a sensor that jitters
  # across the line on a gusty morning does not produce a burst of prompts.
  sustainedFor = "00:10:00";

  # Household push targets. These are actionable prompts for whoever is home,
  # so they go to phones — not to the ntfy homelab topic, which carries infra
  # alerts (backups, upgrades, freshness) and would be diluted by them.
  #
  # NAME THE LIVE REGISTRATION, NOT THE PRETTIEST ENTITY ID. Corrected
  # 2026-09-01 after the morning prompt raised "Error sending notification to
  # Brian's iPhone 14" and delivered nothing. Both entities named here were
  # orphaned mobile_app config entries — the husks left behind when the iOS app
  # re-registers, which keep the original entity_id and hand the *new* entry a
  # suffixed one:
  #
  #   notify.brians_iphone_14       entry created 2024-08-10, last modified
  #                                 2024-12-13 — the same day the replacement
  #                                 entry was created. Its only entity is the
  #                                 notify one; the live registration owns the
  #                                 device_tracker and all ~20 sensors.
  #   notify.queen_s_iphone14_pro   superseded 2026-08-01, two minutes before
  #                                 Queen's iPhone16 Pro 2 was registered.
  #
  # The trap is that a husk KEEPS WORKING, for a long time, and then stops
  # without warning. Delivery to notify.brians_iphone_14 was confirmed daily by
  # the household right up to the evening of 2026-08-31 — twenty-one months
  # after the entry it belongs to was superseded. APNs held the old token valid
  # that entire time; it was invalidated some time overnight, and the next send
  # (10:00 on 2026-09-01) was the first to fail. So there was no period of
  # silent non-delivery to notice, and nothing to notice it with: the husk was
  # indistinguishable from the real thing until the moment it wasn't.
  #
  # Do not read the entity's state as proof of delivery either way. A notify
  # entity's state is the timestamp of its last send, and it advances whenever
  # the HTTP call to HA's push proxy does not raise. The proxy will accept a
  # push for a token APNs has already dropped, because APNs reports invalidation
  # asynchronously — so that timestamp confirms the request was accepted, never
  # that a phone rendered it. It is the only server-side evidence available, and
  # on 2026-09-01 the household was the instrument that actually caught this.
  #
  # When re-pointing these, check .storage/core.entity_registry for which
  # config_entry_id owns the entity and confirm that entry also owns the phone's
  # sensors. An entry whose sole entity is `notify.*` is a husk.
  phones = [ "notify.brians_iphone" "notify.queen_s_iphone16_pro_2" ];

  # Infrastructure alerting, for the sensor-health automation only.
  infraNotify = "notify.homelab_alerts";

  forecastEntity = "weather.forecast_home";  # met.no

  # The contact sensors that say whether the house is open. Shared with
  # ha-hvac-openings.nix so the two never disagree about what counts.
  openings = import ../lib/ha-openings.nix;

  # ---- Derived ------------------------------------------------------------

  # These must go through notify.send_message targeting the notify ENTITY, not
  # `action: notify.<entity>`. mobile_app registers its legacy services under a
  # different name than its entity (notify.mobile_app_brians_iphone_14 vs the
  # entity notify.brians_iphone_14), and the ntfy integration registers no legacy
  # service at all — so naming the entity as if it were a service fails at run
  # time, per-action, with nothing but a log line. Verified against
  # /api/services on rivendell rather than assumed.
  #
  # continue_on_error so one bad target cannot mute the household. HA scripts
  # abort the whole sequence on the first raising action, so on 2026-09-01 the
  # failure against Brian's phone at position 1 meant the action for Queen's
  # phone never ran at all — one stale registration silenced both recipients.
  # A push that fails for one person is not a reason to withhold it from the
  # other, and the per-action error is still logged either way.
  notify = title: message:
    map (target: {
      action = "notify.send_message";
      target.entity_id = target;
      data = { inherit title message; };
      continue_on_error = true;
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
  # in binary_sensor.windows_open_day, plus `not is_state(…, 'on')` here, make
  # the intended behaviour real: no forecast reading → not an open day → the
  # temperature rules still run.
  notAnOpenDay = {
    condition = "template";
    value_template = "{{ not is_state('binary_sensor.windows_open_day', 'on') }}";
  };

  # "The house is not already <state>" — passes when at least one opening is
  # NOT reporting `state` (`off` = closed, `on` = open). Added 2026-10-03: a
  # morning with everything already shut (nobody opened up because the house
  # was about to be empty) should not get "close the windows".
  #
  # Anything other than the exact target state counts as "not there yet",
  # including `unavailable`/`unknown` and an entity that does not exist
  # (states() returns 'unknown'). So a dark sensor never suppresses a prompt:
  # same failure direction as closeAboveF and the latch — a redundant prompt
  # costs nothing, a missed one costs a hot house.
  #
  # A failing condition does not burn the day. oncePerDay keys on
  # last_triggered, which only advances when the actions run, so the /30 poll
  # keeps re-checking: open a window at 10:00 on a warm morning and the close
  # prompt follows within 30 min. A template rather than `condition: not` over
  # a state condition, for the reason given on notAnOpenDay below.
  notAlready = state: {
    condition = "template";
    value_template =
      "{{ ${builtins.toJSON (builtins.attrNames openings)} | map('states') | reject('eq', '${state}') | list | length > 0 }}";
  };

  # Jinja that sets `rise` (how far met.no expects the rest of today to climb
  # above its own current hour; 0 with no data) and `fc_hours`, from the
  # `hourly` response variable of the past-peak entity below.
  #
  # forecast[0] is the CURRENT hour (verified 2026-10-11: at 15:45 local the
  # first entry was 22:00Z), so the rise is measured from now. Entries are UTC;
  # as_local() before comparing dates, or the evening hours land on tomorrow.
  forecastRise = ''
    {% set fc = hourly['${forecastEntity}'].forecast if hourly is defined and hourly and '${forecastEntity}' in hourly else [] %}
    {% set ns = namespace(temps=[]) %}
    {% for f in fc if as_local(as_datetime(f.datetime)).date() == now().date() %}
      {% set ns.temps = ns.temps + [f.temperature | float(0)] %}
    {% endfor %}
    {% set fc_hours = ns.temps | length %}
    {% set rise = ((ns.temps | max) - ns.temps[0]) if fc_hours > 0 else 0 %}
  '';

  # Whether the day has peaked, for the automation conditions. Only an
  # explicit `on` counts as past the peak; `unavailable` counts as not past it.
  # See binary_sensor.outdoor_past_peak for why that is the safe direction.
  pastPeak = {
    condition = "template";
    value_template = "{{ is_state('binary_sensor.outdoor_past_peak', 'on') }}";
  };
  notPastPeak = {
    condition = "template";
    value_template = "{{ not is_state('binary_sensor.outdoor_past_peak', 'on') }}";
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

      # Is today a windows-open day? The one place that is decided: the 08:00
      # announcement, notAnOpenDay, and the HVAC module's close reminder all
      # read this entity rather than re-deriving it from the forecast.
      #
      # It follows the forecast latch, so it can turn off mid-day (a day
      # forecast at 74 that really reaches 75 stops being an open day and gets
      # its close prompts back) but never back on. `float(999)`: no forecast
      # reading → off → every prompt and reminder still runs, the same
      # failure direction as notAnOpenDay always had.
      {
        binary_sensor = [{
          name = "Windows Open Day";
          unique_id = "homelab_windows_open_day";
          state =
            "{{ states('sensor.forecast_high_today') | float(999) < ${toString openAllDayBelowF} }}";
        }];
      }

      # Today's MEASURED high: the running maximum of sensor.outdoor_temperature
      # since local midnight, with the time it was reached. Deliberately
      # separate from forecast_high_today above, which folds met.no's forecast
      # into its latch and so can sit above anything the yard has actually
      # seen. The peak test needs the curve's real top.
      #
      # Same date-keyed latch as forecast_high_today: a restart carries the
      # value across (trigger-based template entities restore), and the /30
      # trigger lands on 00:00 to reset it. `this` is the state BEFORE this
      # update in every template here, so state and attributes agree on what
      # was latched.
      {
        triggers = [
          { trigger = "state"; entity_id = "sensor.outdoor_temperature"; }
          { trigger = "time_pattern"; minutes = "/30"; }
          { trigger = "homeassistant"; event = "start"; }
        ];
        sensor = [{
          name = "Outdoor High Today";
          unique_id = "homelab_outdoor_high_today";
          device_class = "temperature";
          state_class = "measurement";
          unit_of_measurement = "°F";
          state = ''
            {% set latched = (this.state | float(-999)) if this.attributes.get('high_for_date') == now().strftime('%Y-%m-%d') else -999 %}
            {% set best = [latched, states('sensor.outdoor_temperature') | float(-999)] | max %}
            {{ best if best > -999 else none }}
          '';
          attributes = {
            high_for_date = "{{ now().strftime('%Y-%m-%d') }}";
            high_at = ''
              {% set latched = (this.state | float(-999)) if this.attributes.get('high_for_date') == now().strftime('%Y-%m-%d') else -999 %}
              {% set t = states('sensor.outdoor_temperature') | float(-999) %}
              {{ now().isoformat() if t > -999 and t > latched else this.attributes.get('high_at') }}
            '';
          };
        }];
      }

      # Has today's temperature peaked? The three tests and their thresholds
      # are described at peakDropF; this is where they run.
      #
      # Re-evaluated on every outdoor reading and every 30 min. The forecast
      # read is HA's cached met.no data, not a network call, so calling it per
      # reading is cheap. It may run on the same state change that raises
      # outdoor_high_today and see the previous high, which cannot produce a
      # false "on": a new high means the current reading IS the high, so the
      # drop test fails against either value.
      #
      # Not latched for the day. If the afternoon climbs back to a new high,
      # the drop test fails and this goes off again, which is the truth.
      #
      # Failure directions: no forecast (action failed, or no hours left today)
      # → the forecast test passes and the other two decide. Temperature or
      # high unavailable → this is unavailable, and the automations read
      # unavailable as "not past peak": the close prompt can still fire and
      # the open prompt cannot, which is the same choice as closeAboveF and
      # notAlready (a redundant prompt costs nothing, a missed close costs a
      # hot house).
      {
        triggers = [
          { trigger = "state"; entity_id = "sensor.outdoor_temperature"; }
          { trigger = "time_pattern"; minutes = "/30"; }
          { trigger = "homeassistant"; event = "start"; }
        ];
        actions = [{
          action = "weather.get_forecasts";
          target.entity_id = forecastEntity;
          data.type = "hourly";
          response_variable = "hourly";
          continue_on_error = true;
        }];
        binary_sensor = [{
          name = "Outdoor Past Peak";
          unique_id = "homelab_outdoor_past_peak";
          availability =
            "{{ has_value('sensor.outdoor_temperature') and has_value('sensor.outdoor_high_today') }}";
          state = ''
            ${forecastRise}
            {% set drop = (states('sensor.outdoor_high_today') | float(0)) - (states('sensor.outdoor_temperature') | float(0)) %}
            {{ state_attr('sun.sun', 'rising') == false and drop >= ${toString peakDropF} and rise <= ${toString forecastRiseF} }}
          '';
          # Diagnostics, so "why hasn't it fired?" is answerable from the
          # entity alone.
          attributes = {
            drop_from_high = "{{ ((states('sensor.outdoor_high_today') | float(0)) - (states('sensor.outdoor_temperature') | float(0))) | round(1) }}";
            sun_rising = "{{ state_attr('sun.sun', 'rising') }}";
            forecast_rise_rest_of_today = ''
              ${forecastRise}
              {{ rise if fc_hours > 0 else none }}
            '';
          };
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
          condition = "state";
          entity_id = "binary_sensor.windows_open_day";
          state = "on";
        }];
        actions = notify "Windows open day"
          "Today is a windows open day! Forecast high {{ states('sensor.forecast_high_today') }}°F.";
      }

      # 2. Warming up → close up.
      #
      # The id still says "morning" from when this was clock-gated; it is the
      # entity registry key, so it stays.
      {
        id = "homelab_windows_close_morning";
        alias = "Windows: close (warming up)";
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
          # gate on temperature, sunrise, the peak, the open-day check, and
          # oncePerDay, so the worst case remains exactly one prompt per day.
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
          # Replaced a 12:00 cutoff. A day still climbing at 13:00 (morning fog,
          # a late warm front) now gets its prompt; a day that has turned over
          # does not, whatever the clock says.
          notPastPeak
          notAnOpenDay
          (notAlready "off")
          oncePerDay
        ];
        actions = notify "Close the windows"
          "It's {{ states('sensor.outdoor_temperature') }}°F outside and climbing — shut the windows to hold the cool air. High of {{ states('sensor.forecast_high_today') }}°F today.";
      }

      # 3. Cooling down → open up. Same registry-key note on the id as above.
      {
        id = "homelab_windows_open_evening";
        alias = "Windows: open (cooling down)";
        mode = "single";
        # Two conditions have to hold together — below openBelowF and past the
        # peak — and either can be the one that arrives second, so each gets a
        # trigger. Usually the peak comes first (2026-10-11: ~14:50, 2°F off
        # 74.5, then under 72 about half an hour later) and the temperature
        # trigger fires. A day that peaks below openBelowF without counting as
        # an open day (the forecast latch said 75+) is already under 72 when
        # it turns over, so there the past-peak trigger is the one that fires.
        triggers = [
          {
            trigger = "numeric_state";
            entity_id = "sensor.outdoor_temperature";
            below = openBelowF;
            "for" = sustainedFor;
          }
          # Sustained like the temperature trigger: the drop test can flicker
          # while the reading hovers right at high − peakDropF.
          {
            trigger = "state";
            entity_id = "binary_sensor.outdoor_past_peak";
            to = "on";
            "for" = sustainedFor;
          }
          # Same standing-state re-evaluation as the close rule — see the long
          # comment there.
          { trigger = "homeassistant"; event = "start"; }
          { trigger = "time_pattern"; minutes = "/30"; }
        ];
        conditions = [
          {
            condition = "numeric_state";
            entity_id = "sensor.outdoor_temperature";
            below = openBelowF;
          }
          # Replaced a 16:00–21:00 window. 21:00 stays as a comfort cutoff (see
          # eveningEndsAt); 16:00 was a guess at when the day turns over and is
          # now measured instead.
          pastPeak
          { condition = "time"; before = eveningEndsAt; }
          notAnOpenDay
          (notAlready "on")
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
  # declare `template:`, and all four sensors above are templates.
  services.home-assistant.config.homeassistant.packages.windows = windowsPackage;
}
