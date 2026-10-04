# modules/ha-chores.nix — household chores that a sensor can see
#
# Home Assistant package `chores`, read-only in the UI. One entity,
# sensor.chores: its state is how many chores are due and its `chores`
# attribute is their labels, in the order of `chores` below. Two consumers:
#
#   07:25 / 08:10  the daily digest lists them in its Chores section
#                  (modules/daily-digest.py reads this sensor over HA's API)
#   20:05          a push to Brian's phone if anything is still due
#
# Adding a chore is adding an entry to `chores`: the entity, the state that
# means "needs doing", and the line to show. Both consumers pick it up.
#
# WHY THE SENSOR LATCHES
#
# The Roborock entities are cloud-backed and go `unavailable` for seconds to
# minutes several times a day (and once for 32 hours, 2026-09-28) as the
# integration reconnects. A chore read straight off the source would vanish
# from a digest built during one of those gaps. So `unavailable`/`unknown`
# keeps whatever the chore was last known to be, and only a real state
# decides it. Trigger-based template entities restore across restarts, so the
# latch survives one too. The cost is that a sensor dead for days keeps its
# last answer; `offline` lists those for anyone debugging.

{ ... }:

let
  chores = [
    {
      # The dock's tank, not the robot's (that is
      # binary_sensor.kitchen_robo_water_shortage). device_class problem, so
      # `on` = empty.
      entity = "binary_sensor.kitchen_robo_dock_clean_water_box";
      state = "on";
      label = "Fill the Roborock's clean water tank";
    }
  ];

  sensor = "sensor.chores";
  phone = "notify.brians_iphone";  # live registration; see ha-window-notifications.nix

  # A chore is due when its source reads `state`, and stays due (or not) while
  # the source is unavailable. JSON is valid Jinja literal syntax.
  latched = pick: out: ''
    {% set prev = this.attributes.get('chores', []) if this.attributes is defined else [] %}
    {% set ns = namespace(out=[]) %}
    {% for c in ${builtins.toJSON chores} %}
      {% set s = states(c.entity) %}
      {% set offline = s in ['unavailable', 'unknown'] %}
      {% set due = s == c.state or (offline and c.label in prev) %}
      {% if ${pick} %}{% set ns.out = ns.out + [c.label] %}{% endif %}
    {% endfor %}
    {{ ${out} }}'';
in
{
  services.home-assistant.config.homeassistant.packages.chores = {
    template = [
      {
        triggers = [
          { trigger = "state"; entity_id = map (c: c.entity) chores; }
          { trigger = "homeassistant"; event = "start"; }
        ];
        sensor = [
          {
            name = "Chores";
            unique_id = "chores";
            icon = "mdi:clipboard-check-outline";
            state = latched "due" "ns.out | length";
            attributes = {
              chores = latched "due" "ns.out";
              offline = latched "offline" "ns.out";
            };
          }
        ];
      }
    ];

    automation = [
      {
        id = "chores_evening_reminder";
        alias = "Chores: evening reminder";
        description = "Declared in modules/ha-chores.nix — edit there, not in the UI.";
        mode = "single";
        triggers = [ { trigger = "time"; at = "20:05:00"; } ];
        conditions = [
          { condition = "numeric_state"; entity_id = sensor; above = 0; }
        ];
        actions = [
          {
            action = "notify.send_message";
            target.entity_id = phone;
            data = {
              title = "Chores";
              message = "{{ state_attr('${sensor}', 'chores') | join('\\n') }}";
            };
          }
        ];
      }
    ];
  };
}
