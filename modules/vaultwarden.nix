# modules/vaultwarden.nix — Vaultwarden password manager (native NixOS service)
#
# Bitwarden-compatible server, replacing 1Password. The clients are the
# official Bitwarden apps (desktop, iOS, browser extensions) pointed at
# https://vault.theshire.io via their "self-hosted" server setting. Everything
# is end-to-end encrypted client-side; this server stores ciphertext and syncs.
#
# PUBLIC, via the Cloudflare Tunnel on orthanc (hosts/orthanc.nix) → Caddy on
# rivendell → here. Inside the house vault.theshire.io resolves to Caddy
# directly through the Blocky split-horizon wildcard; outside, the public
# CNAME goes through the tunnel. Same URL everywhere, so the clients never
# need to know which network they are on — that was the reason for choosing
# the tunnel over a VPN: the apps are read-only when they cannot reach the
# server, and a save should never depend on remembering to connect first.
#
# Public exposure is why the controls below are not optional:
#   - signups closed (single user)
#   - no /admin
#   - two-step login on the account (enforced by habit, not config)
#   - real client IPs for the login rate limit — see the vault vhost in
#     modules/caddy.nix; Vaultwarden reads X-Real-IP, which Caddy always sets.
# Cloudflare Access cannot sit in front of this: the Bitwarden apps cannot
# complete an Access login, so it would break every client.
#
# Fully declarative on purpose: there is NO admin page. ADMIN_TOKEN is unset,
# which disables /admin entirely. That matters beyond attack surface — settings
# saved through /admin land in $DATA_FOLDER/config.json, which OVERRIDES the
# environment, so the admin page would silently shadow this file.
#
# Signups are CLOSED. They were open only to bootstrap the single account.
# There is no SMTP and no /admin, so nothing else can register. Adding a
# person later means setting SIGNUPS_ALLOWED again — and because the server is
# public, anyone who finds it can register in that window, so keep it short.
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

      SIGNUPS_ALLOWED = false;
      # No SMTP: verification mail can never be sent and invitations would
      # dead-end. With no mail, a hint would be displayed to anyone who types
      # the email address, so hints are off.
      SIGNUPS_VERIFY      = false;
      INVITATIONS_ALLOWED = false;
      SHOW_PASSWORD_HINT  = false;

      # Client IP for the login/2FA rate limit. X-Real-IP is Vaultwarden's
      # default and is spelled out because the value only means something in
      # combination with the Caddy vhost, which overwrites it on every request
      # (CF-Connecting-IP via the tunnel, the peer address on the LAN). It is
      # honoured only from local addresses (IP_HEADER_TRUSTED_PROXIES=local),
      # which Caddy on 127.0.0.1 is. NOT X-Forwarded-For: through Cloudflare
      # its leftmost entry is client-supplied.
      IP_HEADER = "X-Real-IP";

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
