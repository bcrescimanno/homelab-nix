# modules/ha-bathroom-lights.nix — Boys Bathroom lights auto-off
#
# Any time the Boys Bathroom lights have been on for 15 minutes, turn them off.
# No occupancy check: the room has no motion sensor, so "on for 15 min" is the
# whole rule.
#
# Declared as a Home Assistant package, like modules/ha-window-notifications.nix,
# so it merges additively with the UI-authored automations.yaml. It shows in the
# UI (traces work) but is read-only there — edit this file.
#
# Why two triggers, not one
#
# A state trigger with `for` keeps its countdown in memory. Restart HA 10
# minutes into a 15-minute window and the countdown is gone. It only re-arms on
# the next state change, so a light left on across a restart could stay on
# forever. The Matter light usually does flap unavailable -> on during startup,
# which re-arms it, but that depends on whether the automation or the Matter
# integration finishes loading first. Don't rely on it.
#
# The start trigger closes that gap. It waits 15 minutes, then re-checks with
# a `for` condition. That condition reads the entity's last_changed, which HA
# resets at startup, so it asks "on, untouched, for the full 15 minutes since
# boot". If someone toggles the light during the wait, the condition fails and
# the normal state trigger owns the new window. mode = parallel so a start run
# sitting in its delay never blocks or cancels a state-trigger run. A second
# turn_off on an already-off light is harmless.
#
# Durations are written as { minutes = 15; }, never "00:15:00". A mapping cannot
# go through YAML's sexagesimal-int trap at all (see ha-nix-packages-pattern).
#
# Shower window: 19:00–20:30, nothing turns the lights off
#
# Evening showers run past 15 minutes, and the lights went out on one. A time
# condition sits right before the turn_off, so it gates every trigger path,
# including a start run that checks after its 15-minute delay.
#
# Suppressing alone would leave a gap. Turn the light on at 19:10 and the state
# trigger fires once at 19:25, gets blocked, and never fires again. So a third
# trigger fires at 20:30 and turns off anything that has been on for at least
# 15 minutes. A light turned on at 20:20 fails that check, but its own state
# trigger fires at 20:35, outside the window, so it is still covered.
#
# This is a stopgap. The time rule is only here because the room has no
# occupancy sensing. Once a presence sensor (mmWave, since a still person in a
# shower defeats PIR) is in the bathroom, replace the window and the 15-minute
# timer with "off after N minutes of no presence". Tracked in Plan.md.

{ ... }:

let
  light = "light.boys_bathroom_boys_bathroom_lights";
  onFor = { minutes = 15; };

  # HA's time condition wraps midnight when after > before.
  showerStart = "19:00:00";
  showerEnd = "20:30:00";

  turnOff = {
    action = "light.turn_off";
    target.entity_id = light;
  };
in
{
  services.home-assistant.config.homeassistant.packages.boys_bathroom_lights = {
    automation = [
      {
        id = "boys_bathroom_lights_auto_off";
        alias = "Boys Bathroom: lights off after 15 minutes";
        description = "Declared in modules/ha-bathroom-lights.nix — edit there, not in the UI.";
        mode = "parallel";
        triggers = [
          {
            trigger = "state";
            entity_id = light;
            to = "on";
            "for" = onFor;
            id = "on_for_15";
          }
          {
            trigger = "homeassistant";
            event = "start";
            id = "ha_start";
          }
          {
            trigger = "time";
            at = showerEnd;
            id = "shower_window_end";
          }
        ];
        actions = [
          {
            "if" = [{ condition = "trigger"; id = "ha_start"; }];
            "then" = [
              { delay = onFor; }
              { condition = "state"; entity_id = light; state = "on"; "for" = onFor; }
            ];
          }
          {
            "if" = [{ condition = "trigger"; id = "shower_window_end"; }];
            "then" = [
              { condition = "state"; entity_id = light; state = "on"; "for" = onFor; }
            ];
          }
          # Outside the shower window only.
          { condition = "time"; after = showerEnd; before = showerStart; }
          turnOff
        ];
      }
    ];
  };
}
