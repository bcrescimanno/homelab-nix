# modules/nut.nix — Network UPS Tools
#
# Monitors the Tripp Lite SMC15002URM UPS connected to rivendell via USB.
# Runs in netserver mode so Home Assistant can connect via the NUT integration.
#
# Secrets required in secrets/rivendell.yaml:
#   nut_upsmon_password  — internal upsmon user password
#   nut_ha_password      — Home Assistant monitor user password
#
# Port: 3493 (NUT default)
# After deploy, configure HA via Settings → Devices → Add Integration → NUT
#   Host: localhost (or rivendell), Port: 3493
#   Username: homeassistant, Password: <nut_ha_password>

{ config, pkgs, ... }:

let
  # Publish UPS events to ntfy via the LAN port (bypasses NPM — more reliable
  # during a real power event when NPM itself might be restarting).
  # NOTIFYTYPE and UPSNAME are set by upsmon before calling this script.
  nutNotify = pkgs.writeShellScript "nut-ntfy-notify" ''
    case "$NOTIFYTYPE" in
      ONBATT)   PRIORITY=4; TAGS=rotating_light ;;
      LOWBATT)  PRIORITY=5; TAGS=warning ;;
      SHUTDOWN) PRIORITY=5; TAGS=skull ;;
      COMMBAD)  PRIORITY=4; TAGS=warning ;;
      ONLINE)   PRIORITY=3; TAGS=white_check_mark ;;
      COMMOK)   PRIORITY=3; TAGS=white_check_mark ;;
      *)        PRIORITY=3; TAGS=electric_plug ;;
    esac

    ${pkgs.curl}/bin/curl -s \
      -H "Title: UPS: $NOTIFYTYPE" \
      -H "Priority: $PRIORITY" \
      -H "Tags: $TAGS" \
      -d "UPS $UPSNAME: $NOTIFYTYPE" \
      http://rivendell:2586/homelab
  '';
in

{
  power.ups = {
    enable = true;
    mode = "netserver";

    ups.tripplite = {
      driver = "usbhid-ups";
      port = "auto";
      description = "Tripp Lite SMC15002URM";
      directives = [
        "vendorid = 09AE"
        "productid = 3015"
      ];
    };

    upsd = {
      listen = [{ address = "0.0.0.0"; port = 3493; }];
    };

    users = {
      # Internal user for upsmon to authenticate with upsd
      upsmon = {
        passwordFile = config.sops.secrets.nut_upsmon_password.path;
        upsmon = "primary";
      };
      # User for Home Assistant NUT integration
      homeassistant = {
        passwordFile = config.sops.secrets.nut_ha_password.path;
      };
    };

    upsmon = {
      monitor.tripplite = {
        system = "tripplite@localhost";
        powerValue = 1;
        user = "upsmon";
        passwordFile = config.sops.secrets.nut_upsmon_password.path;
        type = "primary";
      };

      settings = {
        NOTIFYCMD = "${nutNotify}";
        NOTIFYFLAG = [
          ["ONBATT"   "SYSLOG+EXEC"]
          ["LOWBATT"  "SYSLOG+EXEC"]
          ["ONLINE"   "SYSLOG+EXEC"]
          ["COMMBAD"  "SYSLOG+EXEC"]
          ["COMMOK"   "SYSLOG+EXEC"]
          ["SHUTDOWN" "SYSLOG+EXEC"]
        ];
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 3493 ];

  # ---------------------------------------------------------------------------
  # Prometheus exporter
  #
  # Until 2026-08-01 the UPS was visible only to Home Assistant and to upsmon's
  # NOTIFYCMD pushes. Nothing recorded battery charge, load, or input voltage
  # over time, so "the UPS has been running hot for a month" or "runtime is half
  # what it was a year ago" were unanswerable. This feeds the UPS alert rules in
  # modules/grafana.nix.
  #
  # Deliberately reuses the existing read-only `homeassistant` monitor account
  # rather than adding a third NUT user: it already has exactly the access an
  # exporter needs (read variables, no instcmds), and a new user would mean a new
  # sops secret for no additional isolation. Both consumers are read-only and
  # local, so a shared credential costs nothing here. If that ever stops being
  # true, add a dedicated `prometheus` user with its own nut_prom_password.
  services.prometheus.exporters.nut = {
    enable = true;
    port = 9199;
    nutServer = "127.0.0.1";
    nutUser = "homeassistant";
    passwordPath = config.sops.secrets.nut_ha_password.path;
    openFirewall = true;
  };

  # The exporter reads the password file directly (`NUT_EXPORTER_PASSWORD=$(cat
  # …)` in its ExecStart) and runs under DynamicUser, so it needs group access
  # to the sops-rendered secret. The matching mode/group is set on the secret in
  # hosts/rivendell.nix.
  users.groups.nut-monitor = {};
  systemd.services.prometheus-nut-exporter.serviceConfig.SupplementaryGroups =
    [ config.users.groups.nut-monitor.name ];

  homelab.postUpgradeCheck.services = [ "upsd" "upsmon" ];
}
