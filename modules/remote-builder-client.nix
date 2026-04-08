# modules/remote-builder-client.nix — use orthanc as a remote Nix builder
#
# Included in all Pi (aarch64-linux) hosts via piModules in flake.nix.
# Offloads builds to orthanc (Ryzen 9 5950X, x86_64) which handles:
#   - x86_64-linux builds natively
#   - aarch64-linux builds via QEMU binfmt emulation (configured on orthanc)
#
# This eliminates multi-hour kernel compiles on the Pis — the 5950X builds
# the same kernel in ~10 minutes and the Pi downloads the result.
#
# Required sops secret (add to each Pi's secrets/<host>.yaml):
#   nix_remote_builder_key — SSH private key for the nix-remote-builder user
#
# The PUBLIC half of this key goes in hosts/orthanc.nix under
# users.users.nix-remote-builder.openssh.authorizedKeys.keys.
# All three Pis share the same key pair.
#
# Setup steps (see hosts/orthanc.nix for full instructions):
#   1. ssh-keygen -t ed25519 -f /tmp/nix-remote-builder -C nix-remote-builder
#   2. Add public key to hosts/orthanc.nix
#   3. Add private key to secrets/{pirateship,rivendell,mirkwood}.yaml
#   4. Deploy orthanc first, then redeploy Pi hosts

{ config, pkgs, ... }:

{
  # nix-daemon runs in a restricted systemd PATH and cannot find ssh on its own.
  # Without this, remote builder connections fail with "Could not find executable 'ssh'".
  systemd.services.nix-daemon.path = [ pkgs.openssh ];

  # homelab-upgrade.service also needs openssh: in Nix 2.28+, the nix build
  # client process (running inside that service) makes the SSH connection to
  # the remote builder directly, not the daemon. Without this, auto-upgrades
  # fail with "Could not find executable 'ssh'" whenever new derivations need
  # to be built (cache misses after container image digest bumps, etc.).
  systemd.services.homelab-upgrade.path = [ pkgs.openssh ];

  programs.ssh.knownHosts.orthanc = {
    hostNames = [ "orthanc" "orthanc.home.theshire.io" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHkrkkYch/Q5K4XUn58yLX4lfg9s7qqZu9s/Y71uxaAA";
  };

  nix.distributedBuilds = true;

  # Never build locally on the Pi — always use orthanc or a substituter.
  # Prevents large builds (kernels, etc.) from running on the Pi CPUs.
  nix.settings.max-jobs = 0;

  nix.buildMachines = [{
    hostName = "orthanc.home.theshire.io";
    # orthanc builds x86_64 natively and aarch64 via binfmt emulation.
    systems = [ "x86_64-linux" "aarch64-linux" ];
    sshUser = "nix-remote-builder";
    sshKey = config.sops.secrets.nix_remote_builder_key.path;
    # 8 parallel jobs — leaves 8 cores free on the 5950X for other workloads.
    maxJobs = 8;
    # High speed factor so Nix prefers orthanc over local Pi builds.
    speedFactor = 10;
    supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    mandatoryFeatures = [];
  }];

  sops.secrets.nix_remote_builder_key = {
    # Uses each host's defaultSopsFile. The same private key value must be
    # added to secrets/pirateship.yaml, secrets/rivendell.yaml, and
    # secrets/mirkwood.yaml.
  };
}
