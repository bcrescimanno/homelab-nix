# modules/caddy.nix — Caddy reverse proxy
#
# Replaces Nginx Proxy Manager with a declarative, native NixOS service.
# Handles wildcard TLS for *.theshire.io via Cloudflare DNS-01 ACME challenge
# (no inbound ports required — cert obtained entirely via Cloudflare API).
#
# Backends use .local hostnames which resolve via networking.search = ["local"]
# (set in base.nix). Rivendell-local services use 127.0.0.1.
#
# Required sops secret (secrets/rivendell.yaml):
#   caddy_cloudflare_env  — env file containing:
#                             CLOUDFLARE_API_TOKEN=<token>

{ config, pkgs, lib, ... }:

let
  # Technitium is authoritative for theshire.io locally, so it can't verify
  # _acme-challenge TXT records created at Cloudflare. Specifying public
  # resolvers in the per-site tls block requires the DNS provider to be
  # declared there too (global acme_dns is not inherited by the tls block).
  tlsConfig = ''
    tls {
      dns cloudflare {$CLOUDFLARE_API_TOKEN}
      resolvers 1.1.1.1 8.8.8.8
    }
  '';

  proxy = target: "reverse_proxy ${target}\n${tlsConfig}";

  httpsProxy = target: ''
    reverse_proxy ${target} {
      transport http {
        tls_insecure_skip_verify
      }
    }
    ${tlsConfig}
  '';
in

{
  services.caddy = {
    enable = true;

    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.3" ];
      hash = "sha256-eDCHOuPm+o3mW7y8nSaTnabmB/msw6y2ZUoGu56uvK0=";
    };

    globalConfig = "";

    virtualHosts = {
      # mirkwood backends
      "home.theshire.io".extraConfig           = proxy "mirkwood.local:3000";
      "ns1.theshire.io".extraConfig            = proxy "mirkwood.local:5380";
      "mirkwood-stats.theshire.io".extraConfig = proxy "mirkwood.local:61208";

      # rivendell backends (Caddy runs here — use 127.0.0.1)
      "ha.theshire.io".extraConfig              = proxy "127.0.0.1:8123";
      "ns2.theshire.io".extraConfig             = proxy "127.0.0.1:5380";
      "rivendell-stats.theshire.io".extraConfig = proxy "127.0.0.1:61208";
      "ntfy.theshire.io".extraConfig            = proxy "127.0.0.1:2586";
      "monitor.theshire.io".extraConfig         = proxy "127.0.0.1:3001";

      # pirateship backends
      "jellyfin.theshire.io".extraConfig         = proxy "pirateship.local:8096";
      "media.theshire.io".extraConfig            = proxy "pirateship.local:8096";
      "movies.theshire.io".extraConfig           = proxy "pirateship.local:7878";
      "radar.theshire.io".extraConfig            = proxy "pirateship.local:7878";
      "sonarr.theshire.io".extraConfig           = proxy "pirateship.local:8989";
      "tv.theshire.io".extraConfig               = proxy "pirateship.local:8989";
      "prowlarr.theshire.io".extraConfig         = proxy "pirateship.local:9696";
      "trackers.theshire.io".extraConfig         = proxy "pirateship.local:9696";
      "lidarr.theshire.io".extraConfig           = proxy "pirateship.local:8686";
      "music.theshire.io".extraConfig            = proxy "pirateship.local:8686";
      "dl.theshire.io".extraConfig               = proxy "pirateship.local:9091";
      "nzb.theshire.io".extraConfig              = proxy "pirateship.local:8080";
      "pirateship-stats.theshire.io".extraConfig = proxy "pirateship.local:61208";

      # HTTPS upstream — backend cert may be self-signed
      "doh.theshire.io".extraConfig = httpsProxy "https://10.0.1.8:5381";
    };
  };

  sops.secrets.caddy_cloudflare_env = {
    owner = "caddy";
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile =
    config.sops.secrets.caddy_cloudflare_env.path;

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
