# modules/tailscale.nix — tailnet membership for every host.
#
# Imported by base.nix, so all four hosts join. This is the replacement for the
# WireGuard server on the UDM Pro, not a second door beside it; see Plan.md
# "Remote access consolidation" for the decision and the break-glass window.
#
# ---------------------------------------------------------------------------
# What the tailnet can reach — and why nothing here opens a port
# ---------------------------------------------------------------------------
#
# Nothing in this file opens a port, and that is deliberate. NixOS emits its
# top-level allowedTCPPorts/allowedUDPPorts rules with NO `-i` match: they are
# the `default` entry of networking.firewall.allInterfaces, and
# firewall-iptables.nix only appends `-i <iface>` for entries whose name is not
# "default". So every port already open on the LAN is already open on
# tailscale0, and nothing else is.
#
# That is exactly the surface we want and it stays correct on its own. Prometheus
# on mirkwood is deliberately absent from allowedTCPPorts (modules/grafana.nix),
# so 9090 is refused on the tailnet for the same reason it is refused on the LAN
# — without anyone having to remember a second list.
#
# DO NOT add tailscale0 to networking.firewall.trustedInterfaces. It is the
# obvious-looking way to do this and it is wrong: trustedInterfaces accepts
# EVERYTHING arriving on the interface, which would publish 9090 — and every
# other deliberately-closed port — to every device on the tailnet.
#
# pirateship's arr apps need no rule either: podman publishes their ports with
# `-p`, which DNATs in PREROUTING and then traverses FORWARD rather than INPUT,
# and networking.firewall.filterForward only does anything under nftables (this
# fleet is on iptables). They are reachable over the tailnet exactly as they are
# over the LAN.
#
# ---------------------------------------------------------------------------
# extraUpFlags vs extraSetFlags — getting this backwards fails silently
# ---------------------------------------------------------------------------
#
# tailscaled-autoconnect.service only runs `tailscale up` when BackendState is
# NeedsLogin/NeedsMachineAuth/Stopped, i.e. essentially once, at first
# authentication. So extraUpFlags is the *enrolment* channel: change a flag
# there on an already-authenticated node and nothing happens, ever, with no
# error.
#
# tailscaled-set.service runs `tailscale set <flags>` unconditionally on every
# boot and every activation. That is the *reconciliation* channel, and it is
# where anything we might want to change later belongs — routes, exit node,
# DNS acceptance.
#
# ---------------------------------------------------------------------------
# --accept-dns=false is load-bearing on the servers
# ---------------------------------------------------------------------------
#
# Client devices (phones, laptops) SHOULD accept tailnet DNS: that is what makes
# Blocky's ad blocking and split-horizon *.theshire.io follow them off the LAN.
# The homelab hosts must NOT. Accepting it rewrites the host's resolv.conf to
# point at 100.100.100.100, which makes all host name resolution — including the
# nightly `nixos-rebuild --flake github:...` — depend on tailscaled being up. On
# rivendell and mirkwood it also routes the DNS servers' own lookups back through
# themselves. The flag is set on both `up` and `set` so there is no window at
# first enrolment where resolv.conf is taken over.
#
# --accept-routes is left at its Linux default of false for the same class of
# reason: these hosts are already ON 10.0.1.0/24 and must not learn it a second
# time through the tunnel.

{ config, ... }:

let
  # The main LAN. Deliberately NOT the IoT VLAN (10.0.12.0/22): rivendell's
  # eth0.4 exists so Home Assistant can broadcast WoL onto that segment without
  # rivendell being a member of it, and advertising it here would hand the whole
  # IoT network to every tailnet device.
  lanCidr = "10.0.1.0/24";

  # Tailnet topology, in one place on purpose.
  #
  # rivendell + mirkwood both advertise the LAN. Tailscale picks one and fails
  # over to the other, which mirrors the redundancy the two of them already
  # provide for DNS — the failure that takes out the subnet router should be the
  # same failure that takes out a resolver, not a second, independent one.
  #
  # orthanc advertises an exit node. It is always on, it is the only host with
  # real upstream headroom, and an advertised exit node costs nothing until a
  # client explicitly selects one. It still has to be approved in the admin
  # console before it can be used.
  #
  # pirateship is a plain client and must stay one. "client"/"both" would set
  # networking.firewall.checkReversePath = "loose", and loosening reverse-path
  # filtering on the host running gluetun's kill switch trades a real safety
  # property for a feature nothing needs. It must never be an exit node either:
  # its egress belongs to ProtonVPN, and routing other devices through it would
  # either leak past the tunnel or silently ride it.
  roles = {
    rivendell  = { routing = "server"; setFlags = [ "--advertise-routes=${lanCidr}" ]; };
    mirkwood   = { routing = "server"; setFlags = [ "--advertise-routes=${lanCidr}" ]; };
    orthanc    = { routing = "server"; setFlags = [ "--advertise-exit-node" ]; };
    pirateship = { routing = "none";   setFlags = [ ]; };
  };

  role = roles.${config.networking.hostName} or { routing = "none"; setFlags = [ ]; };
in
{
  # The tailnet auth credential. This must be an OAuth CLIENT SECRET
  # (tskey-client-…) with the auth_keys scope and tag:homelab, not a plain auth
  # key: plain keys expire after 90 days at the outside, and a re-auth you have
  # to remember is exactly the kind of drift this repo exists to avoid. The
  # module appends the authKeyParameters below to it as a query string, which is
  # the OAuth-key calling convention.
  sops.secrets.tailscale_auth_key = {};

  services.tailscale = {
    enable = true;

    authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    authKeyParameters = {
      # Join already approved — device approval is not on, and a host that
      # enrols into a "pending" state looks identical to one that failed.
      preauthorized = true;
      # These are permanent members of the tailnet, not CI runners. An ephemeral
      # node is garbage-collected when it goes offline, which would delete a Pi
      # from the tailnet every time it rebooted.
      ephemeral = false;
    };

    # UDP 41641. This is what lets peers find a DIRECT path instead of falling
    # back to a DERP relay: it is not required for connectivity, only for good
    # connectivity. Opening it is safe — an unsolicited packet to this port from
    # a non-peer fails the WireGuard handshake and is dropped.
    openFirewall = true;

    # Enrolment-time only. --advertise-tags is what puts these hosts under
    # tag:homelab, which is what disables key expiry on them: a tagged node is
    # owned by the tailnet rather than by a user, so it never needs re-auth.
    # There is no `tailscale set --advertise-tags`, so this cannot live below.
    extraUpFlags = [
      "--advertise-tags=tag:homelab"
      "--accept-dns=false"
    ];

    # Reconciled on every activation. See the header.
    extraSetFlags = [ "--accept-dns=false" ] ++ role.setFlags;

    useRoutingFeatures = role.routing;
  };

  # Roll the host back if the daemon does not come up after an unattended
  # upgrade. Deliberately tailscaled and not tailscaled-autoconnect: the daemon
  # being active is a real regression signal, whereas a failed autoconnect
  # usually means a credential problem that a rollback cannot fix and would only
  # revert an otherwise-good upgrade to chase.
  homelab.postUpgradeCheck.services = [ "tailscaled" ];
}
