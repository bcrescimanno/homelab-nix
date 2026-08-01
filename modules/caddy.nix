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

  # Serve a static site out of the Nix store. try_files sends unknown paths to
  # index.html because these are client-side-routed SPAs — without it a reload
  # on any route but / is a 404.
  static = root: ''
    root * ${root}
    try_files {path} /index.html
    file_server
    ${tlsConfig}
  '';

  # Origin allowed to make cross-origin API calls to Invidious. See the CORS
  # section in modules/materialious.nix.
  materialiousOrigin = "https://yt.theshire.io";
in

{
  services.caddy = {
    enable = true;

    # NB: this hash covers the resolved Go module graph, not just the Caddy
    # version — a nixpkgs Go toolchain bump moves it even when Caddy itself is
    # unchanged (2.11.4 + go 1.26.5 did exactly that on 2026-07-31). Always take
    # the replacement from the "got:" line of the build error.
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.3" ];
      hash = "sha256-to0fhW7LWBocw1ccpPQ7e2nod7iJO9gkWZpjHsZDeu4=";
    };

    globalConfig = "";

    virtualHosts = {
      # mirkwood backends
      "homepage.theshire.io".extraConfig       = proxy "mirkwood.home.theshire.io:3000";
      "grafana.theshire.io".extraConfig        = proxy "mirkwood.home.theshire.io:3001";
      "mirkwood-stats.theshire.io".extraConfig = proxy "mirkwood.home.theshire.io:61208";
      "cache.theshire.io".extraConfig          = proxy "orthanc.home.theshire.io:8080";

      # rivendell backends (Caddy runs here — use 127.0.0.1)
      "ha.theshire.io".extraConfig              = proxy "127.0.0.1:8123";
      "rivendell-stats.theshire.io".extraConfig = proxy "127.0.0.1:61208";
      "ntfy.theshire.io".extraConfig            = proxy "127.0.0.1:2586";
      "monitor.theshire.io".extraConfig         = proxy "127.0.0.1:8080";

      # rivendell backends (continued)
      "listen.theshire.io".extraConfig = proxy "127.0.0.1:8095";

      # orthanc backends
      "jellyfin.theshire.io".extraConfig         = proxy "orthanc.home.theshire.io:8096";
      "media.theshire.io".extraConfig            = proxy "orthanc.home.theshire.io:8096";
      "piped.theshire.io".extraConfig            = proxy "orthanc.home.theshire.io:8181";
      "piped-api.theshire.io".extraConfig        = proxy "orthanc.home.theshire.io:8180";
      # flush_interval -1 disables Caddy's response buffering so video chunks are
      # forwarded to the client immediately. Without this, Firefox's MSE times out
      # waiting for the initial data and aborts the request before playback starts.
      # WebKit is more tolerant of buffering delays, which is why Safari/Orion work.
      "piped-proxy.theshire.io".extraConfig      = ''
        reverse_proxy orthanc.home.theshire.io:8182 {
          flush_interval -1
        }
        ${tlsConfig}
      '';
      # Invidious — trial replacement for Piped, running alongside it.
      # flush_interval -1 for the same reason as piped-proxy above: video is
      # streamed through this vhost (invidious proxies its companion rather than
      # exposing it), and Caddy's default response buffering makes Firefox's MSE
      # time out before playback starts.
      #
      # The CORS block exists for the Materialious frontend below, which runs
      # in the browser on a different origin and calls this API directly.
      # Invidious has no CORS setting of its own, so it has to happen here.
      # Pinned to the one origin rather than `*` because the requests are sent
      # with credentials, which `*` is not valid for.
      #
      # `defer` makes Caddy write these at response time so they REPLACE the
      # Access-Control-Allow-Origin Invidious sets itself, rather than
      # appending a second, conflicting one (browsers reject duplicates).
      #
      # handle/respond rather than a bare `respond` so the preflight short
      # circuit is explicitly ordered ahead of the proxy instead of relying on
      # Caddy's implicit directive order.
      "invidious.theshire.io".extraConfig        = ''
        @cors_preflight method OPTIONS
        handle @cors_preflight {
          respond 204
        }

        header {
          Access-Control-Allow-Credentials true
          Access-Control-Allow-Origin "${materialiousOrigin}"
          Access-Control-Allow-Methods "GET, POST, OPTIONS, HEAD, PATCH, PUT, DELETE"
          Access-Control-Allow-Headers "User-Agent, Authorization, Content-Type"
          defer
        }

        reverse_proxy orthanc.home.theshire.io:3000 {
          flush_interval -1
        }
        ${tlsConfig}
      '';

      # Materialious — static SPA built by modules/materialious.nix and served
      # straight from the store; there is no backend process for this vhost.
      # It talks to invidious.theshire.io above from the browser.
      "yt.theshire.io".extraConfig               = static "${pkgs.materialious}";

      # pirateship backends
      "stream.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:4533";
      "movies.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:7878";
      "radar.theshire.io".extraConfig            = proxy "pirateship.home.theshire.io:7878";
      "sonarr.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:8989";
      "tv.theshire.io".extraConfig               = proxy "pirateship.home.theshire.io:8989";
      "prowlarr.theshire.io".extraConfig         = proxy "pirateship.home.theshire.io:9696";
      "trackers.theshire.io".extraConfig         = proxy "pirateship.home.theshire.io:9696";
      "lidarr.theshire.io".extraConfig           = proxy "pirateship.home.theshire.io:8686";
      "music.theshire.io".extraConfig            = proxy "pirateship.home.theshire.io:8686";
      "dl.theshire.io".extraConfig               = proxy "pirateship.home.theshire.io:9091";
      "nzb.theshire.io".extraConfig              = proxy "pirateship.home.theshire.io:8080";
      "pirateship-stats.theshire.io".extraConfig = proxy "pirateship.home.theshire.io:61208";
      "subtitles.theshire.io".extraConfig        = proxy "pirateship.home.theshire.io:6767";

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

  homelab.postUpgradeCheck.services = [ "caddy" ];
}
