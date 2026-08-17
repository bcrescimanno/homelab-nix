# modules/piped.nix — Piped: privacy-respecting YouTube frontend
#
# -----------------------------------------------------------------------------
# STATUS 2026-08-01: PLAYBACK IS BROKEN. Diagnosed, not yet fixed.
#
# The symptom reported as "the feed seems broken" is not the feed. Measured on
# orthanc:
#   - The feed pipeline is HEALTHY. 49 channels, 49 rows in `pubsub`, videos
#     landing through today. The recurring "PubSub: queue size - 0 channels"
#     log line means the queue is momentarily empty, NOT that nothing is
#     subscribed — it is a red herring.
#   - PLAYBACK is dead. /streams/<id> returns videoStreams=1, audioStreams=0,
#     hls=false, dash=false on every video sampled; one returned outright
#     "Could not get any stream". Piped needs separate adaptive audio, so zero
#     audio streams means nothing can play. This is the standard signature of
#     YouTube's PoToken/SABR enforcement defeating NewPipeExtractor.
#
# Why this will not fix itself: the running backend image was built
# 2026-03-26, and TeamPiped/Piped-Backend's last commit upstream is 2026-05-29
# with nothing addressing extraction. Renovate is digest-pinned to :latest and
# has nothing newer to pull. The project is effectively dormant against a
# problem that requires active maintenance.
#
# Path forward is a DECISION, not a patch — do not just bump the image:
#   a) Replace with Invidious. nixpkgs has services.invidious (fully native,
#      which also kills the piped-postgres container below), and iv-org is
#      actively maintained — commits through 2026-08-01 including a
#      "Hotfix - Fix YouTube change" on 2026-07-23. Invidious fights the same
#      YouTube battle but is actually still fighting it.
#   b) Retire the self-hosted YouTube frontend entirely.
#   c) Stay on Piped and accept it as a subscription-feed reader whose links
#      open elsewhere, since the feed half genuinely still works.
#
# NOTE the postgres 16-alpine container below is a principle violation on its
# own (a database with a first-class NixOS module). Option (a) removes it for
# free and retires the pinned-major upgrade task; do not migrate it separately
# before this decision is made.
# -----------------------------------------------------------------------------
#
# Four containers: postgres (DB), backend (API), frontend (nginx UI), proxy.
# Video streams are served in redirect mode — the browser fetches video directly
# from YouTube's CDN rather than proxying through the local instance. This avoids
# the reliability and speed issues of full proxying (à la Invidious).
#
# After first login, disable "Proxy Video" in Piped's settings for the best
# playback experience (it may be on by default).
#
# Port layout (all on orthanc):
#   8180 — piped-backend (API; postgres via internal piped network)
#   8181 — piped-frontend (nginx)
#   8182 — piped-proxy (Go stream/image proxy)
#   postgres is internal only, not exposed to the host
#
# Caddy vhosts on rivendell (see modules/caddy.nix):
#   piped.theshire.io       → orthanc:8181
#   piped-api.theshire.io   → orthanc:8180
#   piped-proxy.theshire.io → orthanc:8182

{ config, pkgs, lib, ... }:

let
  # Generated into /nix/store — no secrets here.
  # Postgres credentials are local-only (postgres port not exposed to host).
  backendConfig = pkgs.writeText "piped-config.properties" ''
    PORT=8080
    HTTP_WORKERS=2
    PROXY_PART=https://piped-proxy.theshire.io
    FRONTEND_URL=https://piped.theshire.io
    # Required for PubSubHubbub: backend constructs its callback URL from this.
    # Without it, subscriptions sent to YouTube's hub use localhost and are rejected.
    PUBSUB_URL=https://piped-api.theshire.io
    COMPROMISED_PASSWORD_CHECK=false
    DISABLE_REGISTRATION=false
    hibernate.connection.url=jdbc:postgresql://piped-postgres:5432/piped
    hibernate.connection.driver_class=org.postgresql.Driver
    hibernate.connection.username=piped
    hibernate.connection.password=piped
    hibernate.dialect=org.hibernate.dialect.PostgreSQLDialect
    hibernate.hbm2ddl.auto=update
  '';

