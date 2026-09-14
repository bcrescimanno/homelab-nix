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

{ ... }:

let
  light = "light.boys_bathroom_boys_bathroom_lights";
  onFor = { minutes = 15; };

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
        ];
        actions = [
          {
            "if" = [{ condition = "trigger"; id = "ha_start"; }];
            "then" = [
              { delay = onFor; }
              { condition = "state"; entity_id = light; state = "on"; "for" = onFor; }
            ];
          }
          turnOff
        ];
      }
    ];
  };
}
