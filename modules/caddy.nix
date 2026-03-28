# modules/caddy.nix — Caddy reverse proxy
#
# Replaces Nginx Proxy Manager with a declarative, native NixOS service.
# Handles wildcard TLS for *.theshire.io via Cloudflare DNS-01 ACME challenge
# (no inbound ports required — cert obtained entirely via Cloudflare API).
#
# Backends use .home.theshire.io hostnames for mirkwood/pirateship.
# Rivendell-local services use 127.0.0.1.
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
      hash = "sha256-bL1cpMvDogD/pdVxGA8CAMEXazWpFDBiGBxG83SmXLA=";
    };

    globalConfig = "";

    virtualHosts = {
      # mirkwood backends
      "homepage.theshire.io".extraConfig       = proxy "mirkwood.home.theshire.io:3000";
      "grafana.theshire.io".extraConfig        = proxy "mirkwood.home.theshire.io:3001";
      "mirkwood-stats.theshire.io".extraConfig = proxy "mirkwood.home.theshire.io:61208";

      # rivendell backends (Caddy runs here — use 127.0.0.1)
      "ha.theshire.io".extraConfig              = proxy "127.0.0.1:8123";
      "rivendell-stats.theshire.io".extraConfig = proxy "127.0.0.1:61208";
      "ntfy.theshire.io".extraConfig            = proxy "127.0.0.1:2586";
      "monitor.theshire.io".extraConfig         = proxy "127.0.0.1:8080";

      # pirateship backends
      "jellyfin.theshire.io".extraConfig         = proxy "pirateship.home.theshire.io:8096";
      "media.theshire.io".extraConfig            = proxy "pirateship.home.theshire.io:8096";
      "movies.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:7878";
      "radar.theshire.io".extraConfig            = proxy "pirateship.home.theshire.io:7878";
      "sonarr.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:8989";
      "tv.theshire.io".extraConfig               = proxy "pirateship.home.theshire.io:8989";
      "prowlarr.theshire.io".extraConfig         = proxy "pirateship.home.theshire.io:9696";
      "trackers.theshire.io".extraConfig         = proxy "pirateship.home.theshire.io:9696";
      "lidarr.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:8686";
      "music.theshire.io".extraConfig            = proxy "pirateship.home.theshire.io:8686";
      "listen.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:4533";
      "dl.theshire.io".extraConfig               = proxy "pirateship.home.theshire.io:9091";
      "nzb.theshire.io".extraConfig              = proxy "pirateship.home.theshire.io:8080";
      "pirateship-stats.theshire.io".extraConfig = proxy "pirateship.home.theshire.io:61208";

      # Blocky DoH — plain HTTP locally, Caddy terminates TLS
      "doh.theshire.io".extraConfig = proxy "127.0.0.1:4000";
    };
  };

  sops.secrets.caddy_cloudflare_env = {
    owner = "caddy";
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile =
    config.sops.secrets.caddy_cloudflare_env.path;

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
