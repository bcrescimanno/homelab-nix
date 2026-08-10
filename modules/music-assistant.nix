# modules/music-assistant.nix — Music Assistant multi-room audio server
#
# Self-hosted music server and multi-room playback controller.
# Replaces Navidrome; accesses the music library directly via NFS mount
# at /var/lib/media/music (declared in hosts/rivendell.nix).
#
# After deployment, open listen.theshire.io and add a "Filesystem" provider
# pointing to /var/lib/media/music. AirPlay and DLNA device discovery is
# automatic — devices appear in the Players list within a few minutes.
#
# NFS permission note: the NixOS module uses DynamicUser = true, so the
# music-assistant service runs as an ephemeral UID. The erebor NFS export
# must allow reads from arbitrary UIDs (e.g. world-readable file permissions,
# or all_squash + anonuid pointing to a known UID).
#
# Ports opened:
#   8095  — web UI/API (proxied via Caddy at listen.theshire.io)
#   8097  — audio streams server (internal, used by players)
#   7000  — AirPlay receiver (allows iOS/macOS to cast to MA)
#   8927  — Sendspin
#   1900  — SSDP/UPnP multicast discovery (UDP, required for DLNA)
#
# Firewall note: eth0 is added to trustedInterfaces so that DLNA/UPnP works.
# MA sends M-SEARCH to 239.255.255.250 (multicast), but multicast UDP doesn't
# create conntrack entries, so the unicast SSDP replies from players appear as
# NEW packets and get dropped. Trusting eth0 (the LAN interface) unblocks them.
# That blanket trust also covers the mDNS (UDP 5353) discovery the wiim and sonos
# providers rely on, so neither needs a port added.

{ config, pkgs, lib, ... }:

let
  # rivendell's LAN address. MA must advertise this and never eth0.4's
  # 10.0.12.2 (IoT VLAN) -- see the ExecStartPre block below.
  publishIp = "10.0.1.9";
  webPort   = 8095;
in
{
  services.music-assistant = {
    enable = true;
    # Adding a name here does not "enable" a provider -- it installs that
    # provider's Python dependencies. nixpkgs patches out MA's pip-install path
    # (dont-install-deps.patch) and replaces it with a hard error, so a provider
    # MA has enabled in its own settings.json but which is missing from this list
    # fails to import on every startup. That patch also drops MA's `==` version
    # check, which is why nixpkgs shipping wiim 0.1.5 against MA's pinned
    # wiim==0.1.4 is harmless.
    #
    # "sonos": MA enables this itself via default_providers_setup, and there are
    # two Sonos devices on the LAN (a Beam and one more, both visible as
    # uuid:RINCON_* DLNA renderers). Without it declared MA logged
    # "Failed to load provider module for sonos" plus a recursion traceback on
    # every single startup.
    #
    # "wiim": native LinkPlay support, discovered over mDNS (_linkplay._tcp).
    # Covers the WiiM Pro ("Stereo", 10.0.1.179) and WiiM Amp Pro ("Office
    # Music", 10.0.1.20), both of which previously only arrived as generic DLNA
    # renderers. "dlna" deliberately stays -- the TVs (Playroom TV, Television,
    # Samsung Frame 50) have no native provider and would disappear without it.
    providers = [ "airplay" "chromecast" "sendspin" "dlna" "sonos" "wiim" ];
  };

  # Pin the published stream address before MA reads its config.
  #
  # publish_ip (:8097) and base_url (:8095) default to ip_addresses[0] -- the
  # first enumerated interface address, evaluated live. rivendell is multi-homed
  # (eth0 = 10.0.1.9 LAN, eth0.4 = 10.0.12.2 IoT VLAN), and on the 2026-08-09
  # cold boot MA came up before eth0 finished DHCP, so the static VLAN address
  # sorted first. Every WiiM then hung silently in LinkPlay `status: "load"`
  # fetching a URL it cannot route to, while AirPlay -- which MA pushes to
  # rather than advertising a URL for -- kept working and masked the outage.
  #
  # Saving this through MA's own API does NOT pin it: Config.to_raw persists a
  # value only when it differs from the current default, so writing the correct
  # IP while the default already happens to be correct stores nothing. Config
  # .parse applies stored values unconditionally, so the file is the pin.
  #
  # Confirm after a reboot with:
  #   journalctl -u music-assistant | grep "Starting streamserver on"
  systemd.services.music-assistant.serviceConfig.ExecStartPre = [
    ("${pkgs.python3}/bin/python3 ${./ma-publish-ip.py} "
      + "/var/lib/music-assistant/settings.json "
      + "${publishIp} http://${publishIp}:${toString webPort}")
  ];

  networking.firewall.allowedTCPPorts = [ webPort 8097 7000 8927 ];
  networking.firewall.allowedUDPPorts = [ 1900 ];

  # DLNA/UPnP discovery: MA sends M-SEARCH to the multicast group
  # (239.255.255.250:1900), but multicast UDP doesn't create conntrack entries.
  # WiiMs respond unicast back to MA's ephemeral source port, which the firewall
  # sees as NEW (not ESTABLISHED/RELATED) and drops. Trusting eth0 (the LAN
  # interface) lets those unicast SSDP responses — and subsequent UPnP HTTP
  # control traffic — reach MA unblocked.
  networking.firewall.trustedInterfaces = [ "eth0" ];
}
