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

  # The origin permitted to make cross-origin calls, which is now the STOCK
  # Invidious UI rather than Materialious — the direction reversed when
  # Invidious' `domain` became yt.theshire.io. See the CORS note on the yt
  # vhost below.
  invidiousOrigin = "https://invidious.theshire.io";

  # The Invidious paths Materialious actually touches, proxied under
  # yt.theshire.io so the browser never leaves that origin. Derived from
  # Invidious' own route table (src/invidious/routing.cr) intersected with what
  # Materialious calls — NOT guessed:
  #   /api          v1 endpoints + /api/manifest/dash (the DASH manifest)
  #   /companion    where /api/manifest 302s to; carries the media bytes
  #   /vi /ggpht    thumbnail and channel-avatar proxies
  #   /sb           storyboard images
  #   /authorize_token /login   the Invidious OAuth-ish flow (src/lib/auth.ts:81)
  #
  # None of these collide with a Materialious client route — note it uses
  # /internal/login, not /login. Invidious owns far more top-level paths than
  # these (/watch, /channel, /search, /feed...), and those deliberately stay
  # with Materialious; it does not need Invidious' HTML pages at all.
  invidiousPaths = "/api/* /companion/* /vi/* /ggpht/* /sb/* /authorize_token /login";
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
      # NO CORS BLOCK HERE ANY MORE — it moved to the yt vhost below, because
      # the direction of the cross-origin request reversed. Invidious' `domain`
      # is now yt.theshire.io (see modules/invidious.nix), so this vhost serves
      # the stock UI HTML while every absolute URL inside it points at yt —
      # making the STOCK UI the cross-origin consumer and Materialious purely
      # first-party.
      "invidious.theshire.io".extraConfig        = ''
        reverse_proxy orthanc.home.theshire.io:3000 {
          flush_interval -1
        }
        ${tlsConfig}
      '';

      # Materialious — static SPA built by modules/materialious.nix, served
      # straight from the store, PLUS a reverse proxy for the handful of
      # Invidious paths it calls.
      #
      # Everything on ONE origin, deliberately. Serving the app and the API from
      # two hostnames made every media fetch a cross-origin request, which cost
      # a CORS preflight per byte-range and made the traffic look like a public
      # page reaching into RFC1918 space — something privacy extensions treat as
      # hostile. Same origin means no preflight, no CORS headers, and nothing
      # third-party to inspect. See the header of modules/materialious.nix.
      #
      # try_files sends unknown paths to index.html because this is a
      # client-side-routed SPA; without it a reload on any route but / 404s.
      # The handle blocks are mutually exclusive and evaluated in order, so the
      # proxy wins for Invidious paths and the SPA catches everything else.
      # The CORS block below is NOT for Materialious — that is same-origin now
      # and needs none of it. It is for the STOCK Invidious UI at
      # invidious.theshire.io, which since the `domain` change receives
      # yt.theshire.io URLs for its own media and is therefore the cross-origin
      # consumer. Without it the stock UI, our control for the Invidious trial,
      # would break.
      #
      # `Range` is mandatory: Invidious' DASH uses <SegmentBase> with
      # indexRange, so every media fetch is a byte-range request, and Range is
      # not CORS-safelisted. Omitting it is a TOTAL playback failure while the
      # rest of the UI works perfectly, because plain GETs are never
      # preflighted. Expose-Headers is needed because cross-origin response
      # headers are invisible to JS, and Shaka/videojs read Content-Range and
      # Content-Length to size buffers.
      #
      # `defer` makes Caddy write these at response time so they REPLACE the
      # Access-Control-Allow-Origin Invidious sets itself rather than appending
      # a second, conflicting one (browsers reject duplicates).
      #
      # The preflight handle is ordered ahead of the proxy explicitly rather
      # than relying on Caddy's implicit directive order.
      "yt.theshire.io".extraConfig               = ''
        @invidious path ${invidiousPaths}
        @invidious_preflight {
          path ${invidiousPaths}
          method OPTIONS
        }

        handle @invidious_preflight {
          respond 204
        }

        handle @invidious {
          reverse_proxy orthanc.home.theshire.io:3000 {
            flush_interval -1
          }
        }

        handle {
          root * ${pkgs.materialious}
          try_files {path} /index.html
          file_server
        }

        header @invidious {
          Access-Control-Allow-Credentials true
          Access-Control-Allow-Origin "${invidiousOrigin}"
          Access-Control-Allow-Methods "GET, POST, OPTIONS, HEAD, PATCH, PUT, DELETE"
          Access-Control-Allow-Headers "User-Agent, Authorization, Content-Type, Range"
          Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Content-Type, Date"
          defer
        }
        ${tlsConfig}
      '';

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
