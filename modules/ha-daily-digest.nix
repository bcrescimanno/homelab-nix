# modules/ha-daily-digest.nix — push the daily digest to Brian's phone
#
# The digest itself is built by modules/daily-digest.nix; this package only
# announces it. Home Assistant package `daily_digest`, read-only in the UI.
#
#   07:45  push if today's digest exists and is a WORKDAY digest
#   08:30  push if today's digest exists and is a WEEKEND digest
#   08:45  infra alert if no digest for today exists at all
#
# HA never decides what kind of day it is. The generator does (weekends plus
# python-holidays plus a list of extra days off) and writes its verdict into
# latest.json as `slot`; the push whose trigger id matches that slot is the one
# that fires. Two calendars of holidays could disagree; one cannot.
#
# The sensor is refreshed explicitly before each check rather than trusted from
# its last poll, so a page rebuilt at 07:25 is seen at 07:45 regardless of
# where the poll interval happens to fall.
#
# WHY THE LEGACY mobile_app SERVICE
#
# Everything else here uses notify.send_message against the notify ENTITY (see
# modules/ha-window-notifications.nix for why). That action accepts only title
# and message, and this push needs `data.url` so a tap opens the digest rather
# than the HA app. Only the legacy per-device service takes `data`.
#
# The service name follows the device name, not the entity. The live
# registration (config entry 01JEZ6N34Z8FXKN0712B05RFN1, created 2024-12-13,
# 29 entities) has device_name "Brian’s iPhone", entity notify.brians_iphone,
# and so service notify.mobile_app_brians_iphone. notify.brians_iphone_14 /
# mobile_app_brians_iphone_14 is the HUSK — do not use it. Read the
# husk-registration comment in modules/ha-window-notifications.nix before
# re-pointing this.

{ ... }:

let
  sensor = "sensor.daily_digest";
  phoneService = "notify.mobile_app_brians_iphone";
  infraNotify = "notify.homelab_alerts";

  # True when the sensor holds today's digest.
  isToday = "states('${sensor}') == now().date().isoformat()";
in
{
  # rest declares requirements (jsonpath-python, xmltodict), so it must be in
  # extraComponents or it fails to import at runtime. The list merges with the
  # one in modules/homeassistant.nix.
  services.home-assistant.extraComponents = [ "rest" ];

  services.home-assistant.config.homeassistant.packages.daily_digest = {
    rest = [
      {
        resource = "https://digest.theshire.io/latest.json";
        # Refreshed on demand by the automations below; this poll only keeps
        # the dashboard value roughly current.
        scan_interval = 3600;
        sensor = [
          {
            name = "Daily digest";
            unique_id = "daily_digest";
            icon = "mdi:newspaper-variant-outline";
            value_template = "{{ value_json.date }}";
            json_attributes = [ "slot" "generated_at" "url" "push_title" "push_message" "problems" ];
          }
        ];
      }
    ];

    automation = [
      {
        id = "daily_digest_push";
        alias = "Daily digest: push to phone";
        description = "Declared in modules/ha-daily-digest.nix — edit there, not in the UI.";
        mode = "single";
        triggers = [
          { trigger = "time"; at = "07:45:00"; id = "weekday"; }
          { trigger = "time"; at = "08:30:00"; id = "weekend"; }
        ];
        actions = [
          { action = "homeassistant.update_entity"; target.entity_id = sensor; }
          {
            condition = "template";
            value_template = "{{ ${isToday} and state_attr('${sensor}', 'slot') == trigger.id }}";
          }
          {
            action = phoneService;
            data = {
              title = "{{ state_attr('${sensor}', 'push_title') }}";
              message = "{{ state_attr('${sensor}', 'push_message') }}";
              data.url = "{{ state_attr('${sensor}', 'url') }}";
            };
          }
        ];
      }
      {
        id = "daily_digest_missing";
        alias = "Daily digest: alert when missing";
        description = "Declared in modules/ha-daily-digest.nix — edit there, not in the UI.";
        mode = "single";
        # After both build slots (07:25, 08:10) and both pushes. Every day must
        # have produced a digest by now, whichever kind of day it is; covers a
        # timer that never fired, which the unit's OnFailure cannot see.
        triggers = [ { trigger = "time"; at = "08:45:00"; } ];
        actions = [
          { action = "homeassistant.update_entity"; target.entity_id = sensor; }
          { condition = "template"; value_template = "{{ not (${isToday}) }}"; }
          {
            action = "notify.send_message";
            target.entity_id = infraNotify;
            data = {
              title = "Daily digest missing";
              message = "No digest for today at 08:45 (sensor reads '{{ states('${sensor}') }}'). Check journalctl -u 'daily-digest@*' on rivendell and https://digest.theshire.io/latest.json.";
            };
          }
        ];
      }
    ];
  };
}
