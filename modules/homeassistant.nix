# modules/homeassistant.nix — Home Assistant + Matter Server + OTBR
#
# Home Assistant: home automation platform (port 8123) — native
# Matter Server: bridges Matter-protocol IoT devices into HA — CONTAINER
# OTBR (OpenThread Border Router): Thread border router via ZBT-2 — native
#
# Migration status (staged deliberately; see Plan.md):
#   Stage 1 (2026-08-01): otbr -> native. DONE and verified — same Thread
#     network (OpenThread-0b14), state "leader", REST API still on
#     localhost:8081, so HA's Thread integration needed no reconfiguration.
#     matter-server was attempted in the same pass and REVERTED to the
#     container; see the Matter Server comment block below before retrying.
#   Stage 2 (2026-08-01): home-assistant container -> services.home-assistant.
#     THIS CHANGE. See "Home Assistant" below.
#
# HA reaches Matter Server on localhost:5580 and OTBR's REST API on
# localhost:8081. Those config entries live in HA's .storage and are untouched
# by this migration, so neither integration needs reconfiguration.
#
# ZBT-2 (Nabu Casa, 303a:831a) presents as /dev/ttyACM0 in Thread RCP mode.
# If running Multi-PAN firmware (Zigbee + Thread concurrently), a cpcd
# service would be required between the USB device and OTBR.

