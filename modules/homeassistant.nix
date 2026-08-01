# modules/homeassistant.nix — Home Assistant + Matter Server + OTBR
#
# Home Assistant: home automation platform (port 8123) — still a CONTAINER
# Matter Server: bridges Matter-protocol IoT devices into HA — native
# OTBR (OpenThread Border Router): Thread border router via ZBT-2 — native
#
# Migration status (staged deliberately; see Plan.md):
#   Stage 1 (2026-08-01): otbr -> native. DONE and verified — same Thread
#     network (OpenThread-0b14), state "leader", REST API still on
#     localhost:8081, so HA's Thread integration needed no reconfiguration.
#     matter-server was attempted in the same pass and REVERTED to the
#     container; see the Matter Server comment block below before retrying.
#   Stage 2 (pending): home-assistant container -> services.home-assistant.
#     Gate is satisfied as of 2026-08-01 — nixpkgs-unstable carries 2026.7.4,
#     exactly the version running here. Re-verify before starting: the gate is
#     "nixpkgs >= running", and HA ships a new minor every month.
#
# The HA container keeps host networking (mDNS/Zeroconf discovery) and
# --privileged (USB dongles, Bluetooth for Matter commissioning, multicast).
# HA reaches Matter Server on localhost:5580 and OTBR's REST API on
# localhost:8081; both native services bind loopback, so nothing is exposed.
#
# ZBT-2 (Nabu Casa, 303a:831a) presents as /dev/ttyACM0 in Thread RCP mode.
# If running Multi-PAN firmware (Zigbee + Thread concurrently), a cpcd
# service would be required between the USB device and OTBR.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers = {

    homeassistant = {
      image = "ghcr.io/home-assistant/home-assistant:stable@sha256:5a531753cea96444200158fc2b0ac7ccd739291ec50414877b396de6e0bb29b3";
      autoStart = true;
      volumes = [
        "/var/lib/homeassistant/config:/config"
        "/run/dbus:/run/dbus:ro"
      ];
      environment = {
        TZ = "America/Los_Angeles";
      };
      extraOptions = [
        "--network=host"
        "--privileged"
      ];
    };

    # Matter Server — deliberately still a CONTAINER. See the "Matter Server"
    # comment block below for why the native module could not be used.
    matter-server = {
      image = "ghcr.io/home-assistant-libs/python-matter-server:stable@sha256:170aa093ce91c76cde4cc390918307590f0f5558fcec93f913af3cb019e6562a";
      autoStart = true;
      # --primary-interface eth0: bind mDNS/multicast to the Ethernet interface
      # so Matter Server can discover WiFi devices on the local network.
      # Without this it defaults to 'None' and mDNS discovery fails.
      #
      # NOTE the absence of --vendorid: that is load-bearing. It means the
      # fabric uses python-matter-server's 0xFFF1 default, which is what
      # chip.json on disk records (caList = [{fabricId: 1, vendorId: 65521}]).
      cmd = [ "--storage-path" "/data" "--primary-interface" "eth0" ];
      volumes = [
        "/var/lib/matter-server/data:/data"
        # DBus access is required for Bluetooth (Matter commissioning).
        "/run/dbus:/run/dbus:ro"
      ];
      extraOptions = [
        "--network=host"
        "--privileged"
      ];
    };

  };

  # ---------------------------------------------------------------------------
  # Matter Server — why this is STILL A CONTAINER
  #
  # services.matter-server was tried on 2026-08-01 and reverted the same day.
  # Do not re-enable it without first re-testing the blocker below.
  #
  # Two separate problems surfaced, in order:
  #
  # 1. FIXED, and the fix is preserved in the container `cmd` above.
  #    The module hardcodes vendorid=4939 (Home Assistant's real vendor ID).
  #    This fabric was built by the container, which passes no --vendorid, so
  #    it uses python-matter-server's 0xFFF1 default. stack.py reuses a stored
  #    FabricAdmin only when BOTH vendorId and fabricId match, else calls
  #    NewFabricAdmin(), which collides on fabricId alone:
  #      ValueError: Provided fabricId of 1 collides with an existing
  #      FabricAdmin instance!
  #    Overridable via extraArgs.vendorid = 65521.
  #
  # 2. NOT FIXABLE from this side, and the actual reason for the revert.
  #    With vendorid corrected the service starts, loads the fabric, then dies
  #    inside server.start() fetching PAA root certificates from the DCL:
  #      ValueError: error parsing asn1 value: ParseError { kind: ExtraData,
  #      location: ["Certificate::tbs_cert", "TbsCertificate::signature_alg"] }
  #    paa_certificates.py calls x509.load_pem_x509_certificate() per cert with
  #    NO per-cert exception handling, so ONE malformed certificate in the DCL
  #    list aborts the whole fetch, which aborts start(). The process stays
  #    "active (running)" but never binds 5580 — systemd reports it healthy
  #    while it is not, so a naive `systemctl is-active` check will lie.
  #    There is no CLI flag to skip the fetch (--enable-test-net-dcl only adds
  #    the test net). The container's older cryptography tolerates the cert.
  #
  # Re-attempt when nixpkgs carries a python-matter-server that wraps that
  # parse in try/except, or when the CSA fixes the offending DCL cert. The
  # state layout is unchanged from the container era (/var/lib/matter-server/data),
  # so re-attempting means re-adding the migration unit that this commit removed;
  # recover it from git history rather than rewriting it.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # OpenThread Border Router (native — migrated off the container 2026-08-01)
  #
  # ZBT-2 USB dongle (/dev/ttyACM0) is the Thread radio in RCP mode.
  # HA's Thread integration reaches the REST API at http://localhost:8081,
  # which is this module's default (rest.listenAddress 127.0.0.1, port 8081) —
  # so the integration needs no reconfiguration.
  #
  # The NAT64=0 / DOCKER=0 workaround the container needed is GONE and must not
  # be reintroduced. That existed because the openthread/otbr image shells out
  # to iptables-legacy, which fails on NixOS ("Table does not exist") since the
  # ip_tables kernel modules are never loaded. The native module instead runs
  # otbr-firewall with config.networking.firewall.package — the host's own
  # iptables — as ExecStartPre/ExecStopPost, so the rules land in the same
  # backend the host firewall already uses. Verified on rivendell 2026-08-01:
  # nftables.service inactive and `lsmod | grep -c ip_tables` = 0, i.e. the
  # default iptables-nft backend, which is exactly what the module targets.
  #
  # The module also sets net.ipv{4,6}.conf.all.forwarding=1 and accept_ra=2 on
  # each backbone interface. That is required for the Thread mesh to be routable
  # and is deliberate.
  # ---------------------------------------------------------------------------
  services.openthread-border-router = {
    enable = true;
    backboneInterfaces = [ "eth0" ];
    # Set the URL directly rather than radio.device + baudRate: the generated
    # form is identical, and this keeps the string byte-for-byte what the
    # container passed to --radio-url.
    radio.url = "spinel+hdlc+uart:///dev/ttyACM0?uart-baudrate=460800";
    # Defaults, restated because HA's Thread integration is pinned to them.
    rest.listenAddress = "127.0.0.1";
    rest.listenPort = 8081;
  };

  # Enable Bluetooth userspace daemon (bluetoothd) so HA and Matter Server
  # can access the Pi 5's built-in Bluetooth adapter via DBus.
  hardware.bluetooth.enable = true;

  # Port 5580 (Matter Server WebSocket) is localhost-only — HA connects
  # to it internally and it does not need to be reachable from the network.
  # UDP 4001: Govee Local — devices send status updates to this port on the host.
  # OTBR REST API (8081) is localhost-only — HA connects via localhost, no LAN
  # exposure needed or possible (bound to 127.0.0.1 by the container).
  networking.firewall.allowedTCPPorts = [ 8123 ];
  networking.firewall.allowedUDPPorts = [ 4001 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant/config 0755 root root -"
    "d /var/lib/matter-server/data 0755 root root -"
  ];

  # ---------------------------------------------------------------------------
  # Container -> native state migrations (2026-08-01)
  #
  # These are one-shot and idempotent: each is a no-op once the old layout is
  # gone, so they cost nothing on subsequent deploys and are safe to leave in
  # place. Deleting them later is fine; they only matter for hosts still
  # carrying the container-era directory layout.
  #
  # Getting these wrong is expensive in a way a rollback does NOT undo: losing
  # the Matter fabric means re-commissioning every Matter device by hand, and
  # losing the Thread dataset means re-forming the mesh. Both move data rather
  # than copying, but only ever into an empty destination, and both bail out
  # untouched if anything looks unexpected.
  # ---------------------------------------------------------------------------

  # Container: host /var/lib/otbr/data -> container /var/lib/thread
  # Native:    StateDirectory=thread -> /var/lib/thread (otbr-agent runs as root,
  #            no DynamicUser, so this is a real directory, not a symlink).
  #
  # Holds the Thread network dataset, named for the radio's extended address
  # (e.g. 0_d878f0fffe9ae872.data). Losing it drops the formed network.
  systemd.services.otbr-state-migration = {
    description = "Move Thread dataset from the container layout to the native one";
    before = [ "otbr-agent.service" ];
    requiredBy = [ "otbr-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      old=/var/lib/otbr/data
      new=/var/lib/thread

      if [ ! -d "$old" ]; then exit 0; fi
      shopt -s dotglob nullglob
      files=("$old"/*)
      if [ ''${#files[@]} -eq 0 ]; then rmdir "$old" 2>/dev/null || true; exit 0; fi

      if [ -d "$new" ] && [ -n "$(ls -A "$new" 2>/dev/null)" ]; then
        echo "refusing to migrate: $new already exists and is non-empty" >&2
        exit 1
      fi

      mkdir -p "$new"
      chmod 0700 "$new"
      mv "''${files[@]}" "$new"/
      shopt -u dotglob nullglob
      rmdir "$old"
      rmdir /var/lib/otbr 2>/dev/null || true
      echo "migrated Thread dataset to $new"
    '';
  };

  # The old podman-otbr `after = blocky.service` ordering is gone with the
  # container. It existed because an unqualified image name made podman do a
  # registry DNS lookup at container start, which raced blocky's restart during
  # nixos-rebuild switch and failed activation (cost a rivendell rollback on
  # 2026-06-24). otbr-agent pulls nothing at start, so the race cannot recur.

  # NB: podman-matter-server, not matter-server — it is still a container.
  homelab.postUpgradeCheck.services = [
    "podman-homeassistant"
    "podman-matter-server"
    "otbr-agent"
  ];
}
