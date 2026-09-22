# modules/ha-pizza-preheat.nix — Discord ping when the pizza oven is up to temp
#
# The wall oven is a Home Connect (cloud) appliance. When it is running the
# Pizza setting and reaches temperature, Home Connect raises a preheat-finished
# event; this posts one Discord message that @-mentions a single member.
#
# Declared as a Home Assistant package, like the other ha-*.nix modules, so it
# merges additively with the UI-authored automations.yaml. It shows in the UI
# (traces work) but is read-only there — edit this file.
#
# Why a channel WEBHOOK and not the discord integration
#
# HA's `discord` integration is `config_flow: true` and has no YAML platform —
# components/discord/notify.py returns None unless it is handed a config entry.
# The bot token would therefore live in .storage and the notify entity would be
# invisible to Nix: exactly the imperative setup this repo avoids (see the
# guiding principle in CLAUDE.md). A channel webhook needs no bot, no gateway
# intents and no UI. The URL is the whole credential and `rest_command` POSTs
# to it, so the config stays in Nix and the secret stays in sops.
#
# What that costs: the message arrives as the webhook's own identity (its name
# and avatar are set once, in the Discord UI), and a webhook can only ever post
# to the one channel it was created in. Both are fine for one notification.
#
# `allowed_mentions` is not optional. A webhook that posts "<@id>" renders the
# mention but does not necessarily ping; naming the id under allowed_mentions
# is what makes it a real notification. `parse: []` suppresses everything else,
# so a future message body can never accidentally @everyone.
#
# Why the trigger is a SENSOR, not an event entity
#
# Home Connect has no event platform. Its appliance events are enum sensors
# (components/home_connect/sensor.py, EVENT_SENSORS) whose state is one of
# present / confirmed / off — `present` is the event being raised, `confirmed`
# is someone acknowledging it on the appliance itself. So this is a state
# trigger to "present", not an event trigger, and the entity is a sensor.
#
# Both preheat sensors are wired up on purpose. The oven exposes the
# Cooking.Oven.Option.FastPreHeat option (see switch.wall_oven_fast_pre_heat in
# modules/homeassistant.nix) and the two paths raise different events:
# PreheatFinished for a fast preheat, RegularPreheatFinished for a normal one.
# One run raises one of them, and which one depends on an option nobody sets
# from Nix — so listening to only one would work until it silently did not.
# Today only the regular event actually fires: over the recorder window
# wall_oven_regular_pre_heat_finished went `present` ten times and
# wall_oven_pre_heat_finished never did. Fast pre-heat is the unused path, not
# a dead one, so it stays wired rather than being rediscovered later.
#
# Why `not_from` instead of a bare `to`
#
# The same cloud flapping documented in modules/ha-hood-light.nix: Home Connect
# entities go unavailable and come back several times a day. A reconnect that
# lands while the event is still raised arrives as unavailable -> present, and
# a bare `to = "present"` would read that as a fresh preheat and ping again.
# Only a transition from a real state counts. The 10-minute repeat guard below
# is the second layer: `not_from` cannot see a restart that re-fetches the
# appliance status, and a duplicate ping is the one failure mode a human
# notices immediately.
#
# Why the program is read from ACTIVE program only
#
# `select.oven_selected_program` is deliberately not in the condition, and must
# not be added: on this appliance it has never reported a program at all. Ten
# days of recorder history hold nothing but `unknown` (16) and `unavailable`
# (10) for it, because Home Connect only publishes SelectedProgram while the
# appliance is under remote control. `select.oven_active_program` is the one
# that works, and it is already pizza when the event arrives — every run in
# that window looks like this:
#
#   18:09:30  select.oven_active_program           pizza_setting
#   18:25:54  sensor.wall_oven_regular_pre_heat…   present
#   18:26:23  sensor.wall_oven_regular_pre_heat…   off
#   18:51:47  select.oven_active_program           unknown
#
# Preheat takes 13–17 minutes and the event is `present` for about 29 seconds,
# which is ample for a state trigger but is why nothing here polls.
#
# Also not used: `switch.oven_program_pizzasetting`, a leftover from the era
# when Home Connect exposed one switch per program. It is still in the entity
# registry and it is `unavailable` in every record.
#
# BEFORE DEPLOYING: both sops entries below must exist in secrets/rivendell.yaml.
# A missing `!secret` key fails the whole HA config load, which takes HA down —
# not just this automation. home-assistant is in homelab.postUpgradeCheck, so
# an unattended upgrade would roll back and a deploy-rs activation would fail
# and roll back, but the deploy is still wasted.
#
# Entity IDs are the fragile part, and guessing them from the device name gets
# them wrong — "Pre-heat finished" becomes `pre_heat_finished`, not
# `preheat_finished`. Read them out of the registry rather than inferring them
# (no API token needed):
#   ssh rivendell sudo jq -r '.data.entities[]
#     | select(.entity_id | test("oven")) | [.entity_id, .device_id] | @tsv' \
#     /var/lib/homeassistant/config/.storage/core.entity_registry
# The wall oven is device 768e7ba8296039a07d37eb889c205650; the range is
# c04f16d71cc0c2f2a0c89380fbb216b9 and owns every `oven_2_right_*` entity.
#
# To confirm behaviour rather than naming, read the recorder — an automation
# that never fires looks identical to one that was never triggered:
#   ssh rivendell sudo sqlite3 \
#     "file:/var/lib/homeassistant/config/home-assistant_v2.db?immutable=1" \
#     "SELECT datetime(s.last_updated_ts,'unixepoch','localtime'), sm.entity_id, s.state
#        FROM states s JOIN states_meta sm ON s.metadata_id = sm.metadata_id
#       WHERE sm.entity_id IN ('select.oven_active_program',
#                              'sensor.wall_oven_regular_pre_heat_finished')
#       ORDER BY s.last_updated_ts;"

