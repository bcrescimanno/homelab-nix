# hosts/terra.nix — host-specific configuration for terra.
#
# terra is the living-room games console: AMD Ryzen 7 5700X3D, NVIDIA RTX 5070
# Ti (Blackwell, GB203), on the TV. It boots straight into Steam's Gaming Mode
# (the Steam Deck UI) via Jovian-NixOS, with Plasma 6 behind "Switch to
# Desktop". It is the only host here that is not a server.
#
# WHY NOT SteamOS: as of 2026-10 SteamOS has no public NVIDIA driver stack;
# Valve's own estimate was "not before late 2026", with no promise that
# Blackwell is in the first wave. Bazzite's deck-nvidia image was the other
# candidate and is the lower-effort couch experience, but it would be the one
# machine in the house managed differently. Revisit if SteamOS ships NVIDIA.
#
# NVIDIA CAVEAT: Jovian is developed on AMD hardware and says NVIDIA "may have
# issues". Known so far (2026): Remote Play broken in the NVIDIA gamescope
# session (upstream gamescope PR #2094), and a one-minute black screen that
# turned out to be bluez timing out with no adapter present (Jovian #542).
#
# FIRST THING TO CHECK after install: on Arch with the 595.x driver, gamescope's
# DRM backend flickered along the bottom of the screen on this card (NVIDIA bug
# 5240452). This config runs gamescope again, on 615.x. If the flicker is back,
# the fallback is greetd → Hyprland → `steam -gamepadui` with no gamescope —
# i.e. replace jovian.steam.autoStart, not the whole host.
#
# ---------------------------------------------------------------------------
# Initial installation via nixos-anywhere (same recipe as orthanc). This WIPES
# the disk named in disko.devices below — check it against `lsblk` on terra.
#
#   age-keygen -o /tmp/terra-age-key.txt          # public key → .sops.yaml
#   mkdir -p /tmp/terra-extra/var/lib/sops-nix
#   cp /tmp/terra-age-key.txt /tmp/terra-extra/var/lib/sops-nix/key.txt
#
#   # Bluetooth pairings, so controllers work at first boot. They are keyed by
#   # the adapter's MAC, which the wipe does not change. Taken from Arch BEFORE
#   # the wipe; root-owned 0700 on the target, as bluez expects.
#   # (Arch's sudo wants a password, so -t; a tty mangles binary, so via a file)
#   ssh -t brian@terra 'sudo tar -C / -cf /tmp/bt.tar var/lib/bluetooth && sudo chown brian /tmp/bt.tar'
#   scp brian@terra:/tmp/bt.tar /tmp/bt.tar && tar -C /tmp/terra-extra -xf /tmp/bt.tar
#
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#terra \
#     --extra-files /tmp/terra-extra \
#     root@<ip>
# ---------------------------------------------------------------------------

{ config, pkgs, lib, inputs, ... }:

let
  # A unit that holds a sleep inhibitor for exactly as long as `unit` runs —
  # see "Upgrades & health".
  sleepInhibitor = unit: why: {
    description = "Inhibit sleep: ${why}";
    wantedBy = [ "${unit}.service" ];
    bindsTo = [ "${unit}.service" ];
    serviceConfig.ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:idle --who=${unit} --why='${why}' --mode=block ${pkgs.coreutils}/bin/sleep infinity";
  };
