# modules/base.nix — shared configuration for all Pi devices.
#

{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  # `users.mutableUsers = false` is an important NixOS concept. It means
  # that users and passwords can ONLY be set via this configuration — you
  # cannot use `adduser` or `passwd` on the running system and have it
  # persist. This enforces that your config file is the single source of
  # truth for who can log in.
  users.mutableUsers = false;

  programs.zsh.enable = true;

  users.users.brian = {
    shell = pkgs.zsh;
    isNormalUser = true;
    # `wheel` allows `sudo`. `podman` allows managing containers without sudo.
    extraGroups = [ "wheel" "podman" ];

    # Your public SSH key goes here. You will never need a password to log in.
    # Generate with `ssh-keygen -t ed25519` if you don't have one.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBEjcQUPpiMkeQJFlkrERftafbT/CpjaeRzbHUv/0P2W"
    ];
  };

  # Allow wheel group to use sudo without a password.
  # Remove `NOPASSWD` if you want to require the password on sudo.
  security.sudo.wheelNeedsPassword = false;

  # ---------------------------------------------------------------------------
  # SSH
  # ---------------------------------------------------------------------------

  services.openssh = {
    enable = true;
    settings = {
      # Never allow root login — always log in as your user and sudo if needed.
      PermitRootLogin = "no";
      # Disable password authentication entirely. SSH keys only.
      # This is safe because we've declared our key above.
      PasswordAuthentication = false;
    };
  };

  # ---------------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------------

  # NixOS enables a firewall by default. We explicitly allow only what we need.
  # Services declared elsewhere in your config (like openssh above) will
  # automatically open their ports — you don't need to list port 22 here.
  # Append .local to bare hostnames so `mirkwood` resolves as `mirkwood.local`.
  # This lets containers and services reference each other without the suffix.
  networking.search = [ "local" ];

  networking.firewall = {
    enable = true;
    # Open additional ports as needed. For example, if you want to access
    # the arr stack web UIs directly from your local network:
    # allowedTCPPorts = [ 8989 7878 9696 8080 ]; # sonarr radarr prowlarr qbit
  };

  # ---------------------------------------------------------------------------
  # Podman
  # ---------------------------------------------------------------------------

  # Enable Podman as the container runtime. NixOS's virtualisation module
  # handles installing Podman, configuring the socket, and setting up the
  # default OCI runtime (crun).
  virtualisation.podman = {
    enable = true;
    dockerSocket.enable = true;
    # Creates a `docker` symlink so any tools or scripts that call `docker`
    # will transparently use Podman instead. Handy for compatibility.
    dockerCompat = true;
    # Enables the Podman socket, which lets tools like podman-compose
    # and some GUIs communicate with Podman the same way they would Docker.
    # Disable Podman's built-in container DNS (aardvark-dns). None of our
    # containers need to resolve each other by name — they use IPs or ports
    # directly. Keeping this enabled occupies port 53 on the bridge interface
    # which conflicts with Technitium on hosts that run it.
    defaultNetwork.settings.dns_enabled = false;
  };

  virtualisation.oci-containers.backend = "podman";

  # ---------------------------------------------------------------------------
  # Automatic updates
  # ---------------------------------------------------------------------------

  # NixOS can automatically apply security updates. This fetches the latest
  # nixpkgs for your channel and rebuilds — but only if the build succeeds
  # and the system can be rolled back. It will NOT auto-reboot by default.
  system.autoUpgrade = {
    enable = true;
    # Point this at your flake in git so upgrades pull your actual config.
    # Replace with your real repo URL.
    flake = "github:bcrescimanno/homelab-nix#${config.networking.hostName}";
    flags = [ "--refresh" ];
    dates = "04:00"; # Run at 4am
    randomizedDelaySec = "30m"; # Stagger if multiple devices run this
  };

  # ---------------------------------------------------------------------------
  # Common packages
  # ---------------------------------------------------------------------------

  # These are packages installed at the system level, available to all users.
  # In Nix, installing a package here doesn't "pollute" the system — it's
  # tracked and can be removed just as declaratively as it was added.
  environment.systemPackages = with pkgs; [
    git
    btop
    curl
    wget
    jq
    lsof
    home-manager
    python3
    sqlite
    bind.dnsutils  # dig, nslookup
    usbutils       # lsusb
    ripgrep
  ];

  # ---------------------------------------------------------------------------
  # Locale & timezone
  # ---------------------------------------------------------------------------

  time.timeZone = "America/Los_Angeles"; # adjust to your timezone
  i18n.defaultLocale = "en_US.UTF-8";

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  # Write the current system configuration (the /nix/store path) to
  # /run/current-system/configuration. Handy for debugging.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Allow the nix daemon to be used by wheel users for building.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # Periodically clean up old generations to free disk space.
  # Keeps the last 7 days of builds. You can always roll back within that window.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
}