{ config, ... }:

let
  # Home Connect event sensors — Cooking.Oven.Event.PreheatFinished and
  # .RegularPreheatFinished. Fast preheat raises the first, normal the second.
  #
  # Note the entity_id prefixes do not match: these two carry `wall_oven_`
  # while the program select below is still `oven_`. Both belong to the same
  # device (768e7ba8296039a07d37eb889c205650, "Wall Oven"). The device was
  # renamed after the older entities were created and entity_ids do not follow
  # a rename, so the prefix records when each entity first appeared. Do not
  # "correct" either one — copy them from the registry.
  preheatSensors = [
    "sensor.wall_oven_pre_heat_finished"
    "sensor.wall_oven_regular_pre_heat_finished"
  ];

  activeProgram = "select.oven_active_program";

  # Cooking.Oven.Program.HeatingMode.PizzaSetting, as HA translates it into a
  # select option ("Pizza setting" in the UI).
  pizzaProgram = "cooking_oven_program_heating_mode_pizza_setting";

  # Do not ping twice for the same preheat. See the header.
  repeatGuardSeconds = 600;
in
{
  # The webhook URL is the whole credential — anyone holding it can post to the
  # channel. The user id is not secret, but it is rendered from sops too so the
  # public repo does not carry a member id, and so the message body can stay
  # here in Nix rather than inside the secret.
  sops.secrets = {
    # https://discord.com/api/webhooks/<id>/<token>
    # Discord: Server Settings > Integrations > Webhooks > New Webhook, pick
    # the channel, Copy Webhook URL.
    ha_discord_pizza_webhook = { };

    # The numeric id of the member to tag. Discord: enable Developer Mode
    # (Settings > Advanced), then right-click the member > Copy User ID.
    ha_discord_pizza_user_id = { };
  };

  # HA resolves `!secret` against secrets.yaml in its config dir. The
  # container-era file held one unused key and was dropped on migration (see
  # modules/homeassistant.nix); this brings it back as a rendered secret.
  # Further HA secrets belong in this template, not in a second file.
  sops.templates."ha-secrets.yaml" = {
    owner = "hass";
    mode = "0400";
    path = "${config.services.home-assistant.configDir}/secrets.yaml";
    # HA reads secrets.yaml once, at config load. Without this, rotating the
    # webhook would leave the old URL live in a running HA until something else
    # happened to restart it.
    restartUnits = [ "home-assistant.service" ];
    content = ''
      # Rendered by modules/ha-pizza-preheat.nix — do not edit on the host.
      ha_discord_pizza_webhook: ${config.sops.placeholder.ha_discord_pizza_webhook}
      ha_discord_pizza_payload: '{"content": "<@${config.sops.placeholder.ha_discord_pizza_user_id}> :pizza: The wall oven is up to temperature on the pizza setting.", "allowed_mentions": {"parse": [], "users": ["${config.sops.placeholder.ha_discord_pizza_user_id}"]}}'
    '';
  };

  services.home-assistant.config.homeassistant.packages.pizza_preheat = {
    # rest_command, not notify: this is one fire-and-forget POST, and it keeps
    # the whole path declarative. No extraComponents entry is needed —
    # rest_command declares no requirements, so it loads from the package.
    rest_command.discord_pizza_preheat = {
      url = "!secret ha_discord_pizza_webhook";
      method = "post";
      content_type = "application/json";
      payload = "!secret ha_discord_pizza_payload";
    };

    automation = [
      {
        id = "pizza_preheat_discord";
        alias = "Wall Oven: Discord ping when the pizza setting finishes preheating";
        description = "Declared in modules/ha-pizza-preheat.nix — edit there, not in the UI.";
        mode = "single";
        max_exceeded = "silent";
        triggers = [
          {
            trigger = "state";
            entity_id = preheatSensors;
            to = "present";
            not_from = [ "unavailable" "unknown" ];
          }
        ];
        conditions = [
          { condition = "state"; entity_id = activeProgram; state = pizzaProgram; }
          {
            # Two none-checks, both load-bearing. `last_triggered` is None
            # until the first run, and `this` itself is None if the automation
            # has no state yet (components/automation/__init__.py sets
            # `this = state.as_dict()` only `if state :=`) — so this is a plain
            # dict, not a state object, and `.attributes` is a dict lookup.
            # Subtracting from None raises, and a raising condition is an error
            # the automation reports rather than a false, so neither case may
            # reach the arithmetic.
            condition = "template";
            value_template = ''
              {% set last = this.attributes.get('last_triggered') if this is not none else none %}
              {{ last is none or (now() - last).total_seconds() > ${toString repeatGuardSeconds} }}
            '';
          }
        ];
        actions = [
          { action = "rest_command.discord_pizza_preheat"; }
        ];
      }
    ];
  };
}
