# modules/ha-bathroom-lights.nix — Boys Bathroom lights auto-off, gated on the door
#
# The room has no occupancy sensing, so the door is the proxy for it: a closed
# door means someone is in there. The rules:
#
#   1. Nothing ever turns the light ON. Manual only.
#   2. Door CLOSED  → the light is left alone, except the 60-minute backstop (5).
#   3. Door closed → open while the light is ON → wait 30s; if the light is
#      still on and the door is still open, turn it off. (Someone left.)
#   4. Light on AND door open, both continuously for 5 minutes → turn it off.
#   5. Light on for 60 minutes while the door is CLOSED → turn it off.
#   6. Door sensor unavailable for 30 minutes → one infra alert. Nothing is
#      turned off while it is dark.
#
# This replaces a flat "off after 15 minutes on" rule, which cut the lights
# mid-shower and needed a 19:00–20:30 suppression window to compensate. That
# window is GONE and must not come back: a shower means a closed door, and rule
# 2 already blocks every fast path. Rule 5 is the only thing that fires behind a
# closed door, and an hour is far longer than any shower.
#
# Declared as a Home Assistant package, like modules/ha-hvac-openings.nix, so it
# merges additively with the UI-authored automations.yaml. It shows in the UI
# (traces work) but is read-only there — edit this file.
#
# ---------------------------------------------------------------------------
# Entities
# ---------------------------------------------------------------------------
#
# The door is a Matter Eve Door & Window (node 10), device_class `door`, so
# `on` = OPEN and `off` = closed. Verified against the recorder, not assumed.
#
# `unavailable` is neither open nor closed. Every condition below names the
# state it wants explicitly, so a dark sensor satisfies none of them: nothing
# turns off, including the backstop. That is deliberate — the failure mode is
# "the light stays on", not "the light dies on someone in the shower" — and
# rule 6 makes the dead sensor visible instead of silent.
#
# ---------------------------------------------------------------------------
# Why rule 3 checks the light BEFORE its delay, not after
# ---------------------------------------------------------------------------
#
# "Closed → open WITH the light on" means the light must be on at the moment
# the door opens. The obvious encoding — a state trigger with `for = 30s`, then
# a light condition — gets the common case backwards: someone walks in (door
# opens while the light is off), turns the light on 5s later, and is switched
# off at 30s. So the light condition sits immediately after the trigger, before
# the delay, and the state is re-checked after it.
#
# mode = "restart": closing and re-opening inside the 30s starts a fresh grace
# period rather than leaving a stale run to fire against the new state.
#
# ---------------------------------------------------------------------------
# Restarts
# ---------------------------------------------------------------------------
#
# A `for` countdown lives in memory and is lost on restart (see the comment in
# modules/ha-hvac-openings.nix). Rules 4 and 5 therefore also trigger on
# `homeassistant: start`, wait their duration, and re-check with a `for`
# condition — that reads last_changed, which HA resets at startup, so it asks
# "on, untouched, for the full duration since boot".
#
# Rule 3 deliberately has NO start trigger. After a restart there is no way to
# know whether a closed → open edge happened, and re-running it would turn off
# a light someone switched on during boot. A light left on across a restart is
# rules 4 and 5's job.
#
# ---------------------------------------------------------------------------
# Rule 4's clock
# ---------------------------------------------------------------------------
#
# "5 minutes without the door state changing" is measured from whichever of the
# two events happened LAST. That falls out of requiring both `for` conditions at
# once: each entity has its own trigger at its own 5-minute mark, and only the
# later one finds both conditions true. Light on at t=0, door opens at t=3 →
# the light's trigger at t=5 fails (door open only 2 min); the door's trigger at
# t=8 passes. In practice rule 3 usually fires first; rule 4's real job is the
# case with no open-edge at all — the light switched on while the door already
# stood open.
#
# Durations are written as { minutes = 5; }, never "00:05:00". A mapping cannot
# go through YAML's sexagesimal-int trap at all (see ha-nix-packages-pattern).

{ ... }:

