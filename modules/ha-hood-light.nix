# modules/ha-hood-light.nix — kitchen hood light follows the fan
#
# When the hood fan is switched on, turn the hood light on too. Nothing turns
# it off. Someone who switches the light off mid-cook keeps it off, and the
# light outliving the fan is harmless.
#
# Declared as a Home Assistant package, like modules/ha-bathroom-lights.nix, so
# it merges additively with the UI-authored automations.yaml. It shows in the
# UI (traces work) but is read-only there — edit this file.
#
# Why `from = "off"`, not just `to = "on"`
#
# The hood is a Home Connect (cloud) appliance. Its entities go `unavailable`
# and come back several times a day as the integration reconnects. A reconnect
# while the fan is running lands as unavailable -> on. A bare `to = "on"` would
# read that as the fan starting, and would turn back on a light someone had
# switched off. Only a real off -> on edge counts. The one case this misses is
# a fan started while HA was disconnected, which is acceptable.
#
# The light is not always off when the fan starts. The recorder shows the hood
# sometimes brings it up on its own (same second as power). The condition skips
# the cloud call in that case. Home Connect's API is rate-limited per day.

{ ... }:

let
  fan = "switch.hood_power";
  light = "light.hood_light";
in
{
  services.home-assistant.config.homeassistant.packages.hood_light = {
    automation = [
      {
        id = "hood_light_with_fan";
        alias = "Kitchen Hood: light on with fan";
        description = "Declared in modules/ha-hood-light.nix — edit there, not in the UI.";
        mode = "single";
        triggers = [
          {
            trigger = "state";
            entity_id = fan;
            from = "off";
            to = "on";
          }
        ];
        conditions = [
          { condition = "state"; entity_id = light; state = "off"; }
        ];
        actions = [
          {
            action = "light.turn_on";
            target.entity_id = light;
          }
        ];
      }
    ];
  };
}
