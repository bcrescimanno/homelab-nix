# modules/remote-builder-client.nix — use orthanc as a remote Nix builder
#
# Included in all Pi (aarch64-linux) hosts via piModules in flake.nix.
# Offloads x86_64-linux builds to orthanc (Ryzen 9 5950X, builds natively).
#
# aarch64-linux builds (e.g. the Pi kernel) run locally on the Pi — native
# aarch64 at 2.4GHz is ~4x faster than orthanc's qemu emulation for heavy
# compiles like the kernel. max-jobs = 4 enables local aarch64 builds.
# Once one Pi builds the kernel and the post-build hook pushes it to attic,
# subsequent Pi deploys get an instant cache hit.
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

  # Allow up to 4 local aarch64 builds — used for the Pi kernel and any other
  # aarch64 packages that miss attic. orthanc handles x86_64 only (see below).
  nix.settings.max-jobs = 4;

  nix.buildMachines = [{
    hostName = "orthanc.home.theshire.io";
    # x86_64 only — aarch64 builds run natively on the Pi (faster than qemu).
    systems = [ "x86_64-linux" ];
    sshUser = "nix-remote-builder";
    sshKey = config.sops.secrets.nix_remote_builder_key.path;
    maxJobs = 8;
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
