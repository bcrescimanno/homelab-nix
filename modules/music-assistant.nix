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

{ config, pkgs, lib, ... }:

{
  services.music-assistant = {
    enable = true;
    providers = [ "airplay" "sendspin" "dlna" ];
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
