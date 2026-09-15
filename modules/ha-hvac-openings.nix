# modules/ha-hvac-openings.nix — pause HVAC while the house is open
#
# The rules:
#
#   1. ANY opening open for 60s  → save the thermostat's mode, set it to off,
#                                   push "HVAC paused" to the household.
#   2. ALL openings closed        → restore the saved mode immediately. Silent.
#   3. Someone sets the thermostat to heat/cool/heat_cool by hand while it is
#      paused → the pause is abandoned. Nothing is restored on close; the next
#      open-for-60s starts a fresh cycle.
#   4. An opening sensor unavailable for 30 min → one infra alert.
#   5. Outdoor temperature outside 40–72°F (or unknown) and any opening open
#      30+ min → push "close it" to the household, naming what is open.
#      Repeats every 30 min while both hold. Independent of the thermostat:
#      it fires whether or not the HVAC is paused or was overridden by hand.
#
# Rules 1–3 are unchanged by adding sensors: "any" and "all" are over the whole
# `openings` set, and a manual override is only undone by a NEW opening
# reaching 60s — one that is already open never re-pauses.
#
# The reminder measures "open 30 min" from last_changed, which HA resets at
# startup, so a restart restarts that clock (at worst a 30-min-late alert).
#
# Only an active mode (heat, cool, heat_cool) is paused. A thermostat that is
# already off is left alone, and because nothing is saved it is never turned
# ON when the door closes.
#
# Declared as a Home Assistant package, like modules/ha-bathroom-lights.nix, so
# it merges additively with the UI-authored automations.yaml. It shows in the UI
# (traces work) but is read-only there — edit this file.
#
# ---------------------------------------------------------------------------
# "All closed" means every sensor REPORTS off
# ---------------------------------------------------------------------------
#
# The resume automation triggers on any opening changing to off, but that is
# only the wake-up. The rule is its condition: a state condition over the whole
# `openings` list, which HA passes only if EVERY entity is `off`. `unavailable`
# and `unknown` are not `off`, so a sensor that drops out holds the current
# state: it never pauses (the pause trigger is `to: on`), and a pause cannot
# resume while it is dark. The kitchen door sensor did exactly that for ~40 min
# on 2026-09-13, which is why rule 4 exists — a dead sensor would otherwise hold
# the HVAC off silently.
#
# ---------------------------------------------------------------------------
# Where the mode to restore lives
# ---------------------------------------------------------------------------
#
# input_text.hvac_openings_saved_mode. A valid mode in it means "this pause is
# ours to undo"; anything else (empty, unknown) means nothing is paused. It has
# no `initial`, so HA restores it across restarts. Not scene.create: snapshot
# scenes are lost on restart, which would strand the HVAC off.
#
# The pause sets the thermostat off BEFORE writing the helper. If the
# set_hvac_mode call raises (thermostat unreachable), the run aborts with
# nothing saved, rather than leaving a saved mode for a pause that never
# happened — a stale saved mode is how a door closing could switch on a
# thermostat someone had deliberately turned off.
#
# ---------------------------------------------------------------------------
# Manual override
# ---------------------------------------------------------------------------
#
# The override trigger names its target states (`to: [heat, cool, heat_cool]`)
# rather than firing on any state change. homekit_controller thermostats do blip
# to `unavailable`; a bare state trigger would read that blip as a human taking
# over and silently drop the pause. Coming BACK from unavailable into an active
# mode does count — if the device says it is cooling, it is.
#
# The resume automation's own set_hvac_mode also fires this trigger. Harmless:
# both end by clearing the helper.
#
# ---------------------------------------------------------------------------
# Restarts
# ---------------------------------------------------------------------------
#
# A `for` countdown lives in memory and is lost on restart (see
# modules/ha-bathroom-lights.nix), and a door closed while HA was down produces
# no state change to trigger on. So all three state-keeping automations also
# trigger on `homeassistant: start`, wait openFor, and re-check:
#
#   pause    — an opening on, untouched, for openFor since boot (last_changed
#              is reset at startup) and the thermostat active → pause.
#   resume   — a saved mode, all closed, thermostat off → resume.
#   override — a saved mode but the thermostat active → clear it.
#
# mode = "queued" everywhere. Two openings reaching 60s together would
# otherwise both see the thermostat active and both save/notify; queued, the
# second run starts after the first has waited for the thermostat to report off
# and fails its condition. The cost is that an event in the first openFor after
# boot waits behind the start run's delay.
#
# Durations are mappings ({ seconds = 60; }), never "00:01:00" — see
# ha-nix-packages-pattern for the YAML sexagesimal trap.
#
# ---------------------------------------------------------------------------
# Expansion plan
# ---------------------------------------------------------------------------
#
# Today there are two sensors: the ecobee SmartSensor on the kitchen door (via
# homekit_controller) and an Eve Door & Window on the office door (Matter). As
# window sensors are added:
#
#   - Adding a sensor is adding `entity = "Label";` to `openings`. The pause
#     and reminder notifications, the any-open/all-closed logic, and the
#     unavailable alert all follow it; nothing else changes.
#   - Windows are not "opened briefly" the way a door is, so they may want a
#     shorter delay. Make each `openings` value { label; openFor; } and emit
#     one pause trigger per distinct duration. (Decided 2026-09-15: one 60s
#     delay for all for now.)
#   - A second thermostat/zone: map each opening to the climate entity it
#     affects and keep one saved-mode helper per thermostat.
#   - With many sensors, one dead sensor blocks every resume (see above). If
#     that becomes a nuisance, the escape hatch is to treat a sensor that has
#     been unavailable longer than unavailableFor as closed FOR RESUME ONLY,
#     keeping the alert. Don't do it pre-emptively: it trades a noisy failure
#     (HVAC stays off, alert fires) for a quiet one (AC runs with a window open).
#   - Thread contact sensors are battery sleepy end devices, and this mesh has
#     no mains-powered Thread routers yet. Check coverage at the far windows
#     before buying a batch.

