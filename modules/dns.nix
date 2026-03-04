# modules/dns.nix — Technitium DNS Server
#
# Technitium is a full-featured DNS server with a web UI. It replaces the
# previous Pi-hole + Unbound + Redis + Nebula-Sync stack.
#
# Deployment plan:
#   mirkwood: primary DNS (port 53)
#   rivendell: secondary DNS (port 53, syncs zone data from mirkwood)
#
# TODO: Implement container config once deployed.

{ config, pkgs, lib, ... }:

{
  # placeholder — no services configured yet
}
