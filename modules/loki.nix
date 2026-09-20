# modules/loki.nix — Grafana Loki log store, on orthanc.
#
# The other half of this is modules/alloy.nix, which ships logs here. Grafana
# stays on mirkwood and queries this over the LAN.
#
# WHY ORTHANC, not rivendell as the original sketch had it: four hosts of
# journals plus Blocky's query log wants disk and page cache, and orthanc has
# 1.7TB free on NVMe and ~16GB of headroom against rivendell's 8GB shared with
# Home Assistant. The accepted cost is that orthanc is the one host that gets
# rebooted for a game or a build, so log history is thinnest exactly when
# orthanc is the thing that broke. Alloy's WAL would buffer that, but it is
# still gated behind --stability.level=experimental, so it is deliberately not
# used; see the comment in modules/alloy.nix.
#
# Measured volume before this was written (2026-09-20), so the retention below
# is sized against real numbers rather than a guess:
#
#   orthanc journal      ~57 MB/day   (podman-minecraft, invidious-companion,
#                                      tailscaled and dhcpcd are the talkers)
#   mirkwood journal     ~2  MB/day
#   Blocky query log     ~23-31 MB/day PER DNS HOST — twice all four journals
#
# ~125 MB/day raw, so 14 days is ~1.8GB raw and roughly 250-400MB once Loki
# compresses the chunks. Against 1.7TB free that is nothing; retention is set
# by how far back a question is worth asking, not by disk.
#
# NOT BACKED UP, on purpose. This is a rolling 14-day window of a thing that
# already exists on each host's own disk. Adding it to restic would churn the
# repo for data that expires anyway.
#
# Single-binary mode: every Loki component runs in one process with an
# in-memory ring and replication_factor 1. Loki's microservice split exists for
# horizontal scale that a four-host lab will never need.

{ config, pkgs, lib, ... }:

let
  lokiPort = 3100;
  dataDir  = "/var/lib/loki";
in
{
  services.loki = {
    enable = true;
    inherit dataDir;

    # NOTE: this whole attrset is validated at BUILD time — the nixpkgs module
    # runs `loki -verify-config` over the generated JSON and the derivation
    # fails if it does not parse. A broken config here fails `nix flake check`
    # rather than the deploy, which is the opposite of the usual situation in
    # this repo and worth knowing.
    configuration = {
      # No multi-tenancy. With auth_enabled = false every write and read uses
      # the tenant id "fake"; Alloy therefore sends no X-Scope-OrgID header and
      # Grafana's datasource needs no tenant set.
      auth_enabled = false;

      server = {
        # 0.0.0.0, not 127.0.0.1: the three remote Alloys push here and Grafana
        # on mirkwood queries here. The firewall below is what bounds it.
        http_listen_address = "0.0.0.0";
        http_listen_port    = lokiPort;
        # gRPC is only used by Loki talking to itself in single-binary mode,
        # so it stays on loopback and no firewall port is opened for it.
        grpc_listen_address = "127.0.0.1";
        grpc_listen_port    = 9096;
        # Loki at info logs a line per flushed chunk, which would make this
        # service the noisiest thing in the journal it is collecting.
        log_level = "warn";
      };

      common = {
        instance_addr      = "127.0.0.1";
        path_prefix        = dataDir;
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
        storage.filesystem = {
          chunks_directory = "${dataDir}/chunks";
          rules_directory  = "${dataDir}/rules";
        };
      };

      # TSDB + schema v13 is the current pairing for Loki 3.x. v13 is also what
      # makes structured metadata legal, which is the escape hatch for anything
      # high-cardinality we later want attached to a line without it becoming a
      # stream label (Blocky's client IP is the obvious candidate).
      #
      # `from` is the date this schema starts applying and must not move
      # backwards once data exists under it. Set to the day before rollout;
      # adding a future schema later means appending a second entry here, never
      # editing this one.
      schema_config.configs = [{
        from         = "2026-09-20";
        store        = "tsdb";
        object_store = "filesystem";
        schema       = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }];

      storage_config.tsdb_shipper = {
        active_index_directory = "${dataDir}/tsdb-index";
        cache_location         = "${dataDir}/tsdb-cache";
      };

      # Retention is NOT a property of limits_config alone. Loki will happily
      # accept `retention_period` and then never delete anything unless the
      # compactor is also running with retention_enabled — the config reads as
      # "14 days" while the disk grows forever. delete_request_store is
      # additionally mandatory in 3.x once retention is on, and Loki refuses to
      # start without it, which is the one part of this that fails loudly.
      compactor = {
        working_directory             = "${dataDir}/compactor";
        compaction_interval           = "10m";
        retention_enabled             = true;
        retention_delete_delay        = "2h";
        retention_delete_worker_count = 150;
        delete_request_store          = "filesystem";
      };

      limits_config = {
        retention_period = "336h";   # 14 days

        # Guards against a misconfigured shipper replaying months of history
        # into the store. Blocky keeps 30 days of query log on disk, so a file
        # source pointed at the whole directory would otherwise backfill ~805MB
        # of expired lines on first start. alloy.nix sets tail_from_end for the
        # same reason; this is the server-side half of that belt.
        reject_old_samples         = true;
        reject_old_samples_max_age = "168h";  # 7 days

        # Lets Grafana's log-volume histogram work without scanning chunks.
        volume_enabled = true;

        allow_structured_metadata = true;
      };

      # Phones home to Grafana Labs by default.
      analytics.reporting_enabled = false;
    };
  };

  # Loki's own data. StateDirectory is not used by the nixpkgs module (it runs
  # as a static `loki` user with createHome), so the directory is created here
  # for the subdirectories the config above names.
  systemd.tmpfiles.rules = [
    "d ${dataDir}             0750 loki loki -"
    "d ${dataDir}/chunks      0750 loki loki -"
    "d ${dataDir}/rules       0750 loki loki -"
    "d ${dataDir}/tsdb-index  0750 loki loki -"
    "d ${dataDir}/tsdb-cache  0750 loki loki -"
    "d ${dataDir}/compactor   0750 loki loki -"
  ];

  # Open to the LAN for the three remote Alloys and for Grafana on mirkwood.
  #
  # Unlike Prometheus's 9090 on mirkwood — which is deliberately closed so that
  # nothing off-host can query it — Loki has no choice: its writers are on
  # other machines. Note that NixOS emits allowedTCPPorts with no -i match, so
  # this is reachable from the tailnet too, exactly like every other LAN-open
  # port in this lab. See modules/tailscale.nix.
  networking.firewall.allowedTCPPorts = [ lokiPort ];

  homelab.postUpgradeCheck.services = [ "loki" ];
}
