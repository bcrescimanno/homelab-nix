# modules/attic.nix — attic self-hosted Nix binary cache server
#
# Runs atticd on mirkwood at port 8080. Served publicly as cache.theshire.io
# via Caddy on rivendell (TLS termination + reverse proxy).
#
# Storage: SQLite DB + NAR storage both on mirkwood's local NVMe at
# /var/lib/atticd/. GC retains entries used within the last 2 weeks.
#
# ---------------------------------------------------------------------------
# Required sops secret (secrets/mirkwood.yaml):
#   attic_env  — env file with the JWT RS256 signing key:
#                  ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=<base64-encoded-rsa-key>
#                Generate:
#                  openssl genrsa 4096 | base64 -w0
#                  # paste output as the value
# ---------------------------------------------------------------------------
#
# Post-deployment setup (one-time, after first deploy):
#
#   1. Get the root token from the journal on mirkwood:
#        ssh brian@mirkwood journalctl -u atticd | grep -i token
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
#        ssh brian@mirkwood sudo atticd-atticadm make-token \
#          --sub "post-build-hook" \
#          --validity "100y" \
#          --pull "nixpkgs" \
#          --push "nixpkgs"
#
#   6. Add the push token to all three sops secrets files as attic_push_token,
#      declare it in each host's sops.secrets block, and redeploy:
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
  services.atticd = {
    enable = true;

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
        interval = 43200;
        # Evict cache entries not accessed within 2 weeks.
        default-retention-period = "2 weeks";
      };
    };
  };

  sops.secrets.attic_env = {
    owner = "atticd";
  };

  # Allow Caddy on rivendell to reach atticd, and Pis to push via post-build hook.
  networking.firewall.allowedTCPPorts = [ 8080 ];
}
