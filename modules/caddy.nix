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
  #   /videoplayback  what adaptiveFormats[].url points at
  #   /latest_version the non-DASH/progressive media endpoint
  #   /download     "download this video"
  #   /authorize_token /login   the Invidious OAuth-ish flow (src/lib/auth.ts:81)
  #
  # /videoplayback and /latest_version are NOT optional now that Invidious'
  # `domain` is this vhost: every URL in adaptiveFormats is absolute and points
  # here. Miss one of these and it falls through to the SPA fallback below,
  # which answers with index.html and HTTP 200 — a broken stream that looks
  # like a successful request.
  #
  # None of these collide with a Materialious client route — note it uses
  # /internal/login, not /login. Invidious owns far more top-level paths than
  # these (/watch, /channel, /search, /feed...), and those deliberately stay
  # with Materialious; it does not need Invidious' HTML pages at all.
  # /css /js /videojs are Invidious' OWN static assets. They matter because the
  # login and authorize_token pages are Invidious HTML served under this vhost;
  # without them those pages render unstyled (functional but bare). Materialious
  # keeps its own assets under /_app, so there is no clash.
  invidiousPaths =
    "/api/* /companion/* /vi/* /ggpht/* /sb/* /videoplayback /latest_version "
    + "/download /authorize_token /login /css/* /js/* /videojs/* /toggle_theme";
in

{
  services.caddy = {
    enable = true;

    # Plugin list and the FOD hash live in pkgs/caddy-cloudflare.nix, which is
    # also exposed as .#caddy-cloudflare so scripts/refresh-pins can recompute
    # the hash. Read that file before touching either — the hash tracks the Go
    # module graph, not the Caddy version.
    package = pkgs.callPackage ../pkgs/caddy-cloudflare.nix { };

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
      # Invidious — the stock UI, kept as the diagnostic control for the
      # Materialious frontend on yt.theshire.io below. Same service, same
      # database, so it costs nothing to keep and it is the only way to tell a
      # frontend bug from a companion/extraction failure.
      #
      # flush_interval -1 disables Caddy's response buffering so video chunks
      # are forwarded to the client immediately: video is streamed through this
      # vhost (invidious proxies its companion rather than exposing it), and the
      # default buffering makes Firefox's MSE time out before playback starts.
      # WebKit is more tolerant of it, which is why Safari/Orion appeared to
      # work while Firefox did not.
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
      # consumer. Without it the stock UI — kept as the diagnostic control that
      # separates a Materialious bug from a companion/extraction failure —
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
