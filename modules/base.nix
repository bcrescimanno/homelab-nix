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
  # Append search domain so bare hostnames resolve (e.g. `mirkwood` → `mirkwood.home.theshire.io`).
  # This lets containers and services reference each other without the full suffix.
  networking.search = [ "home.theshire.io" ];

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

  # homelab-upgrade is a shared oneshot service present on all three hosts.
  # On mirkwood it is triggered by homelab-upgrade-orchestrator (declared in
  # hosts/mirkwood.nix), which builds first and primes the attic cache.
  # On rivendell and pirateship it is triggered via SSH by that same
  # orchestrator after mirkwood's own upgrade completes.
  #
  # All three hosts share the same service definition — each runs
  # nixos-rebuild switch against its own hostname and sends its own ntfy
  # notification on success or failure.
  systemd.services.homelab-upgrade = {
    description = "Homelab NixOS upgrade";
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # --refresh re-fetches the latest flake revision from GitHub.
      ExecStart = toString (pkgs.writeShellScript "homelab-upgrade-run" ''
        exec /run/current-system/sw/bin/nixos-rebuild switch \
          --flake "github:bcrescimanno/homelab-nix#${config.networking.hostName}" \
          --refresh
      '');
    };
    unitConfig = {
      OnSuccess = "homelab-upgrade-notify-success.service";
      OnFailure = "homelab-upgrade-notify-failure.service";
    };
  };

  systemd.timers.homelab-upgrade = {
    description = "Daily NixOS upgrade";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:00";
      Persistent = true;
      # Spread host upgrades randomly within a 15-minute window so they
      # don't all hammer orthanc and attic at the exact same second.
      RandomizedDelaySec = "15m";
    };
  };

  # Notify ntfy when this host's upgrade succeeds or fails.
  # Uses the LAN address of rivendell directly — avoids DNS dependency
  # during the brief window when Blocky restarts on the upgrading host.
  systemd.services.homelab-upgrade-notify-success = {
    description = "Notify ntfy of successful homelab upgrade";
    serviceConfig = {
      Type = "oneshot";
      # --retry 5 / --retry-delay 15: tolerates ntfy container restarts and
      # brief DNS unavailability while Blocky restarts on the upgrading host.
      ExecStart = "${pkgs.curl}/bin/curl -s "
        + "--connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors "
        + "-H 'Title: NixOS Updated' "
        + "-H 'Priority: 2' "
        + "-H 'Tags: white_check_mark' "
        + "-d '${config.networking.hostName} upgraded successfully' "
        + "http://10.0.1.9:2586/homelab";
    };
  };

  systemd.services.homelab-upgrade-notify-failure = {
    description = "Notify ntfy of failed homelab upgrade";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.curl}/bin/curl -s "
        + "--connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors "
        + "-H 'Title: NixOS Upgrade FAILED' "
        + "-H 'Priority: 4' "
        + "-H 'Tags: rotating_light' "
        + "-d '${config.networking.hostName} upgrade failed — check journalctl -u homelab-upgrade' "
        + "http://10.0.1.9:2586/homelab";
    };
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

  # Attic binary cache — served from mirkwood as cache.theshire.io.
  # The post-build hook pushes every built path to the cache so subsequent
  # hosts (and future upgrades) can fetch instead of rebuilding.
  #
  # The hook exits gracefully if attic_push_token is not yet provisioned —
  # this lets all hosts deploy before the cache is fully set up.
  # Add the signing public key to extra-trusted-public-keys once the cache
  # is created (see step 4 in modules/attic.nix).
  nix.settings.extra-substituters = [ "https://cache.theshire.io/nixpkgs" ];
  nix.settings.extra-trusted-public-keys = [ "nixpkgs:4zoHH4lPBJuJfPmH0/FjKl5yIYfG0yCZc39m492t+jM=" ];

  nix.settings.post-build-hook = toString (pkgs.writeShellScript "attic-push" ''
    set -f  # Disable glob expansion on $OUT_PATHS

    [ -f /run/secrets/attic_push_token ] || exit 0
    [ -n "$OUT_PATHS" ] || exit 0

    ATTIC_TOKEN=$(cat /run/secrets/attic_push_token)
    # Valid JWTs always start with 'eyJ' — skip if token is a placeholder.
    case "$ATTIC_TOKEN" in eyJ*) ;; *) exit 0 ;; esac

    # attic reads config from $HOME/.config/attic/config.toml.
    # Use a temp HOME so we don't pollute /root/.config.
    ATTIC_HOME=$(mktemp -d --tmpdir attic.XXXXXXXX)
    trap 'rm -rf "$ATTIC_HOME"' EXIT
    mkdir -p "$ATTIC_HOME/.config/attic"
    printf '[servers.homelab]\nendpoint = "https://cache.theshire.io/"\ntoken = "%s"\n' \
      "$ATTIC_TOKEN" > "$ATTIC_HOME/.config/attic/config.toml"

    # Push one path at a time — the attic client (0-unstable-2025-09-24) has a
    # panic_in_cleanup bug in Pusher::worker that triggers when batching multiple
    # paths. Pushing serially avoids it. Remove the loop once attic is fixed upstream.
    for path in $OUT_PATHS; do
      HOME="$ATTIC_HOME" ${pkgs.attic-client}/bin/attic push homelab:nixpkgs "$path" \
        || echo "attic-push: push failed for $path (non-fatal)" >&2
    done
  '');

  # Allow the nix daemon to be used by wheel users for building.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # Increase download buffer to avoid "download buffer is full" warnings during
  # deploys. Default is 64MB; 256MB is comfortable on Pi 5 (4-8GB RAM).
  nix.settings.download-buffer-size = 256 * 1024 * 1024;

  # zram swap: gives 4GB Pis breathing room during memory-intensive builds
  # (e.g. kernel compilation). zram compresses pages in RAM — no disk I/O,
  # ~2x memory multiplier typical. Without this, parallel `make` during kernel
  # builds OOM-kills the process on 4GB Pis.
  zramSwap.enable = true;

  # Periodically clean up old generations to free disk space.
  # Keeps the last 7 days of builds. You can always roll back within that window.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
}
