# hosts/celes.nix — host-specific configuration for celes.
#
# celes is Brian's laptop: ASUS ROG Zephyrus G14 2024 (GA403UI) — Ryzen 9
# 8945HS with a Radeon 780M (Hawk Point), RTX 4070 Laptop (AD106, Ada), 32 GB,
# 2880x1800 120 Hz OLED. A desktop, not a server: Plasma 6, with the dGPU
# asleep unless something asks for it. It is also the trial run for Plasma on
# liquidark, which is why the Hyprland setup it ran on Arch is not carried over.
#
# There is NO nixos-hardware module for the GA403 (nixos-hardware #1136, open
# since 2024; PR #1255 closed unmerged). What the GA402X module does was
# checked against this machine before borrowing any of it, and almost nothing
# was needed: the Arch install ran a stock kernel cmdline with no ASUS
# workarounds. In particular its `mem_sleep_default=deep` is inert here —
# Hawk Point offers s2idle only (`/sys/power/mem_sleep` = `[s2idle]`).
#
# Everything below that describes "what Arch did" was read off the running
# Arch install on 2026-10-13 (kernel 7.2.9, BIOS GA403UI.311, asusctl 6.5.0,
# nvidia-open 615.71.09).
#
# ---------------------------------------------------------------------------
# Installation is a checklist in hosts/celes-install.md: nixos-anywhere from
# a NixOS USB stick, not terra's kexec recipe (the kexec installer has no
# Wi-Fi, and the G14 has no Ethernet port), plus the Wi-Fi/Bluetooth
# carry-over and the first-boot checks.
# ---------------------------------------------------------------------------

{ config, pkgs, lib, inputs, ... }:

