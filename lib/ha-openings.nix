# The doors and windows that count as "opening the house up", shared by two HA
# packages that ask the same question about them:
#
#   modules/ha-hvac-openings.nix       — any open → pause the HVAC
#   modules/ha-window-notifications.nix — all already closed/open → skip the
#                                          close/open prompt
#
# Contact sensors (device_class opening/door/window; `on` = open).
#
# binary_sensor.front_door_contact is deliberately NOT here. The front door
# isn't kept open when the house is opened up for cooling, so it must not pause
# the HVAC, and an open front door is not "the windows are open". Not an
# omission — don't add it.
#
# entity → the name used in notifications. Labels live here rather than coming
# from friendly_name, which Matter builds from device + room + entity (hence
# entity IDs like office_office_door_door).
#
# Usage: openings = import ../lib/ha-openings.nix;
{
  "binary_sensor.kitchen_door_contact" = "Kitchen door";
  "binary_sensor.office_office_door_door" = "Office door";
}