{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Home Assistant (native — migrated off the container 2026-08-01)
  #
  # Why this was safe to do now: HA refuses to start against a .storage schema
  # written by a NEWER version, i.e. you cannot downgrade. The gate was
  # "nixpkgs >= running container", and at the time of writing both are exactly
  # 2026.7.4. The container image had been frozen in renovate.json so it could
  # not drift ahead of nixpkgs while this was staged; that rule is removed in
  # the same commit, since with the container gone there is no image left for it
  # to match.
  #
  # The gate does not disappear, it moves: HA now advances only when nixpkgs
  # advances, so a flake update that carries HA forward is a one-way door. There
  # is no downgrade path short of a restic restore of .storage.
  #
  # What is NOT managed here, on purpose:
  #   - .storage/       — every UI-created integration, device, area, user,
  #                       dashboard and helper. The module never touches it,
  #                       which is the entire reason a migration in place works.
  #   - automations.yaml, scripts.yaml, scenes.yaml — still written by the UI
  #                       editors, still `!include`d below. Nix-managed
  #                       automations ride the packages mechanism instead (see
  #                       modules/ha-window-notifications.nix), so the two
  #                       coexist without either clobbering the other.
  #   - home-assistant_v2.db — the recorder history, carried over as-is.
  #
  # What DID change: configuration.yaml is now a read-only symlink into the
  # store, rendered from `config` below. Stop hand-editing it on the host; the
  # module's preStart deletes and re-links it on every start. The pre-migration
  # copy is preserved by the ownership unit at the bottom of this file.
  # ---------------------------------------------------------------------------
  services.home-assistant = {
    enable = true;

    # Reuse the container's config dir rather than the module default
    # (/var/lib/hass). This is what makes the migration a cutover instead of a
    # data move: .storage, the recorder DB, custom_components/ and the UI YAML
    # files are all already here, and homelab.backup.paths already names this
    # path in hosts/rivendell.nix.
    configDir = "/var/lib/homeassistant/config";

    # This list is NOT optional and NOT cosmetic. The module only ships Python
    # dependencies for components it knows are used, and it can only infer that
    # from `config` below — which sees none of these, because they were all
    # added through the UI. A domain missing here loads with unmet imports and
    # fails at runtime, not at build.
    #
    # There are TWO sources, and using only the first is a mistake I already
    # made once (see the second block below).
    #
    # Source 1 — integrations that are actually configured. These have a config
    # entry in .storage:
    #   sudo jq -r '.data.entries[].domain' \
    #     /var/lib/homeassistant/config/.storage/core.config_entries | sort -u
    #
    # Re-run that after adding an integration through the UI. Several of these
    # are already pulled in by default_config; they are listed anyway so the
    # inventory is complete and greppable.
    #
    # Core components with no external requirements do NOT belong here and are
    # deliberately absent: template, notify, weather and sun all declare
    # `"requirements": []`, so there is nothing for extraComponents to install
    # and they load from the package regardless. (sun appears below only because
    # it genuinely has a config entry.)
    extraComponents = [
      "analytics"
      "apple_tv"
      "backup"
      "bluetooth"
      "default_config"
      "elgato"
      "go2rtc"
      "google_translate"
      "home_connect"
      "homekit"
      "matter"
      "met"
      "mobile_app"
      "ntfy"
      "nut"
      "otbr"
      "pi_hole"
      "radio_browser"
      "samsungtv"
      "shopping_list"
      "sonos"
      "sun"
      "thread"
      "wake_on_lan"
      "webostv"

      # Source 2 — integrations HA loads for DISCOVERY, which have no config
      # entry and are therefore invisible to the jq above.
      #
      # Missed on the first cut of this migration and caught only by reading the
      # journal after deploying: zeroconf/ssdp/dhcp discovery finds these
      # devices on the LAN, HA imports the integration to offer a "Discovered"
      # card, and the import dies:
      #   ERROR [homeassistant.components.<x>] Error occurred loading flow for
      #   integration <x>: No module named '<dep>'
      #
      # Nothing that already works breaks — none of these are set up — so this
      # fails quietly, in a way that would only surface as "the Add Integration
      # button does nothing" weeks later. The container had every dependency
      # present, so this is a regression against it and not a pre-existing gap.
      #
      # Regenerate this block the only way that works, from a running instance:
      #   sudo journalctl -u home-assistant -b -o cat \
      #     | grep -oE "loading flow for integration [a-z_]+" | sort -u
      "brother"           # printer, via mDNS
      "cast"              # Chromecast/Google speakers
      "ecobee"
      "homekit_controller" # HomeKit accessories — distinct from "homekit",
                           # which is HA *exposing* entities to Apple
      "ipp"               # printer, IPP everywhere
      "linkplay"          # WiiM's underlying protocol
      "litterrobot"
      "music_assistant"   # the MA server on this host advertises itself
      "roborock"
      "twinkly"
      "wiim"
    ];

    # HACS. It is a custom component, not a nixpkgs one — it lives in
    # configDir/custom_components/hacs and stays there, imperatively installed.
    #
    # The module's preStart only deletes symlinks under custom_components/ that
    # point into /nix/store, so a real directory survives it untouched.
    #
    # But: nixpkgs builds home-assistant with `skipPip ? true`, which bakes
    # --skip-pip into the hass wrapper. HACS satisfies its own requirement
    # (aiogithubapi) by pip-installing into configDir/deps at runtime, and that
    # is exactly what --skip-pip suppresses — so the dependency has to come from
    # nixpkgs instead. Read it back out of the manifest if HACS is ever updated:
    #   jq -r '.requirements[]' custom_components/hacs/manifest.json
    #
    # HACS currently has ZERO repositories installed through it — custom_components/
    # contains nothing but hacs itself — so nothing else needs deps here.
    extraPackages = ps: [ ps.aiogithubapi ];

    # Translation of the container-era configuration.yaml. Two things were
    # dropped rather than carried over, both verified dead on the live host:
    #   - `frontend.themes: !include_dir_merge_named themes` — the themes/
    #     directory does not exist.
    #   - secrets.yaml (one key, `some_password`) — referenced by nothing.
    config = {
      # Pulls in the standard integration set (including dhcp, ssdp, zeroconf,
      # bluetooth discovery). Do not remove.
      default_config = { };

      api = { };
      wake_on_lan = { };

      # UI-authored automations/scripts/scenes. These files stay writable and
      # stay owned by HA's own editors — Nix does not render them. Nix-managed
      # automations arrive via homeassistant.packages instead, which merges
      # additively with these includes.
      automation = "!include automations.yaml";
      script = "!include scripts.yaml";
      scene = "!include scenes.yaml";

      http = {
        use_x_forwarded_for = true;
        # Caddy is on this same host and connects over loopback (see
        # modules/caddy.nix — rivendell-local backends deliberately use
        # 127.0.0.1 and not localhost, because trusted_proxies here is IPv4 and
        # localhost resolves to ::1).
        #
        # The container-era list also trusted 172.18.0.0/24 and 10.88.0.0/16.
        # Those were podman bridge subnets, and trusting an entire container
        # bridge as a reverse proxy is worth not carrying forward: nothing
        # proxies HA from a container, and matter-server uses host networking.
        trusted_proxies = [
          "127.0.0.1"
          "10.0.1.0/24"
        ];
      };
    };
  };

  # Matter Server — deliberately still a CONTAINER. See the comment block below
  # for why the native module could not be used.
  virtualisation.oci-containers.containers.matter-server = {
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
  #    NO per-cert exception handling, and its caller fetch_dcl_certificates
  #    catches only (ClientError, TimeoutError) — so a ValueError from ONE
  #    malformed certificate in the DCL list escapes and aborts start().
  #
  #    Root cause is the cryptography version, measured 2026-08-01:
  #      nixpkgs closure  49.0.0  — rejects the cert
  #      container        45.0.6  — tolerates it
  #    The newer Rust asn1 parser is the stricter one. There is no CLI flag to
  #    skip the fetch (--enable-test-net-dcl only ADDS the test net).
  #
  #    Upstream has not touched paa_certificates.py since 2024-08-16, so this
  #    will not resolve on its own. Re-check when either nixpkgs carries a
  #    python-matter-server that wraps that parse, or the CSA fixes the cert.
  #
  #    THE TRAP: the process stays alive and systemd reports "active (running)"
  #    while port 5580 is NEVER bound. `systemctl is-active` lies here — verify
  #    with `ss -tlnp | grep 5580`.
  #
  # The state layout is unchanged from the container era
  # (/var/lib/matter-server/data), so re-attempting means re-adding the
  # migration unit that PR #504 removed; recover it from git history rather
  # than rewriting it.
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
  #
  # The native HA module grants AF_BLUETOOTH to the service only when a
  # component in componentsUsingBluetooth is in use — "bluetooth" is in
  # extraComponents above, which is what satisfies that.
  hardware.bluetooth.enable = true;

  # Port 5580 (Matter Server WebSocket) is localhost-only — HA connects
  # to it internally and it does not need to be reachable from the network.
  # UDP 4001: Govee Local — devices send status updates to this port on the host.
  # OTBR REST API (8081) is localhost-only — HA connects via localhost, no LAN
  # exposure needed or possible.
  networking.firewall.allowedTCPPorts = [ 8123 ];
  networking.firewall.allowedUDPPorts = [ 4001 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/matter-server/data 0755 root root -"
  ];

  # ---------------------------------------------------------------------------
  # Container -> native ownership migration (2026-08-01)
  #
  # The container ran HA as root, so the whole 85M config tree is root-owned.
  # The native module runs it as hass:hass and does NOT fix pre-existing files:
  # users.users.hass sets createHome, which only applies to a directory that
  # does not already exist.
  #
  # Idempotent and self-disarming: the find matches nothing once the tree is
  # converted, so subsequent deploys walk it and do nothing. Left in place
  # rather than run by hand so that a restore from restic — which preserves the
  # original root ownership — does not silently produce an HA that cannot write
  # its own database.
  # ---------------------------------------------------------------------------
  systemd.services.home-assistant-config-ownership = {
    description = "Give the hass user ownership of the Home Assistant config directory";
    before = [ "home-assistant.service" ];
    requiredBy = [ "home-assistant.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      dir=/var/lib/homeassistant/config

      if [ ! -d "$dir" ]; then
        echo "$dir does not exist — nothing to migrate (fresh install)"
        exit 0
      fi

      # Preserve the container-era configuration.yaml exactly once. The module's
      # own preStart is about to `rm -f` it and drop a store symlink in its
      # place; its content lives in `services.home-assistant.config` now, but
      # keeping the original makes the translation auditable after the fact.
      if [ -f "$dir/configuration.yaml" ] && [ ! -L "$dir/configuration.yaml" ] \
         && [ ! -f "$dir/configuration.yaml.pre-nix" ]; then
        ${pkgs.coreutils}/bin/cp -a "$dir/configuration.yaml" "$dir/configuration.yaml.pre-nix"
        echo "saved pre-migration configuration.yaml to $dir/configuration.yaml.pre-nix"
      fi

      count=$(${pkgs.findutils}/bin/find "$dir" \( ! -user hass -o ! -group hass \) -printf . | ${pkgs.coreutils}/bin/wc -c)
      if [ "$count" -eq 0 ]; then
        exit 0
      fi

      echo "chowning $count path(s) under $dir to hass:hass"
      # -h is mandatory, not defensive. On every run after the first, this
      # directory contains symlinks into the store — configuration.yaml points
      # at /etc/home-assistant/configuration.yaml, and www/nixos-lovelace-modules
      # can too. find does not follow symlinks, so it reports the (root-owned)
      # link itself as needing a chown; a bare chown would then FOLLOW it and
      # try to chown a /nix/store path, which fails, and `set -e` would take
      # this unit — and therefore home-assistant.service — down with it.
      ${pkgs.findutils}/bin/find "$dir" \( ! -user hass -o ! -group hass \) \
        -exec ${pkgs.coreutils}/bin/chown -h hass:hass {} +
    '';
  };

  # The old podman-otbr `after = blocky.service` ordering is gone with the
  # container. It existed because an unqualified image name made podman do a
  # registry DNS lookup at container start, which raced blocky's restart during
  # nixos-rebuild switch and failed activation (cost a rivendell rollback on
  # 2026-06-24). otbr-agent pulls nothing at start, so the race cannot recur.

  # NB: podman-matter-server, not matter-server — it is still a container.
  #
  # home-assistant is a real check now, and a meaningful one: under the
  # container, deploy-rs could not see HA failing to boot because the container
  # started fine and HA died inside it. A native unit that fails to start is a
  # failed activation.
  homelab.postUpgradeCheck.services = [
    "home-assistant"
    "podman-matter-server"
    "otbr-agent"
  ];
}
