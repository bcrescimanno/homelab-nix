# modules/post-upgrade-check.nix — post-upgrade local service health check
#
# Runs after homelab-upgrade.service succeeds. Verifies that every service
# module declared in homelab.postUpgradeCheck.services is active before
# sending the success notification.
#
# On any service being inactive: sends a priority-4 ntfy alert and exits
# non-zero (journalctl -u homelab-upgrade-check shows which services failed).
#
# Service modules opt in by adding:
#   homelab.postUpgradeCheck.services = [ "my-service" ];
# Lists from all imported modules are merged automatically.

{ config, pkgs, lib, ... }:

{
  options.homelab.postUpgradeCheck.services = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "systemd service names to verify are active after upgrade";
  };

  config.systemd.services.homelab-upgrade-check = {
    description = "Post-upgrade service health check";
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = 10;
      ExecStart =
        let
          svcList = config.homelab.postUpgradeCheck.services;
          script =
            if svcList == [] then "exit 0"
            else ''
              failed=()
              for svc in ${lib.concatStringsSep " " svcList}; do
                status=$(systemctl is-active "$svc.service" 2>/dev/null || echo inactive)
                [[ "$status" == "active" ]] || failed+=("$svc: $status")
              done
              if [[ ''${#failed[@]} -gt 0 ]]; then
                echo "post-upgrade checks failed: ''${failed[*]}" >&2
                exit 1
              fi
            '';
        in toString (pkgs.writeShellScript "homelab-upgrade-check" script);
    };
    unitConfig = {
      OnFailure = "homelab-upgrade-notify-unhealthy.service";
    };
  };

  config.systemd.services.homelab-upgrade-notify-unhealthy = {
    description = "Notify ntfy of post-upgrade health check failure";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.curl}/bin/curl -s "
        + "--connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors "
        + "-H 'Title: NixOS Upgraded but Unhealthy' "
        + "-H 'Priority: 4' "
        + "-H 'Tags: rotating_light' "
        + "-d '${config.networking.hostName} upgraded but services failed post-upgrade check — see journalctl -u homelab-upgrade-check' "
        + "http://10.0.1.9:2586/homelab";
    };
  };
}