{ ... }:

let
  # ---- Configuration ------------------------------------------------------

  # Contact sensors (device_class opening/door/window; `on` = open).
  #
  # binary_sensor.front_door_contact is deliberately NOT here. The front door
  # isn't kept open when the house is opened up for cooling, so it must not
  # pause the HVAC. Not an omission — don't add it.
  #
  # entity → the name used in notifications. Labels live here rather than
  # coming from friendly_name, which Matter builds from device + room + entity
  # (hence entity IDs like office_office_door_door).
  openings = {
    "binary_sensor.kitchen_door_contact" = "Kitchen door";
    "binary_sensor.office_office_door_door" = "Office door";
  };

  thermostat = "climate.main_floor";

  # How long an opening must stay open before HVAC is paused.
  openFor = { seconds = 60; };

  # How long a sensor may be unavailable before the infra alert fires.
  unavailableFor = { minutes = 30; };

  # "Should be closed" reminder: outdoor temperature outside [comfortLowF,
  # comfortHighF] (inclusive) and an opening open for closeAfter. Repeats every
  # remindEvery while both stay true. Deliberately NOT tied to the window prompts'
  # 66/72 in ha-window-notifications.nix — different question, different numbers.
  outdoorTemp = "sensor.outdoor_temperature";
  comfortLowF = 40;
  comfortHighF = 72;
  closeAfter = { minutes = 30; };
  remindEvery = { minutes = 30; };

  # Household phones. Same targets as modules/ha-window-notifications.nix; read
  # the husk-registration comment there before re-pointing either.
  phones = [ "notify.brians_iphone" "notify.queen_s_iphone16_pro_2" ];
  infraNotify = "notify.homelab_alerts";

  # ---- Derived ------------------------------------------------------------

  activeModes = [ "heat" "cool" "heat_cool" ];
  savedMode = "input_text.hvac_openings_saved_mode";

  # A JSON list/object is also a valid Jinja list/dict literal.
  jinja = builtins.toJSON;

  openingIds = builtins.attrNames openings;

  seconds = d: (d.minutes or 0) * 60 + (d.seconds or 0);

  # Jinja prelude: ns.out = labels of openings that are `on` and have been for
  # at least `minSeconds`. Followed by one of the two renderers below.
  collectOpen = minSeconds: ''
    {%- set labels = ${jinja openings} -%}
    {%- set ns = namespace(out=[]) -%}
    {%- for s in expand(${jinja openingIds}) -%}
      {%- if s.state == 'on' and (now() - s.last_changed).total_seconds() >= ${toString minSeconds} -%}
        {%- set ns.out = ns.out + [labels[s.entity_id]] -%}
      {%- endif -%}
    {%- endfor -%}'';
  openLabels = minSeconds: collectOpen minSeconds + "{{ ns.out | join(', ') }}";
  anyOpenFor = minSeconds: collectOpen minSeconds + "{{ ns.out | length > 0 }}";

  # Jinja: true when the outdoor temperature is outside the comfort range OR
  # unknown — an unavailable sensor must not silence the reminder.
  outOfRange = ''
    {%- set t = states('${outdoorTemp}') | float(none) -%}
    {{ t is none or t < ${toString comfortLowF} or t > ${toString comfortHighF} }}'';

  onStart = [{ trigger = "homeassistant"; event = "start"; id = "ha_start"; }];
  ifStartedWaitThen = extra: {
    "if" = [{ condition = "trigger"; id = "ha_start"; }];
    "then" = [{ delay = openFor; }] ++ extra;
  };

  pauseIsOurs = {
    condition = "template";
    value_template = "{{ states('${savedMode}') in ${jinja activeModes} }}";
  };

  anyOpen = {
    condition = "or";
    conditions = map (e: { condition = "state"; entity_id = e; state = "on"; }) openingIds;
  };

  anyOpenSinceBoot = {
    condition = "or";
    conditions = map (e: {
      condition = "state"; entity_id = e; state = "on"; "for" = openFor;
    }) openingIds;
  };

  # A state condition over a list passes only if EVERY entity matches.
  allClosed = { condition = "state"; entity_id = openingIds; state = "off"; };

  thermostatActive = { condition = "state"; entity_id = thermostat; state = activeModes; };
  thermostatOff = { condition = "state"; entity_id = thermostat; state = "off"; };

  setSavedMode = value: {
    action = "input_text.set_value";
    target.entity_id = savedMode;
    data.value = value;
  };

  # notify.send_message on the entity, continue_on_error so one dead phone
  # registration cannot mute the other — see ha-window-notifications.nix.
  notify = title: message:
    map (target: {
      action = "notify.send_message";
      target.entity_id = target;
      data = { inherit title message; };
      continue_on_error = true;
    }) phones;

  description = "Declared in modules/ha-hvac-openings.nix — edit there, not in the UI.";

  hvacOpeningsPackage = {
    input_text.hvac_openings_saved_mode = {
      name = "HVAC mode to restore when openings close";
      icon = "mdi:hvac";
      max = 16;
    };

    automation = [
      {
        id = "hvac_openings_pause";
        alias = "HVAC: pause while a door or window is open";
        inherit description;
        mode = "queued";
        triggers = [{
          trigger = "state";
          entity_id = openingIds;
          to = "on";
          "for" = openFor;
          id = "opened";
        }] ++ onStart;
        actions = [
          (ifStartedWaitThen [ anyOpenSinceBoot ])
          anyOpen
          thermostatActive
          { variables.previous_mode = "{{ states('${thermostat}') }}"; }
          {
            action = "climate.set_hvac_mode";
            target.entity_id = thermostat;
            data.hvac_mode = "off";
          }
          {
            wait_template = "{{ is_state('${thermostat}', 'off') }}";
            timeout = { seconds = 30; };
            continue_on_timeout = true;
          }
          (setSavedMode "{{ previous_mode }}")
        ] ++ notify "HVAC paused"
          "${openLabels 0} open — thermostat turned off (was {{ previous_mode }}). It resumes when everything is closed.";
      }

      {
        id = "hvac_openings_resume";
        alias = "HVAC: resume once everything is closed";
        inherit description;
        mode = "queued";
        triggers = [
          { trigger = "state"; entity_id = openingIds; to = "off"; id = "closed"; }
          # Unreachable at the moment everything closed: retry when it's back.
          { trigger = "state"; entity_id = thermostat; from = "unavailable"; to = "off"; id = "thermostat_back"; }
        ] ++ onStart;
        actions = [
          (ifStartedWaitThen [ ])
          pauseIsOurs
          allClosed
          thermostatOff
          {
            action = "climate.set_hvac_mode";
            target.entity_id = thermostat;
            data.hvac_mode = "{{ states('${savedMode}') }}";
          }
          (setSavedMode "")
        ];
      }

      {
        id = "hvac_openings_manual_override";
        alias = "HVAC: a manual mode change cancels the pause";
        inherit description;
        mode = "queued";
        triggers = [{
          trigger = "state";
          entity_id = thermostat;
          to = activeModes;
          id = "mode_changed";
        }] ++ onStart;
        actions = [
          (ifStartedWaitThen [ ])
          pauseIsOurs
          thermostatActive
          (setSavedMode "")
        ];
      }

      {
        id = "hvac_openings_close_reminder";
        alias = "HVAC: remind to close a door or window left open";
        inherit description;
        mode = "queued";
        triggers = [
          # A sensor has just reached closeAfter while the temp is out of range.
          { trigger = "state"; entity_id = openingIds; to = "on"; "for" = closeAfter; id = "opened_long"; }
          # The temp has just left the range with something already open long.
          { trigger = "numeric_state"; entity_id = outdoorTemp; below = comfortLowF; id = "temp_out"; }
          { trigger = "numeric_state"; entity_id = outdoorTemp; above = comfortHighF; id = "temp_out"; }
          # Reminders, the temp going unavailable, and anything missed across a
          # restart. The rate limit below keeps this to one alert per remindEvery.
          { trigger = "time_pattern"; minutes = "/5"; id = "tick"; }
        ];
        conditions = [
          { condition = "template"; value_template = anyOpenFor (seconds closeAfter); }
          { condition = "template"; value_template = outOfRange; }
          # A sensor newly crossing closeAfter is news and always alerts. Temp
          # crossings and ticks wait remindEvery since the last alert, so a temp
          # hovering at the threshold can't spam. last_triggered only advances
          # when these conditions pass, i.e. when an alert is actually sent; the
          # 60s slack absorbs tick jitter.
          {
            condition = "template";
            value_template = ''
              {%- set lt = this.attributes.last_triggered -%}
              {{ trigger.id == 'opened_long' or lt is none
                 or (now() - as_datetime(lt | string)).total_seconds() >= ${toString (seconds remindEvery - 60)} }}'';
          }
        ];
        actions = notify "Close up the house"
          "{%- set t = states('${outdoorTemp}') | float(none) -%}${openLabels (seconds closeAfter)} open for ${toString closeAfter.minutes}+ min, and it's {{ (t | round(0) | int ~ '°F') if t is not none else 'unknown (outdoor sensor unavailable)' }} outside. Please close it.";
      }

      {
        id = "hvac_openings_sensor_unavailable";
        alias = "HVAC: door/window sensor unavailable";
        inherit description;
        mode = "parallel";
        triggers = [{
          trigger = "state";
          entity_id = openingIds;
          to = [ "unavailable" "unknown" ];
          "for" = unavailableFor;
        }];
        actions = [{
          action = "notify.send_message";
          target.entity_id = infraNotify;
          data = {
            title = "Door/window sensor is down";
            message = "{{ state_attr(trigger.entity_id, 'friendly_name') or trigger.entity_id }} has been unavailable for ${toString unavailableFor.minutes} min. HVAC will not pause for it, and a paused HVAC cannot resume until it reports closed. Check its battery and range.";
          };
        }];
      }
    ];
  };
in
{
  services.home-assistant.config.homeassistant.packages.hvac_openings = hvacOpeningsPackage;
}
