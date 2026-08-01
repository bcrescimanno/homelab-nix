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

  networking.firewall.allowedTCPPorts = [ 8095 8097 7000 8927 ];
  networking.firewall.allowedUDPPorts = [ 1900 ];

  # DLNA/UPnP discovery: MA sends M-SEARCH to the multicast group
  # (239.255.255.250:1900), but multicast UDP doesn't create conntrack entries.
  # WiiMs respond unicast back to MA's ephemeral source port, which the firewall
  # sees as NEW (not ESTABLISHED/RELATED) and drops. Trusting eth0 (the LAN
  # interface) lets those unicast SSDP responses — and subsequent UPnP HTTP
  # control traffic — reach MA unblocked.
  networking.firewall.trustedInterfaces = [ "eth0" ];
}
