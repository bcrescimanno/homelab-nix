# modules/ha-dashboard.nix — the "Home" Lovelace dashboard, declared in Nix
#
# Rendered to ui-lovelace.yaml by services.home-assistant.lovelaceConfig and
# registered as a YAML-mode dashboard. It is READ-ONLY in the HA UI: edit this
# file and deploy. The UI-authored storage dashboards (Overview, Map) are left
# alone — this one is added beside them, not in place of them.
#
# It is also forced to be the system default dashboard — see the preStart at
# the bottom for why that has to be frontend storage, not YAML.
#
# Layout: a Home view (glance: people, weather, climate, doors, whatever is
# active right now, homelab health), then one view per floor with a section
# per room. Sections views reflow to one column on phones and several on a
# desktop, which is the only reason they are used — every card is stock.
#
# Entity choices, verified against the recorder on 2026-09-13:
#   - The `_2` HomeKit entities (binary_sensor.*_occupancy_2,
#     sensor.*_temperature_2) are the live ones. The unsuffixed IDs are empty
#     leftovers from an earlier pairing; so are climate.main_floor_2 and
#     weather.main_floor. Do not "tidy" the suffix off.
#   - Music Assistant registers several players per room and some are dead:
#     living_room_atv, lucass_appletv, office_music, playoom_atv, playroom_tv
#     and samsung_the_frame_50_2 were all unavailable. office_music_2 is the
#     live office player.
#   - Living Room motion/temperature are unavailable device-side (the same
#     offline HomeKit sensor as the Living Room door). They stay on the page so
#     the outage stays visible.
#   - Home Connect program/option switches are deliberately absent: they are
#     only meaningful while a program is selected, and are unavailable
#     otherwise (see the Kitchen bridge comment in homeassistant.nix).
#   - Outdoor temperature reads sensor.outdoor_temperature, the same template
#     indirection the window notifications use, so a sensor swap is one edit in
#     modules/ha-window-notifications.nix and this page follows.

{ config, lib, pkgs, ... }:

let
  tile = entity: extra: { type = "tile"; inherit entity; } // extra;

  heading = text: icon: { type = "heading"; heading = text; inherit icon; };

  section = text: icon: cards: {
    type = "grid";
    cards = [ (heading text icon) ] ++ cards;
  };

  # Show a card only while `entity` is NOT in one of `idle` states. Used for the
  # "Active now" section so it is empty on a quiet day rather than a wall of
  # "inactive" tiles.
  whenNot = entity: idle: {
    visibility = [{ condition = "state"; inherit entity; state_not = idle; }];
  };

  speaker = entity: name: tile entity { inherit name; icon = "mdi:speaker"; };

  # ---- Home ----------------------------------------------------------------

  home = {
    title = "Home";
    path = "home";
    icon = "mdi:home";
    type = "sections";
    max_columns = 3;

    badges = [
      { type = "entity"; entity = "person.brian"; }
      { type = "entity"; entity = "person.heather"; }
      { type = "entity"; entity = "sensor.outdoor_temperature"; name = "Outside"; show_name = true; }
      { type = "entity"; entity = "binary_sensor.front_door_contact"; name = "Front door"; show_name = true; }
      { type = "entity"; entity = "binary_sensor.kitchen_door_contact"; name = "Kitchen door"; show_name = true; }
    ];

    sections = [
      (section "Weather" "mdi:weather-partly-cloudy" [
        {
          type = "weather-forecast";
          entity = "weather.forecast_home";
          forecast_type = "daily";
          show_current = true;
          show_forecast = true;
        }
        (tile "sensor.outdoor_temperature" { name = "Outside now"; })
        (tile "sensor.forecast_high_today" { name = "High today"; })
        (tile "sensor.eve_weather_humidity" { name = "Outside humidity"; })
        (tile "sensor.eve_weather_weather_trend" { name = "Trend"; })
      ])

      (section "Climate" "mdi:thermostat" [
        { type = "thermostat"; entity = "climate.main_floor"; name = "Main floor"; }
        (tile "sensor.main_floor_current_humidity" { name = "Humidity"; })
        (tile "sensor.office_temperature_2" { name = "Office"; })
        (tile "sensor.bedroom_temperature_2" { name = "Bedroom"; })
        (tile "sensor.living_room_temperature_2" { name = "Living room"; })
      ])

      (section "Active now" "mdi:flash" [
        (tile "light.boys_bathroom_boys_bathroom_lights" ({ name = "Boys bathroom"; } // whenNot "light.boys_bathroom_boys_bathroom_lights" [ "off" ]))
        (tile "light.desktop_key_light" ({ name = "Key light"; } // whenNot "light.desktop_key_light" [ "off" ]))
        (tile "light.hood_light" ({ name = "Hood light"; } // whenNot "light.hood_light" [ "off" ]))
        (tile "sensor.dishwasher_operation_state" ({ name = "Dishwasher"; icon = "mdi:dishwasher"; } // whenNot "sensor.dishwasher_operation_state" [ "inactive" "ready" "unavailable" ]))
        (tile "sensor.oven_operation_state" ({ name = "Wall oven"; icon = "mdi:stove"; } // whenNot "sensor.oven_operation_state" [ "inactive" "ready" "unavailable" ]))
        (tile "sensor.oven_2_right_operation_state" ({ name = "Range"; icon = "mdi:stove"; } // whenNot "sensor.oven_2_right_operation_state" [ "inactive" "ready" "unavailable" ]))
        (tile "vacuum.kitchen_robo" ({ name = "Roborock"; } // whenNot "vacuum.kitchen_robo" [ "docked" "unavailable" ]))
        (tile "media_player.office_music_2" ({ name = "Office music"; } // whenNot "media_player.office_music_2" [ "idle" "off" "paused" "unavailable" ]))
        (tile "media_player.kitchen" ({ name = "Kitchen music"; } // whenNot "media_player.kitchen" [ "idle" "off" "paused" "unavailable" ]))
        (tile "media_player.living_room" ({ name = "Living room music"; } // whenNot "media_player.living_room" [ "idle" "off" "paused" "unavailable" ]))
      ])

      (section "Doors & motion" "mdi:door" [
        (tile "binary_sensor.front_door_contact" { name = "Front door"; })
        (tile "binary_sensor.kitchen_door_contact" { name = "Kitchen door"; })
        (tile "binary_sensor.main_floor_motion" { name = "Hall motion"; })
        (tile "binary_sensor.front_door_motion" { name = "Entry motion"; })
      ])

      (section "Homelab" "mdi:server" [
        (tile "sensor.ups_status" { name = "UPS"; })
        (tile "sensor.ups_battery_charge" { name = "UPS battery"; })
        (tile "sensor.ups_load" { name = "UPS load"; })
        (tile "sensor.qbittorrent_status" { name = "qBittorrent"; })
      ])
    ];
  };

  # ---- Upstairs ------------------------------------------------------------

  upstairs = {
    title = "Upstairs";
    path = "upstairs";
    icon = "mdi:home-floor-1";
    type = "sections";
    max_columns = 3;
    sections = [
      (section "Kitchen" "mdi:silverware-fork-knife" [
        (tile "light.hood_light" { name = "Hood light"; })
        (tile "vacuum.kitchen_robo" {
          name = "Roborock";
          features = [{ type = "vacuum-commands"; commands = [ "start_pause" "return_home" ]; }];
        })
        (tile "sensor.dishwasher_operation_state" { name = "Dishwasher"; icon = "mdi:dishwasher"; })
        (tile "sensor.dishwasher_remaining_program_time" { name = "Dishwasher done"; })
        (tile "sensor.oven_operation_state" { name = "Wall oven"; icon = "mdi:stove"; })
        (tile "sensor.oven_current_oven_cavity_temperature" { name = "Wall oven temp"; })
        (tile "sensor.oven_2_right_operation_state" { name = "Range"; icon = "mdi:stove"; })
        (tile "sensor.oven_2_right_current_oven_cavity_temperature" { name = "Range temp"; })
        (tile "binary_sensor.kitchen_door_contact" { name = "Door"; })
        (speaker "media_player.kitchen" "Speaker")
      ])

      (section "Living Room" "mdi:sofa" [
        (tile "sensor.living_room_temperature_2" { name = "Temperature"; })
        (tile "binary_sensor.living_room_motion" { name = "Motion"; })
        (tile "media_player.living_room_appletv" { name = "Apple TV"; })
        (tile "media_player.living_room_sonos" { name = "Sonos"; })
        (speaker "media_player.living_room" "Speaker")
      ])

      (section "Office" "mdi:desk" [
        (tile "light.desktop_key_light" { name = "Key light"; })
        (tile "sensor.office_temperature_2" { name = "Temperature"; })
        (tile "binary_sensor.office_motion" { name = "Motion"; })
        (tile "media_player.lg_webos_tv_oled42c4pua" { name = "Monitor"; })
        (speaker "media_player.office_music_2" "Speaker")
      ])

      (section "Master Bedroom" "mdi:bed-king" [
        (tile "sensor.bedroom_temperature_2" { name = "Temperature"; })
        (tile "binary_sensor.bedroom_motion" { name = "Motion"; })
        (tile "media_player.master_bedroom_master_bedroom" { name = "Apple TV"; })
        (tile "media_player.samsung_the_frame_50" { name = "The Frame"; })
        (speaker "media_player.master_bedroom" "Speaker")
      ])

      (section "Hall & Entry" "mdi:door-open" [
        (tile "climate.main_floor" { name = "Thermostat"; })
        (tile "binary_sensor.main_floor_motion" { name = "Hall motion"; })
        (tile "binary_sensor.front_door_contact" { name = "Front door"; })
        (tile "binary_sensor.front_door_motion" { name = "Entry motion"; })
      ])

      (section "Ethan's Room" "mdi:bed" [
        (speaker "media_player.ethans_room" "Speaker")
      ])

      (section "Lounge" "mdi:sofa-single" [
        (speaker "media_player.stereo" "Stereo")
      ])

      (section "Boys Bathroom" "mdi:shower" [
        (tile "light.boys_bathroom_boys_bathroom_lights" { name = "Lights"; })
      ])
    ];
  };

  # ---- Downstairs ----------------------------------------------------------

  downstairs = {
    title = "Downstairs";
    path = "downstairs";
    icon = "mdi:home-floor-0";
    type = "sections";
    max_columns = 3;
    sections = [
      (section "Playroom" "mdi:toy-brick" [
        (speaker "media_player.playroom" "Speaker")
      ])

      (section "Lily's Room" "mdi:bed" [
        (speaker "media_player.lily" "Speaker")
      ])

      (section "Studio" "mdi:printer" [
        (speaker "media_player.studio" "Speaker")
        (tile "sensor.brother_mfc_j995dw" { name = "Printer"; })
        (tile "sensor.brother_mfc_j995dw_bk" { name = "Black ink"; })
        (tile "sensor.brother_mfc_j995dw_c" { name = "Cyan ink"; })
        (tile "sensor.brother_mfc_j995dw_m" { name = "Magenta ink"; })
        (tile "sensor.brother_mfc_j995dw_y" { name = "Yellow ink"; })
      ])

      (section "Homelab" "mdi:server" [
        (tile "sensor.ups_status" { name = "UPS"; })
        (tile "sensor.ups_battery_charge" { name = "Battery"; })
        (tile "sensor.ups_load" { name = "Load"; })
        (tile "sensor.ups_input_voltage" { name = "Input voltage"; })
        (tile "sensor.qbittorrent_status" { name = "qBittorrent"; })
        (tile "sensor.qbittorrent_download_speed" { name = "Down"; })
        (tile "sensor.qbittorrent_upload_speed" { name = "Up"; })
        (tile "sensor.qbittorrent_active_torrents" { name = "Active torrents"; })
      ])
    ];
  };
  # url_path of the dashboard the module registers for lovelaceConfig. Fixed by
  # the module; used both below and as the default-panel value.
  dashboardPath = "nixos-lovelace";
in
{
  services.home-assistant = {
    lovelaceConfig = {
      title = "Home";
      views = [ home upstairs downstairs ];
    };

    # Overrides the module's default entry for this dashboard, which would
    # otherwise also be titled "Overview" and sit in the sidebar next to the
    # existing storage Overview with the same name.
    config.lovelace.dashboards.${dashboardPath} = {
      mode = "yaml";
      filename = "ui-lovelace.yaml";
      title = "Home";
      icon = "mdi:home";
      show_in_sidebar = true;
    };
  };

  # Make this the default dashboard for everyone.
  #
  # YAML cannot express this. The default is frontend state:
  # `.storage/frontend.system_data` -> data.core.default_panel, which is what
  # Settings > Dashboards > "Set as default" writes. The frontend (20260826)
  # resolves the landing page as
  #   userData.default_panel || systemData.default_panel || localStorage || "home"
  # so this beats a stale per-browser choice, but a PER-USER default set on the
  # profile page still wins. That is intended; clear it there if it bites.
  #
  # Written in HA's own preStart, not a separate oneshot, for two reasons:
  #   - HA holds the store in memory and only writes it on change, so the edit
  #     must land while HA is stopped or it is not seen until the next restart.
  #   - Changing the preStart changes home-assistant.service, so a deploy
  #     restarts HA and the new default applies at once.
  # preStart runs as hass inside ProtectSystem=strict with configDir writable,
  # so no chown is needed. It is authoritative: a UI "Set as default" is
  # reverted on the next restart.
  #
  # Never fails the unit. A bad merge warns and leaves the file untouched; a
  # wrong landing page is not worth HA refusing to boot.
  systemd.services.home-assistant.preStart = lib.mkAfter ''
    sys="${config.services.home-assistant.configDir}/.storage/frontend.system_data"
    if [ -f "$sys" ]; then
      if ${pkgs.jq}/bin/jq --arg p ${dashboardPath} '.data.core.default_panel = $p' "$sys" > "$sys.nix-tmp"; then
        mv "$sys.nix-tmp" "$sys"
      else
        rm -f "$sys.nix-tmp"
        echo "ha-dashboard: could not set default_panel in $sys, leaving it unchanged" >&2
      fi
    else
      printf '%s\n' '{"version":1,"minor_version":1,"key":"frontend.system_data","data":{"core":{"default_panel":"${dashboardPath}"}}}' > "$sys"
    fi
  '';
}
