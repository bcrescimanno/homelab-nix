# modules/piped.nix — Piped: privacy-respecting YouTube frontend
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
      image = "docker.io/postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50";
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
      image = "1337kavin/piped:latest@sha256:b0462b15a951061878d13abf3e3706b60a33c1941cb28bb48f86227d0fbeb730";
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
      image = "1337kavin/piped-frontend:latest@sha256:7ccda9646bfde6dd19f7e63f2f1c791b801aa9b8f23e9da33bb9e51d3c7c5d47";
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
      image = "1337kavin/piped-proxy:latest@sha256:4fee95666857c737374ae73a9151028c16e55ba8452fccc337e8ec642b06b5a8";
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