in
{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "terra";

  # Steam and the NVIDIA driver are both unfree, and so is a long tail of
  # Steam's runtime dependencies — a predicate would be a list nobody keeps
  # current. Scoped to this host; the servers stay free-only.
  nixpkgs.config.allowUnfree = true;

  # ---------------------------------------------------------------------------
  # Boot & Disk
  # ---------------------------------------------------------------------------

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # A console nobody sees boot: keep the generation menu reachable (hold a key)
  # for rollbacks, but don't sit on it.
  boot.loader.timeout = 1;

  # Mainline, not the LTS default every server runs: terra is a desktop on an
  # out-of-tree NVIDIA driver, and 7.x + 615.x is the pairing it ran on Arch.
  # If nixpkgs moves _latest past what the driver supports, the nightly build
  # fails before switching and terra stays on its current system.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [ "amd_pstate=active" ];
  hardware.cpu.amd.updateMicrocode = true;

  # Gigabyte AB350N-Gaming WIFI: the Realtek RTL8111 NIC (rtl_nic), the Intel
  # 3165 Wi-Fi and its 8087:0a2a Bluetooth all load firmware from
  # linux-firmware. Without this, Bluetooth controllers have no adapter.
  hardware.enableRedistributableFirmware = true;

  disko.devices = {
    disk.main = {
      type = "disk";
      # Samsung 980 PRO 1TB — terra's ONLY disk, so installing replaces Arch
      # and everything on it. Steam games are re-downloaded, not restored;
      # back up anything non-Steam first.
      # By id rather than /dev/nvme0n1 so this can never name another disk.
      device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5P2NS0X203728Y";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "1G"; # room for several kernel+initrd generations
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
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
  # Graphics — NVIDIA
  # ---------------------------------------------------------------------------
  #
  # `open = true` is not a preference: Blackwell is supported ONLY by the open
  # kernel modules. `latest` (the new-feature branch, 615.x at the 2026-10-07
  # lock) rather than `stable`, which in nixpkgs aliases the long-lived
  # production branch (595.x) — gamescope/Proton fixes on NVIDIA land in the
  # feature branch first. It is the same driver terra ran on Arch.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # 32-bit games and parts of the Steam runtime
  };
  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    # gamescope drives the display through KMS; without modesetting there is no
    # DRM device for it to take.
    modesetting.enable = true;
    # Saves VRAM across suspend (NVreg_PreserveVideoMemoryAllocations) so
    # sleeping from Gaming Mode does not come back to a corrupted session.
    powerManagement.enable = true;
  };

  # ---------------------------------------------------------------------------
  # Gaming Mode — Jovian-NixOS
  # ---------------------------------------------------------------------------
  #
  # autoStart replaces a display manager: SDDM auto-logs brian straight into
  # the gamescope session, and "Switch to Desktop" lands in Plasma. Plasma
  # rather than the Hyprland setup terra ran on Arch because it is Jovian's
  # documented desktop and SteamOS's own — Desktop Mode is the fallback for the
  # odd non-Steam task, not somewhere anyone lives.
  #
  # The Arch install passed `gamescope -r 120`; in Gaming Mode the refresh rate
  # is Steam's own Settings → Display, so it is set there, not here.
  jovian.steam = {
    enable = true;
    autoStart = true;
    user = "brian";
    desktopSession = "plasma";
  };

  # useSteamOSConfig (on by default with jovian.steam.enable) brings Valve's
  # sysctls, bluetooth config, zram and earlyoom — wanted. Its kernel cmdline
  # is NOT wanted: besides inert amdgpu.* tuning it sets `amd_iommu=off` and
  # `ttm.pages_min=2097152` (an 8 GiB TTM floor, sized for the Deck's shared
  # memory — half of terra's RAM). Both are Deck assumptions.
  jovian.steamos.enableDefaultCmdlineConfig = false;

  # Steam's Settings → Software Updates asks Jovian's `steamos-update check`
  # stub, which reports "restart pending" (exit 8) when the booted kernel and
  # the system profile's kernel differ — compared with a bare `readlink`, i.e.
  # by symlink TARGET. deploy-rs installs an `activatable-nixos-system-*`
  # wrapper whose `kernel` points at the inner toplevel's `kernel`, not at the
  # bzImage, so after any `deploy terra` the strings differ while the kernel is
  # identical: a permanent yellow "!" that "Restart" (a real reboot) never
  # clears. `readlink -f` compares what the links resolve to, which keeps the
  # check honest for a real kernel update. Upstream: Jovian-NixOS
  # pkgs/jovian-stubs/holo-update.
  #
  # Not in flake.nix's overlayWorkarounds: that probe builds a nixpkgs package
  # unpatched, and this is neither. --replace-fail is the probe instead — once
  # upstream changes the line, terra's build fails and this block goes, in the
  # same PR as the jovian lock bump. mkAfter: it must apply after Jovian's own
  # overlay, which is what defines jovian-stubs.
  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      jovian-stubs = prev.jovian-stubs.overrideAttrs (old: {
        buildCommand = old.buildCommand + ''
          for f in $out/bin/holo-update $out/bin/steamos-polkit-helpers/steamos-update; do
            substituteInPlace "$f" \
              --replace-fail '"$(readlink /run/booted-system/kernel)"' '"$(readlink -f /run/booted-system/kernel)"' \
              --replace-fail '"$(readlink /nix/var/nix/profiles/system/kernel)"' '"$(readlink -f /nix/var/nix/profiles/system/kernel)"'
          done
        '';
      });
    })
  ];

  # Steam runs as brian, so the couch session gets the same home-manager
  # profile as every other machine (the Arch install's separate `gamers`
  # account is retired). The trade-off is accepted knowingly: brian is in
  # wheel and base.nix makes wheel passwordless, so every game and Proton
  # prefix runs as a user with root a `sudo` away.
  users.users.brian.extraGroups = [ "networkmanager" ];

  services.desktopManager.plasma6.enable = true;

  # brian has no password (users.mutableUsers = false, keys only), so a Plasma
  # lock screen would be a lock nobody can open. Gaming Mode never locks.
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
  '';

  # Steam is an X11 client, and in Desktop Mode it drives the controller as a
  # mouse/keyboard by injecting input through Xwayland. KWin 6 gates that
  # behind kwin_eis_prompter's "steam is asking to control input devices"
  # dialog — which the controller cannot answer, because the controller IS
  # that input: it goes dead the moment the dialog appears (2026-10-09, first
  # Desktop Mode launch). Pre-allowing the client name is what the dialog's
  # own "Always allow" checkbox writes. Accepted trade-off on a console: any
  # X11 app calling itself "steam" can inject input. System-level /etc/xdg so
  # a fresh home directory never sees the dialog; KWin reads it at startup.
  # SteamOS puts a "Return to Gaming Mode" icon on the desktop; Jovian does not
  # ship one, which left Desktop Mode with no way back (2026-10-09). Plasma's
  # Log Out is NOT a substitute: "Switch to Desktop" leaves an SDDM one-shot
  # (/etc/sddm.conf.d/zzt-holo-temp-login.conf, Session=plasma.desktop) that
  # steamos-manager only cleans at the start of a graphical session, so a
  # relogin can land straight back in Plasma. steamosctl is SteamOS's own path
  # and handles that file. In the app launcher, and on the desktop (Plasma
  # only shows a ~/Desktop launcher that is executable — hence the flag).
  environment.systemPackages = [
    (pkgs.makeDesktopItem {
      name = "return-to-gaming-mode";
      desktopName = "Return to Gaming Mode";
      exec = "steamosctl switch-to-game-mode";
      icon = "steam";
      categories = [ "Game" ];
    })
  ];
  home-manager.users.brian.home.file."Desktop/Return to Gaming Mode.desktop" = {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Application
      Name=Return to Gaming Mode
      Exec=steamosctl switch-to-game-mode
      Icon=steam
    '';
  };

  environment.etc."xdg/kwinrc".text = ''
    [Xwayland]
    XwaylandEisNoPromptApps=steam
  '';

  # Steam's LAN game-transfer and Remote Play ports. Remote Play is currently
  # broken under NVIDIA gamescope anyway (see header); the transfer port is the
  # one that matters.
  programs.steam = {
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  #
  # 10.0.1.215 is a DHCP reservation on the UDM Pro, and Blocky maps
  # terra.home.theshire.io to it statically (modules/dns.nix) so the name
  # resolves the moment WoL fires, before any lease exists.
  #
  # NetworkManager rather than the dhcpcd every other host uses: the Steam Deck
  # UI talks to it for its network settings, and its first-run setup cannot
  # complete without it (Jovian warns at eval time when it is off).
  networking.networkmanager.enable = true;

  # Wake-on-LAN on enp9s0 (RTL8111, 1c:1b:0d:9a:b4:a8). terra suspends rather
  # than powering off, and is woken from suspend over the LAN. On Arch this was
  # the NetworkManager profile's `wake-on-lan=magic`; NM re-applies its setting
  # on every activation, so it — not a .link file like orthanc's — is the one
  # place that must say magic, or NM would quietly disarm it. Set as the global
  # default because the wired profile is NM's auto-created one.
  #
  # The value is the NM_SETTING_WIRED_WAKE_ON_LAN flag as an INTEGER (64 =
  # magic). NetworkManager.conf parses this key numerically, unlike nmcli: the
  # string "magic" fails to parse, falls back to `ignore` with nothing logged,
  # and the first install booted with ethtool showing `Wake-on: d`.
  networking.networkmanager.settings.connection."ethernet.wake-on-lan" = 64;

  # ---------------------------------------------------------------------------
  # Sleep
  # ---------------------------------------------------------------------------

  # IN GAMING MODE THIS DOES NOTHING. logind only acts on sessions that report
  # an idle hint, and gamescope never does (IdleSinceHint=0 for the whole
  # session, verified 2026-10-09). What actually sleeps terra there is Steam's
  # own Settings → Power → Sleep → When Plugged In, set to 30 minutes. That
  # lives in Steam's config under ~/.local/share/Steam, not here, so a
  # reinstall must set it again. It is also what puts terra back to sleep after
  # the 05:20 upgrade wake. Kept for Desktop Mode, where Plasma does report idle.
  services.logind.settings.Login = {
    IdleAction = "suspend";
    IdleActionSec = "30min";
  };

  # Wake from suspend with a Bluetooth controller: the Intel BT adapter AND the
  # USB root hub it hangs off must both be wake-enabled (ported from Arch's
  # 90-bt-wakeup.rules). The DEVPATH is the AB350N's xHCI at 02:00.0 — fixed
  # hardware topology, not enumeration order.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="8087", ATTRS{idProduct}=="0a2a", ATTR{power/wakeup}="enabled"
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVPATH}=="/devices/pci0000:00/0000:00:01.3/0000:02:00.0/usb1", ATTR{power/wakeup}="enabled"
  '';

  # Never suspend under an SSH session (ported from Arch's ssh-sleep-inhibit).
  # Load-bearing for deploys: a 30-minute idle suspend mid-`deploy terra`
  # drops the connection and deploy-rs's magic rollback undoes the deploy.
  systemd.services.ssh-sleep-inhibit = {
    description = "Inhibit sleep while SSH sessions are active";
    wantedBy = [ "multi-user.target" ];
    after = [ "sshd.service" ];
    path = [ pkgs.iproute2 pkgs.systemd pkgs.gnugrep pkgs.coreutils ];
    # Polls every 20s and holds each inhibitor for 30s, so they overlap.
    script = ''
      while true; do
        if ss -tnH state established '( sport = :22 )' | grep -q .; then
          systemd-inhibit --what=sleep:idle --who=ssh-guard \
            --why="Active SSH session" --mode=block sleep 30 &
        fi
        sleep 20
      done
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };

  # ...and REFUSE to suspend under one, because the inhibitor above is only
  # advisory. It stops logind's IdleAction, but on Arch a plain
  # `systemctl suspend` from the desktop session got past it (2026-10-08), and
  # Gaming Mode's Sleep button takes that same path. Being RequiredBy
  # sleep.target makes the suspend job itself fail while SSH is up, whoever
  # asked. Safe with this GPU only because no nvidia-suspend/-resume units
  # exist (the driver uses kernel suspend notifiers): a refused suspend cannot
  # strand the GPU half-suspended.
  systemd.services.ssh-sleep-veto = {
    description = "Refuse to sleep while SSH sessions are active";
    requiredBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    unitConfig = {
      DefaultDependencies = false;
      # Stop again when sleep.target stops after resume, so the check runs on
      # every sleep attempt rather than once.
      StopWhenUnneeded = true;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.iproute2 pkgs.gnugrep ];
    script = ''
      if ss -tnH state established '( sport = :22 )' | grep -q .; then
        echo "refusing to sleep: active SSH session(s)" >&2
        exit 1
      fi
    '';
  };

  # ---------------------------------------------------------------------------
  # Upgrades & health
  # ---------------------------------------------------------------------------
  #
  # The goal is that the nightly upgrade never starts under a game. terra
  # spends its nights SUSPENDED, and a calendar timer that elapses during
  # suspend fires on resume — i.e. the moment someone picks up a controller.
  # So the timer wakes the machine at its slot instead (WakeSystem), the
  # upgrade runs, and the 30-minute idle suspend below puts it back to sleep.
  # Persistent is off for the rarer fully-powered-off night, for the same
  # reason: Persistent would run the missed upgrade at power-on.
  #
  # The switch never restarts the display manager, so even a mid-game upgrade
  # would not end the session — this is about not compiling a driver under a
  # game.
  systemd.timers.homelab-upgrade.timerConfig = {
    WakeSystem = true;
    Persistent = lib.mkForce false;
  };

  # Emulator saves are backed up (modules/emulation.nix) on the same terms:
  # backup.nix's 03:00/04:00 slots would elapse during suspend and fire on
  # resume, under a game, so terra's repos run on wake timers just ahead of
  # the upgrade — the one wake serves all three. Not Persistent, for the same
  # reason as the upgrade. Its onsite repo is a subdirectory because
  # backups/terra/ on erebor already holds the Arch-era plain copy of ~/ROMs
  # and ~/ES-DE.
  services.restic.backups.local.timerConfig = lib.mkForce {
    OnCalendar = "05:00";
    WakeSystem = true;
  };
  services.restic.backups.offsite.timerConfig = lib.mkForce {
    OnCalendar = "05:05";
    WakeSystem = true;
  };
  homelab.backup.localRepository = "/var/backup/erebor/terra/restic";

  # Hold off idle suspend for as long as each of those runs: the machine was
  # woken just for it, nobody is touching it, and IdleAction would otherwise
  # suspend it mid-build (a cold NVIDIA module build can run past 30 min).
  # No After=: started alongside the oneshot, and BindsTo stops it the moment
  # the unit goes inactive, success or failure.
  systemd.services.homelab-upgrade-inhibit =
    sleepInhibitor "homelab-upgrade" "NixOS upgrade running";
  systemd.services.restic-backups-local-inhibit =
    sleepInhibitor "restic-backups-local" "Backup to erebor running";
  systemd.services.restic-backups-offsite-inhibit =
    sleepInhibitor "restic-backups-offsite" "Backup to R2 running";

  # Gaming Mode is the whole job: a closure that boots to a black screen is a
  # failed upgrade, and post-upgrade-check rolls it back.
  homelab.postUpgradeCheck.services = [ "display-manager" ];

  # Reboot for a new kernel straight after the nightly upgrade (inside
  # reboot-policy's 03:00–07:00 window). The alternative is a "reboot pending"
  # push every night: terra suspends rather than powering off, so on its own it
  # would never pick a kernel up. Nobody is on a living-room console at 05:30,
  # and Gaming Mode autostarts again on the way back up.
  homelab.reboot.auto = true;

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------
  #
  # Only what base.nix's imports need. tailscale_auth_key is declared by
  # modules/tailscale.nix, restic_password and restic_r2_env by backup.nix
  # (emulator saves); all three are the same value as in every other host's
  # yaml.
  sops = {
    defaultSopsFile = ../secrets/terra.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # JWT push token for the attic post-build hook — anything terra builds
      # (the NVIDIA module against its kernel, mostly) is then cached.
      attic_push_token = {};
    };
  };

  # ---------------------------------------------------------------------------
  # Home Manager
  # ---------------------------------------------------------------------------

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/terra.nix" ];
  };

  system.stateVersion = "26.11";
}
