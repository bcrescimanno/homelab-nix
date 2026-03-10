# modules/backup.nix — Restic backup for service configs
#
# Backs up service config directories to two destinations:
#   - Onsite:  erebor NFS share  (/var/backup/erebor/<hostname>)
#   - Offsite: Cloudflare R2 bucket (homelab-backup/<hostname>)
#
# Usage: set homelab.backup.paths in each host config.
#
# Required sops secrets (add to secrets/<host>.yaml):
#   restic_password   — encryption password for both repos
#   restic_r2_env     — env file with R2 API credentials:
#                         AWS_ACCESS_KEY_ID=...
#                         AWS_SECRET_ACCESS_KEY=...

{ config, lib, r2AccountId, ... }:

{
  options.homelab.backup.paths = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Paths to back up with restic (onsite + offsite).";
  };

  config = lib.mkIf (config.homelab.backup.paths != []) {

    # NFS client support (idempotent — pirateship already has this)
    boot.supportedFilesystems = [ "nfs" ];
    services.rpcbind.enable = true;

    fileSystems."/var/backup/erebor" = {
      device = "erebor.theshire.io:/var/nfs/shared/backups";
      fsType = "nfs";
      options = [ "_netdev" "nofail" "x-systemd.automount" "noauto" ];
    };

    sops.secrets.restic_password = {};
    sops.secrets.restic_r2_env = {};

    services.restic.backups = {

      local = {
        initialize = true;
        paths = config.homelab.backup.paths;
        repository = "/var/backup/erebor/${config.networking.hostName}";
        passwordFile = config.sops.secrets.restic_password.path;
        timerConfig = {
          OnCalendar = "03:00";
          RandomizedDelaySec = "1h";
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 12"
        ];
      };

      offsite = {
        initialize = true;
        paths = config.homelab.backup.paths;
        repository = "s3:https://${r2AccountId}.r2.cloudflarestorage.com/homelab-backup/${config.networking.hostName}";
        passwordFile = config.sops.secrets.restic_password.path;
        environmentFile = config.sops.secrets.restic_r2_env.path;
        timerConfig = {
          OnCalendar = "04:00";
          RandomizedDelaySec = "1h";
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 12"
        ];
      };
    };
  };
}