in

{
  # Create a user-defined Podman network so all piped containers can resolve
  # each other by name (piped-backend → piped-postgres). Must exist before any
  # container in the group starts.
  systemd.services.podman-create-piped-network = {
    description = "Create Podman network for Piped containers";
    before = [
      "podman-piped-postgres.service"
      "podman-piped-backend.service"
      "podman-piped-frontend.service"
      "podman-piped-proxy.service"
    ];
    wantedBy = [
      "podman-piped-postgres.service"
      "podman-piped-backend.service"
      "podman-piped-frontend.service"
      "podman-piped-proxy.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Shell wrapping is required — ExecStart does NOT run through a shell,
      # so || and redirects must be inside a script.
      ExecStart = pkgs.writeShellScript "piped-network-create" ''
        ${pkgs.podman}/bin/podman network create piped 2>/dev/null || true
      '';
    };
  };

  # Ensure backend starts after postgres and keeps retrying without ever entering
  # "failed" state. startLimitBurst=0 disables the restart rate limit so systemd
  # never marks the service as failed — it just keeps restarting until postgres
  # is ready. Without this, the activation script sees a crash as exit code 4
  # and triggers a magic rollback.
  systemd.services.podman-piped-backend = {
    after = [ "podman-piped-postgres.service" ];
    startLimitBurst = 0;
    serviceConfig.RestartSec = "5s";
  };

  virtualisation.oci-containers.containers = {
    piped-postgres = {
      image = "docker.io/postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685";
      autoStart = true;
      environment = {
        POSTGRES_DB = "piped";
        POSTGRES_USER = "piped";
        POSTGRES_PASSWORD = "piped";
      };
      volumes = [
        "/var/lib/piped/postgres:/var/lib/postgresql/data"
      ];
      extraOptions = [ "--network=piped" ];
    };

    piped-backend = {
      image = "docker.io/1337kavin/piped:latest@sha256:7747e19ee501c0a3afa94dd3d6e982dd4247f1babe03fb515b4a0f0b87f82b2e";
      autoStart = true;
      volumes = [
        "${backendConfig}:/app/config.properties:ro"
      ];
      # Pin to 1 CPU core so availableProcessors()=1 → PubSub thread pool size=1.
      # Without this, orthanc's 32-thread pool fires all subscription requests
      # simultaneously, triggering YouTube's hub throttle (429) on every attempt.
      # Sequential requests at ~200ms each clear the throttle easily.
      extraOptions = [ "--network=piped" "--cpuset-cpus=0" ];
      ports = [ "8180:8080" ];
    };

    piped-frontend = {
      image = "docker.io/1337kavin/piped-frontend:latest@sha256:083d2a46cc1dfc3219916d254f7413dc1be23d9afa299346a167760eaa9a070a";
      autoStart = true;
      # The image entrypoint generates config.json from BACKEND_HOSTNAME at startup.
      environment = {
        BACKEND_HOSTNAME = "piped-api.theshire.io";
      };
      # The image's nginx config listens on port 80, but the nginx process runs as
      # uid 101 (nginx user), not root. NET_BIND_SERVICE grants it permission to
      # bind to ports < 1024 without requiring full root.
      extraOptions = [ "--cap-add=NET_BIND_SERVICE" "--network=piped" ];
      ports = [ "8181:80" ];
    };

    piped-proxy = {
      image = "docker.io/1337kavin/piped-proxy:latest@sha256:6ffcd6057cfaf516859e99bb018a5d0fc913ecdbbb5aa1b8543ed29d2bd8c4e5";
      autoStart = true;
      extraOptions = [ "--network=piped" ];
      ports = [ "8182:8080" ];
    };
  };

  networking.firewall.allowedTCPPorts = [ 8180 8181 8182 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/piped/postgres 0755 root root -"
  ];
}
