# hosts/orthanc.nix — host-specific configuration for orthanc.
#
# orthanc is an x86_64 tower server (Ryzen 9 5950X, 32GB RAM, ASUS X570-E Gaming).
# Roles: Nix remote builder for the Pi fleet, Minecraft game server.
#
# Initial installation via nixos-anywhere (headless, no monitor needed):
#   # Prepare the age key directory to upload during install:
#   mkdir -p /tmp/orthanc-extra/var/lib/sops-nix
#   cp /tmp/orthanc-age-key.txt /tmp/orthanc-extra/var/lib/sops-nix/key.txt
#
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#orthanc \
#     --extra-files /tmp/orthanc-extra \
#     root@<ip>

{ config, pkgs, lib, inputs, ... }:

{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "orthanc";

  # ---------------------------------------------------------------------------
  # Boot & Disk
  # ---------------------------------------------------------------------------

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/nvme0n1"; # Samsung 970 EVO NVMe SSD
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "512M";
            type = "EF00"; # EFI system partition
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------

  networking.useDHCP = lib.mkDefault true;

  # ---------------------------------------------------------------------------
  # Nix remote builder — server side
  # ---------------------------------------------------------------------------
  #
  # The Pi fleet connects here as `nix-remote-builder` to offload builds.
  # orthanc handles both x86_64-linux builds natively and aarch64-linux builds
  # via QEMU user-mode emulation (binfmt).
  #
  # Setup steps (one-time, after first deploy):
  #   1. Generate a dedicated SSH key pair:
  #        ssh-keygen -t ed25519 -f /tmp/nix-remote-builder -C nix-remote-builder
  #   2. Paste the PUBLIC key into openssh.authorizedKeys.keys below and redeploy orthanc.
  #   3. Add the PRIVATE key to each Pi's sops secrets as `nix_remote_builder_key`:
  #        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
  #        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
  #        SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
  #   4. Redeploy all Pi hosts. Remote builds activate automatically.

  # x86_64 natively + aarch64 via QEMU binfmt emulation
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  users.users.nix-remote-builder = {
    isSystemUser = true;
    group = "nix-remote-builder";
    shell = pkgs.bash;
    # Paste the PUBLIC half of the generated key pair here after first boot.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyHPFyzAf2wHEmlE82PwR0rG9phC70lZk3ErsfXuF6H nix-remote-builder"
    ];
  };
  users.groups.nix-remote-builder = {};

  # nix-remote-builder must be trusted so the Pi's nix-daemon can copy store
  # paths to/from orthanc without needing root.
  nix.settings.trusted-users = [ "root" "@wheel" "nix-remote-builder" ];

  # ---------------------------------------------------------------------------
  # System state version
  # ---------------------------------------------------------------------------

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------

  sops = {
    defaultSopsFile = ../secrets/orthanc.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/orthanc.nix" ];
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------

  homelab.backup.paths = [
    "/var/lib/minecraft"
  ];
}