{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "celes";

  # The NVIDIA driver is unfree (as on terra); scoped to this host.
  nixpkgs.config.allowUnfree = true;

  # ---------------------------------------------------------------------------
  # Boot & Disk
  # ---------------------------------------------------------------------------

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Mainline, like terra. Not optional on ASUS hardware: TDP/PPT and the
  # MUX/dGPU switches come from the asus-armoury driver (mainline since 6.19),
  # and asusctl's own README says the minimum supported kernel is "always the
  # latest".
  boot.kernelPackages = pkgs.linuxPackages_latest;
  hardware.cpu.amd.updateMicrocode = true;

  # MT7922 Wi-Fi/Bluetooth, and the Cirrus CS35L56 speaker amps — their tuning
  # (cirrus/cs35l56-b0-dsp1-misc-10431b13-*) is in linux-firmware. Without
  # this the speakers are silent.
  hardware.enableRedistributableFirmware = true;

  # Plain ext4, no LUKS — decided 2026-10-13. Same layout the Arch install had.
  # No swap partition: base.nix's zram covers memory pressure, and nobody asked
  # for hibernate (which would need ~32 GB of disk swap).
  disko.devices = {
    disk.main = {
      type = "disk";
      # WD PC SN5000S 1TB — the only disk. By id so this can never name another.
      device = "/dev/disk/by-id/nvme-WD_PC_SN5000S_SDEQNSJ-1T00-1002_24212T808076";
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
  # Graphics — hybrid, dGPU asleep by default
  # ---------------------------------------------------------------------------
  #
  # The firmware MUX stays in hybrid (asus-armoury gpu_mux_mode = 1): the 780M
  # drives the panel and the desktop, and the 4070 sleeps in D3cold until
  # something renders on it. What picks the GPU is the API, not the compositor:
  #
  #   - Vulkan sees both GPUs, and DXVK sorts discrete adapters first
  #     (dxvk_instance.cpp, stable_sort on device type). So every Proton game
  #     and every Lutris/Wine game using DXVK or VKD3D-Proton lands on the
  #     4070 with no switch at all. Native Vulkan games mostly choose discrete
  #     themselves. This is the "automatic" switching, and it works only while the
  #     NVIDIA ICD stays visible. The Arch session's VK_ICD_FILENAMES=radeon
  #     (dotfiles env-celes, 2026-05-19) hid it to stop wakeups, which also sent
  #     DXVK games to the 780M. Games still reached the 4070 there only because
  #     Lutris's Wine runner had GPU = card1 (the NVIDIA card), which puts the ICD
  #     back for every Wine game. Don't reintroduce the session-wide hiding, and
  #     leave Lutris's GPU option on Auto here: it stores a DRM card name,
  #     and card numbers are not stable across boots or distros.
  #   - OpenGL picks the iGPU unless offloaded: `nvidia-offload <cmd>`
  #     (`nvidia-offload %command%` as a Steam launch option), Lutris's "GPU"
  #     system option, or Plasma's "Launch using dedicated GPU".
  #   - Steam's desktop entry has PrefersNonDefaultGPU=true, and Plasma obeys it
  #     through switcheroo-control. The Steam client itself (steamwebhelper)
  #     then renders on the 4070, which keeps the 4070 awake for as long as Steam is open,
  #     and every game it launches inherits the offload env. That trade-off is
  #     still undecided; see the measurement note below.
  #
  # supergfxctl is deliberately absent. Arch never had it installed, and
  # upstream did not move it when asusctl moved to OpenGamingCollective — last
  # release 5.2.7 (2025-02), last commit 2025-11.
  #
  # PORT WIRING: HDMI-A-1 and one USB-C DP output hang off the NVIDIA card;
  # the iGPU has the panel and the other USB-C outputs. Anything plugged into
  # HDMI wakes the dGPU for as long as it is connected.
  services.xserver.videoDrivers = [ "amdgpu" "nvidia" ];
  hardware.amdgpu.initrd.enable = true; # panel console from the first frame
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Wine/Lutris and 32-bit games
  };
  hardware.nvidia = {
    # Ada works with either; the open modules are what Arch ran (nvidia-open).
    open = true;
    # The feature branch, as on terra — 615.x is also what Arch ran.
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    modesetting.enable = true;
    powerManagement = {
      enable = true;
      # NVreg_DynamicPowerManagement=0x02: fine-grained D3cold WITHOUT the
      # driver default's (3) periodic VRAM migration, which on Arch woke the
      # dGPU every few minutes (dotfiles 85ce0ac). Arch's fix lived in a
      # hand-made /etc/modprobe.d/nvidia-pm.conf that had since vanished — the
      # running driver reported 3 on 2026-10-13. Here it cannot drift.
      finegrained = true;
    };
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true; # the `nvidia-offload` wrapper
      };
      # 0000:65:00.0 and 0000:01:00.0 in lspci; PCI:<bus>:<dev>:<fn>, decimal.
      amdgpuBusId = "PCI:101:0:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # NOT SET YET: KWIN_DRM_DEVICES. On Arch, Hyprland had to be pinned to the
  # iGPU (AQ_DRM_DEVICES) or it kept opening the NVIDIA node and waking it, and
  # KWin has a reported twin of that bug: it opens the D3cold dGPU and stalls
  # its main thread ~12 s each time (KDE bug 519935, on a 2022 G14 under Plasma
  # 6.5.6). The fix is KWIN_DRM_DEVICES=<iGPU card> — but that also takes HDMI
  # away from KWin entirely, and card numbers are not stable (Arch had the
  # iGPU at card2), so it is not set blind. Measure first: idle on the desktop
  # and watch /sys/bus/pci/devices/0000:01:00.0/power/runtime_status and
  # runtime_active_time. Do not run lspci while measuring — it wakes the card.
  # Measure twice, Steam closed and Steam open. With the ICD visible, any
  # Vulkan app that creates an instance briefly wakes the card too. That
  # is the price of the automatic game switching above. Narrow it per app,
  # never by hiding the ICD session-wide.

  # ---------------------------------------------------------------------------
  # ASUS firmware controls — asusd
  # ---------------------------------------------------------------------------
  #
  # asusd keeps the charge limit, the keyboard backlight and the Slash lid bar.
  # It does NOT manage power profiles here: power-profiles-daemon does (below),
  # and asusctl's own docs say to run exactly one of the two, because both write
  # /sys/firmware/acpi/platform_profile and the CPU EPP. With PPD in charge the
  # three switches below must be false. That costs nothing on this machine —
  # every custom fan curve was disabled on Arch and no per-profile tunings were
  # set.
  #
  # These files are COPIED into /etc/asusd (the module sets mode 0644), not
  # linked, because asusd writes its config back. So rog-control-center and
  # `asusctl` still work and their changes stick until the next activation,
  # when the values here are written back. asusd reads the files only at start,
  # so in practice what is here is the state at boot.
  #
  # Verified on Arch under systemd 262: asusd reaches the Slash (0b05:193b) and
  # keyboard (0b05:19b6) hidraw nodes despite its unit's ProtectClock=yes, so
  # the device-policy trap in asusctl #400 does not apply on a current systemd.
  # If `asusctl leds get` ever says "No aura interface found", that is the
  # first suspect — fix with serviceConfig.DeviceAllow = [ "char-hidraw rw" ].
  services.asusd = {
    enable = true;
    asusdConfig.text = ''
      (
          charge_control_end_threshold: 80,
          base_charge_control_end_threshold: 0,
          disable_nvidia_powerd_on_battery: true,
          ac_command: "",
          bat_command: "",
          platform_profile_linked_epp: false,
          platform_profile_on_battery: Quiet,
          change_platform_profile_on_battery: false,
          platform_profile_on_ac: Performance,
          change_platform_profile_on_ac: false,
          profile_quiet_epp: Power,
          profile_balanced_epp: BalancePower,
          profile_custom_epp: Performance,
          profile_performance_epp: Performance,
          ac_profile_tunings: {},
          dc_profile_tunings: {},
          armoury_settings: {},
      )
    '';
    # Keyboard: single-zone, static red. Brightness here is the boot default;
    # Plasma's keyboard-backlight control changes it live.
    auraConfigs."19b6".text = ''
      (
          config_name: "aura_19b6.ron",
          brightness: Med,
          current_mode: Static,
          builtins: {
              Static: (
                  mode: Static,
                  zone: r#None,
                  colour1: (r: 166, g: 0, b: 0),
                  colour2: (r: 0, g: 0, b: 0),
                  speed: Med,
                  direction: Right,
              ),
          },
          multizone_on: false,
          enabled: (
              states: [
                  (zone: Keyboard, boot: true, awake: true, sleep: true, shutdown: true),
              ],
          ),
      )
    '';
  };

  # The Slash lid bar. The NixOS module has no option for slash.ron, so it is
  # written the same way the module writes its own files.
  environment.etc."asusd/slash.ron" = {
    mode = "0644";
    text = ''
      (
          enabled: true,
          brightness: 255,
          display_interval: 0,
          display_mode: Bounce,
          show_on_boot: true,
          show_on_shutdown: true,
          show_on_sleep: true,
          show_on_battery: true,
          show_battery_warning: true,
          show_on_lid_closed: true,
      )
    '';
  };

  # Power profiles: PPD, so Plasma's battery-applet slider and its per-source
  # profile settings (System Settings → Power Management: AC / battery / low
  # battery) work. That per-source setting is what replaces asusd's old
  # Performance-on-AC / Quiet-on-battery switching — set it there. The plasma6
  # module already defaults this on; stated so the asusd block above has
  # something to point at.
  services.power-profiles-daemon.enable = true;

  # Plasma's "Launch using dedicated GPU" asks switcheroo-control which GPU is
  # discrete; the plasma6 module does not enable it.
  services.switcherooControl.enable = true;

  # ---------------------------------------------------------------------------
  # Desktop — Plasma 6
  # ---------------------------------------------------------------------------

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # Same DrKonqi coredump loop terra hit (hosts/terra.nix): masked, not
  # excluded, for the same reasons. coredumpctl still has every dump.
  systemd.services."drkonqi-coredump-processor@".enable = false;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;

  # The password manager holds the SSH key and signs git commits, through its
  # agent socket (dotfiles home/ssh-agent.nix, dotfiles.sshAgent = "bitwarden").
  # Lutris lives here rather than in dotfiles because it pulls in unfree Steam
  # runtime pieces, and only this host allows unfree.
  environment.systemPackages = [ pkgs.bitwarden-desktop pkgs.lutris ];
  programs.firefox.enable = true;
  programs.gamemode.enable = true;

  # The terminal font dotfiles' Ghostty config names (home/terminal.nix).
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # ---------------------------------------------------------------------------
  # Login
  # ---------------------------------------------------------------------------
  #
  # base.nix sets users.mutableUsers = false and gives brian no password —
  # fine for the servers and terra (which never locks), not for a laptop that
  # needs a login screen and a lock screen. The hash comes from sops;
  # neededForUsers makes sops-nix decrypt it before users are created.
  # base.nix's passwordless sudo for wheel still applies.
  sops.secrets.brian_password_hash.neededForUsers = true;
  users.users.brian = {
    hashedPasswordFile = config.sops.secrets.brian_password_hash.path;
    extraGroups = [ "networkmanager" ];
  };

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  #
  # NetworkManager, as on terra: Plasma's network applet drives it, and a
  # laptop roams. Its address on the home Wi-Fi is DHCP (10.0.1.214).
  networking.networkmanager.enable = true;

  # ---------------------------------------------------------------------------
  # Upgrades
  # ---------------------------------------------------------------------------
  #
  # A laptop is rarely awake at 04:00 and must never be woken for it in a bag,
  # so no WakeSystem (unlike terra). base.nix's Persistent timer instead runs
  # the missed upgrade soon after the next resume — but only on AC power, so it
  # never compiles on battery. A battery resume skips that day entirely.
  systemd.services.homelab-upgrade.unitConfig.ConditionACPower = true;

  # The Plasma session is the job. A closure that comes up without a display
  # manager is a failed upgrade, and post-upgrade-check rolls it back.
  homelab.postUpgradeCheck.services = [ "display-manager" ];

  # homelab.reboot.auto stays false: a laptop is not rebooted from under its
  # user. A kernel bump gets the nightly "Reboot pending" push instead.

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------
  #
  # tailscale_auth_key is declared by modules/tailscale.nix (the same value as
  # every other host's yaml); brian_password_hash under Login above.
  sops = {
    defaultSopsFile = ../secrets/celes.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # JWT push token for the attic post-build hook — the NVIDIA module built
      # against celes's kernel is then cached.
      attic_push_token = {};
    };
  };

  # ---------------------------------------------------------------------------
  # Home Manager
  # ---------------------------------------------------------------------------
  #
  # celes-nixos.nix, not celes.nix: the latter still serves the Arch install
  # until the wipe, and is retired after it.
  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/celes-nixos.nix" ];
  };

  system.stateVersion = "26.11";
}