let
  light = "light.boys_bathroom_boys_bathroom_lights";

  # device_class `door`: on = OPEN, off = closed.
  door = "binary_sensor.boys_bathroom_door";

  openGrace = { seconds = 30; };
  openTimeout = { minutes = 5; };
  closedBackstop = { minutes = 60; };
  unavailableFor = { minutes = 30; };

  infraNotify = "notify.homelab_alerts";

  description = "Declared in modules/ha-bathroom-lights.nix — edit there, not in the UI.";

  lightOn = { condition = "state"; entity_id = light; state = "on"; };
  doorOpen = { condition = "state"; entity_id = door; state = "on"; };
  doorClosed = { condition = "state"; entity_id = door; state = "off"; };

  lightOnFor = d: lightOn // { "for" = d; };
  doorOpenFor = d: doorOpen // { "for" = d; };

  turnOff = {
    action = "light.turn_off";
    target.entity_id = light;
  };

  onStart = [{ trigger = "homeassistant"; event = "start"; id = "ha_start"; }];

  # On a start run, wait the rule's own duration before the conditions below
  # re-check it. Any other trigger falls straight through.
  ifStartedWait = d: {
    "if" = [{ condition = "trigger"; id = "ha_start"; }];
    "then" = [{ delay = d; }];
  };
in
{
  services.home-assistant.config.homeassistant.packages.boys_bathroom_lights = {
    automation = [
      {
        id = "boys_bathroom_lights_door_opened";
        alias = "Boys Bathroom: lights off 30s after the door opens";
        inherit description;
        # A close/re-open inside the grace period restarts it.
        mode = "restart";
        triggers = [{
          trigger = "state";
          entity_id = door;
          from = "off";
          to = "on";
          id = "opened";
        }];
        actions = [
          # The light must have been on AS the door opened — see the header.
          lightOn
          { delay = openGrace; }
          doorOpen
          lightOn
          turnOff
        ];
      }

      {
        id = "boys_bathroom_lights_open_timeout";
        alias = "Boys Bathroom: lights off after 5 min open with the light on";
        inherit description;
        # parallel, not queued: the start run sits in a delay of this rule's own
        # length, and must never block or cancel a real trigger behind it. A
        # second turn_off on an already-off light is harmless.
        mode = "parallel";
        triggers = [
          { trigger = "state"; entity_id = light; to = "on"; "for" = openTimeout; id = "light_on"; }
          { trigger = "state"; entity_id = door; to = "on"; "for" = openTimeout; id = "door_open"; }
        ] ++ onStart;
        actions = [
          (ifStartedWait openTimeout)
          # Both, so the clock runs from whichever happened last.
          (lightOnFor openTimeout)
          (doorOpenFor openTimeout)
          turnOff
        ];
      }

      {
        id = "boys_bathroom_lights_closed_backstop";
        alias = "Boys Bathroom: lights off after 60 min behind a closed door";
        inherit description;
        # parallel, not queued: the start run sits in a delay of this rule's own
        # length, and must never block or cancel a real trigger behind it. A
        # second turn_off on an already-off light is harmless.
        mode = "parallel";
        triggers = [
          { trigger = "state"; entity_id = light; to = "on"; "for" = closedBackstop; id = "light_on_long"; }
          # The light may already have been on 60 min when the door closes.
          { trigger = "state"; entity_id = door; to = "off"; id = "closed"; }
        ] ++ onStart;
        actions = [
          (ifStartedWait closedBackstop)
          (lightOnFor closedBackstop)
          doorClosed
          turnOff
        ];
      }

      {
        id = "boys_bathroom_door_sensor_unavailable";
        alias = "Boys Bathroom: door sensor unavailable";
        inherit description;
        mode = "parallel";
        triggers = [{
          trigger = "state";
          entity_id = door;
          to = [ "unavailable" "unknown" ];
          "for" = unavailableFor;
        }];
        actions = [{
          action = "notify.send_message";
          target.entity_id = infraNotify;
          data = {
            title = "Boys Bathroom door sensor is down";
            message = "${door} has been unavailable for ${toString unavailableFor.minutes} min. The bathroom lights will not auto-off until it reports again. Check its battery and Thread link.";
          };
        }];
      }
    ];
  };
}
