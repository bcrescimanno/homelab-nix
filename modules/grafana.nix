# modules/grafana.nix — Prometheus + Grafana for DNS observability
#
# Prometheus scrapes Blocky metrics from mirkwood (local) and rivendell.
# Grafana provides dashboards; native OIDC support pre-wired for Authelia.
#
# Ports: Grafana 3001 (3000 is Homepage), Prometheus 9090 (internal only).
#
# Required sops secret (secrets/mirkwood.yaml):
#   grafana_env — env file containing:
#                   GF_SECURITY_ADMIN_PASSWORD=<password>

{ config, pkgs, lib, ... }:

{
  services.prometheus = {
    enable        = true;
    port          = 9090;
    retentionTime = "7d";
    scrapeConfigs = [{
      job_name       = "blocky";
      static_configs = [{
        targets = [
          "127.0.0.1:4000"        # mirkwood Blocky (local)
          "rivendell.local:4000"  # rivendell Blocky
        ];
      }];
    }];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3001;
        domain    = "grafana.theshire.io";
        root_url  = "https://grafana.theshire.io";
      };
      security = {
        admin_user     = "admin";
        admin_password = "$__env{GF_SECURITY_ADMIN_PASSWORD}";
      };
    };

    provision = {
      enable = true;
      datasources.settings.datasources = [{
        name      = "Prometheus";
        type      = "prometheus";
        url       = "http://127.0.0.1:9090";
        isDefault = true;
      }];
    };
  };

  sops.secrets.grafana_env = {
    owner = "grafana";
  };

  systemd.services.grafana.serviceConfig.EnvironmentFile =
    config.sops.secrets.grafana_env.path;

  # Grafana on 3001 — Caddy on rivendell proxies it via mirkwood.local:3001
  # Port must be open so rivendell can reach it; not directly exposed externally
  networking.firewall.allowedTCPPorts = [ 3001 ];
  # Prometheus internal only — no firewall port opened
}
