# modules/attic.nix — attic self-hosted Nix binary cache server
#
# Runs atticd on orthanc at port 8080. Served as cache.theshire.io via Caddy
# on rivendell (TLS termination + reverse proxy) — LAN and tailnet only. Public
# DNS resolves the name to the WAN IP, but nothing forwards 443 to Caddy (it
# lands on the UDM itself), which is what makes pushing unfree closures (terra's
# NVIDIA driver, Steam) acceptable. Never publish this through the tunnel.
#
# Storage: SQLite DB + NAR storage on orthanc's NVMe at /var/lib/atticd/.
# GC evicts cache entries by `default-retention-period` below, which is the one
# place that duration is written down — don't restate it elsewhere. A copy of it
# in hosts/orthanc.nix drifted to "2 weeks" and went unnoticed until 2026-09-19.
#
# ---------------------------------------------------------------------------
# Required sops secret (secrets/orthanc.yaml):
#   attic_env  — env file with the JWT RS256 signing key:
#                  ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=<base64-encoded-rsa-key>
#                Generate:
#                  openssl genrsa 4096 | base64 -w0
#                  # paste output as the value
# ---------------------------------------------------------------------------
#
# Post-deployment setup (one-time, after first deploy):
#
#   1. Get the root token from the journal on orthanc:
#        ssh brian@orthanc journalctl -u atticd | grep -i token
#
#   2. Install attic-client locally and log in:
#        nix run nixpkgs#attic-client -- login homelab https://cache.theshire.io <root-token>
#
#   3. Create the nixpkgs cache:
#        nix run nixpkgs#attic-client -- cache create homelab:nixpkgs
#
#   4. Get the cache signing public key (for flake.nix trusted-public-keys):
#        nix run nixpkgs#attic-client -- cache info homelab:nixpkgs
#        # Copy the "Cache Public Key" value
#
#   5. Generate a push token for the post-build hook:
#        ssh brian@orthanc sudo atticd-atticadm make-token \
#          --sub "post-build-hook" \
#          --validity "100y" \
#          --pull "nixpkgs" \
#          --push "nixpkgs"
#
#   6. Add the push token to all host sops secrets files as attic_push_token,
#      declare it in each host's sops.secrets block, and redeploy:
#        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/orthanc.yaml
#        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
#        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
#        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
#
#   7. Add the public key from step 4 to:
#      - flake.nix: nixConfig.extra-trusted-public-keys
#      - modules/base.nix: nix.settings.extra-trusted-public-keys
#      Then redeploy all hosts.

{ config, pkgs, lib, ... }:

{
  imports = [ (import ../lib/homelab.nix "atticd") ];

  services.atticd = {
    enable = true;

    # attic-sqlite-pragmas.patch: atticd meant to run SQLite with
    # synchronous=normal (plus temp_store/mmap_size), but applied the pragmas
    # with one execute_unprepared on the POOL, which reaches a single pooled
    # connection. The rest stayed on sqlx's default synchronous=FULL, so every
    # chunk commit fsynced db.sqlite-wal: measured 2026-10-09 at ~150 fsyncs/s
    # of ~6 ms each on the 970 EVO Plus, one thread ~93% blocked in fsync, and
    # pushes crawling at ~2-4 MiB/s on gigabit (terra's first 2.4 GiB push).
    # The patch sets them through SeaORM's connect options, so every
    # connection gets them. NORMAL in WAL mode cannot corrupt the database; a
    # power cut can lose the last commits, which for a cache is a re-push.
    #
    # Deliberately a package override here, not a flake overlay: the
    # attic-client on every other host is untouched, and check-overlays'
    # "builds unpatched → droppable" test would misread a performance fix
    # that always builds. Instead the patch is its own expiry signal — it
    # stops applying once upstream touches this block (lib.rs, State::database).
    #
    # Separately, the DB had never been ANALYZEd: with no sqlite_stat1 the
    # planner served chunk-hash lookups from idx-chunk-state-holders (state='V'
    # matches ~94% of rows), a near-full scan per chunk. `ANALYZE` was run by
    # hand on 2026-10-09; the statistics live in db.sqlite, so a restored or
    # recreated DB needs it again:
    #   sudo sqlite3 /var/lib/private/atticd/db.sqlite 'ANALYZE;'
    package = pkgs.attic-server.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./attic-sqlite-pragmas.patch ];
    });

    # JWT RS256 signing key — read from sops secret at runtime, never hits /nix/store.
    environmentFile = config.sops.secrets.attic_env.path;

    settings = {
      listen = "[::]:8080";

      # Canonical public URL (must end with /). Caddy on rivendell terminates TLS.
      api-endpoint = "https://cache.theshire.io/";
      allowed-hosts = [ "cache.theshire.io" ];

      database.url = "sqlite:///var/lib/atticd/db.sqlite?mode=rwc";

      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      compression.type = "zstd";

      garbage-collection = {
        # Run GC every 12 hours to keep storage bounded.
        interval = "12h";
        # Evict cache entries not accessed within 6 weeks.
        default-retention-period = "6 weeks";
      };
    };
  };

  sops.secrets.attic_env = {
    owner = "atticd";
  };

  # Allow Caddy on rivendell to reach atticd (public proxy) and any hosts that
  # push directly over LAN.
  networking.firewall.allowedTCPPorts = [ 8080 ];

  homelab.postUpgradeCheck.services = [ "atticd" ];
}
