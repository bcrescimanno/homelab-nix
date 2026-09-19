# modules/vaultwarden.nix — Vaultwarden password manager (native NixOS service)
#
# Bitwarden-compatible server, replacing 1Password. The clients are the
# official Bitwarden apps (desktop, iOS, browser extensions) pointed at
# https://vault.theshire.io via their "self-hosted" server setting. Everything
# is end-to-end encrypted client-side; this server stores ciphertext and syncs.
#
# LAN-only for now. vault.theshire.io resolves via the Blocky split-horizon
# wildcard and has no public record or tunnel. Consequence: away from home the
# clients work from their read-only offline cache — new logins and passkeys can
# only be SAVED when the server is reachable. Remote access (Tailscale vs.
# Cloudflare Tunnel) is an open decision, not an oversight.
#
# Fully declarative on purpose: there is NO admin page. ADMIN_TOKEN is unset,
# which disables /admin entirely. That matters beyond attack surface — settings
# saved through /admin land in $DATA_FOLDER/config.json, which OVERRIDES the
# environment, so the admin page would silently shadow this file.
#
# Signups: SIGNUPS_ALLOWED is true ONLY to bootstrap the first account(s).
# Flip it to false once they exist — there is no SMTP, so without signups and
# without /admin, nobody else can ever register.
#
# Feature flags: SSH keys are still a gated client feature against Vaultwarden.
# `ssh-key-vault-item` adds the item type, `ssh-agent`/`ssh-agent-v2` turn on
# the desktop agent. `cxp-*-mobile` enable iOS Credential Exchange import/export
# — the only path that moves passkeys between managers. Clients cache
# /api/config for ~1h, so a flag change takes up to an hour to show up.
# Valid names are listed in the .env.template of the running version; an
# unknown flag is dropped (FeatureFlagFilter::ValidOnly), not an error.
#
# Backups: the live SQLite DB is never read by restic. backup-vaultwarden takes
# a consistent `sqlite3 .backup` snapshot (plus attachments, sends and the RSA
# key) into backupDir at 02:30, and restic's 03:00 run picks up that directory.
# Restore = stop vaultwarden, copy backupDir back into /var/lib/vaultwarden,
# chown vaultwarden:vaultwarden, start. vaultwarden is a static user (not
# DynamicUser), so /var/lib/vaultwarden is a real directory — no
# /var/lib/private trap here.

{ config, pkgs, lib, ... }:

let
  ntfyUrl   = "http://10.0.1.9:2586/homelab";
  host      = config.networking.hostName;
  backupDir = "/var/backup/vaultwarden";
in

{
  services.vaultwarden = {
    enable = true;
    inherit backupDir;

    config = {
      DOMAIN = "https://vault.theshire.io";

      # Caddy on the same host is the only way in.
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT    = 8222;

      # Bootstrap only — see the header. Set to false after account creation.
      SIGNUPS_ALLOWED = true;
      # No SMTP: verification mail can never be sent and invitations would
      # dead-end. With no mail, a hint would be displayed to anyone who types
      # the email address, so hints are off.
      SIGNUPS_VERIFY      = false;
      INVITATIONS_ALLOWED = false;
      SHOW_PASSWORD_HINT  = false;

      # Caddy sets X-Forwarded-For, not X-Real-IP. Trusted only from local
      # (non-global) addresses by default, which covers Caddy on 127.0.0.1.
      # Without this every login rate-limit and failure log sees 127.0.0.1.
      IP_HEADER = "X-Forwarded-For";

      EXPERIMENTAL_CLIENT_FEATURE_FLAGS = lib.concatStringsSep "," [
        "ssh-key-vault-item"
        "ssh-agent"
        "ssh-agent-v2"
        "cxp-import-mobile"
        "cxp-export-mobile"
      ];
    };
  };

  # Snapshot just before restic's 03:00 local run (modules/backup.nix), so the
  # nightly archive is at most 30 minutes stale instead of the module's
  # default 23:00 → 4h.
  systemd.timers.backup-vaultwarden.timerConfig.OnCalendar = "02:30";

  # A failing snapshot would otherwise be invisible: restic would keep happily
  # archiving the last good copy, and the restic freshness check only proves
  # restic ran.
  systemd.services.backup-vaultwarden.unitConfig.OnFailure =
    "backup-vaultwarden-notify-failure.service";

  systemd.services.backup-vaultwarden-notify-failure = {
    description = "Notify ntfy that the Vaultwarden snapshot failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.curl}/bin/curl -s --connect-timeout 5 --max-time 30 \
          --retry 3 --retry-delay 10 --retry-all-errors \
          -H 'Title: Vaultwarden snapshot FAILED' \
          -H 'Priority: 4' \
          -H 'Tags: warning' \
          -d '${host}: backup-vaultwarden failed, restic is archiving a stale vault — check journalctl -u backup-vaultwarden' \
          ${ntfyUrl}
      '';
    };
  };

  # The vault.theshire.io vhost lives in modules/caddy.nix with the others.

  homelab.backup.paths = [ backupDir ];

  homelab.postUpgradeCheck.services = [ "vaultwarden" ];
}
