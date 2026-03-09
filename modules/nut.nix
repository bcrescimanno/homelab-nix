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

{ config, ... }:

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
    };
  };

  networking.firewall.allowedTCPPorts = [ 3493 ];
}
