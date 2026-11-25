# celes install checklist

Moving celes (ASUS Zephyrus G14 2024, GA403UI) from Arch + Hyprland to NixOS + Plasma 6. The config is `hosts/celes.nix`, merged in #874. Tick the boxes as you go, and note anything that went differently in the log at the end.

**This wipes celes's only disk.** Nothing in `/home` survives.

## Why kexec over the dock

terra was installed with nixos-anywhere's usual path: it kexecs the running system into an in-RAM installer, which only brings up wired networking (`docs/requirements.md`: "nixos-anywhere does not support wifi networks"). The G14 has no Ethernet port, which is why this checklist first planned on a USB stick.

On 2026-11-20 celes got a wire: the **CalDigit Thunderbolt 4 Pro Dock**, whose Intel 2.5GbE NIC (`igc`, `enp100s0`, 10.0.1.85) sits behind a USB4 PCIe tunnel. The Thunderbolt domain's security level is `user`, so that tunnel exists only once something authorizes the dock. On Arch that is boltd. **The kexec installer has no boltd**, and whether the tunnel survives the kexec is unverified, so the kexec runs as a separate probe first: nothing on disk is touched until it reconnects. The USB stick on Wi-Fi stays as the fallback (section 4b).

The installed system runs boltd (`services.hardware.bolt.enable`), and Arch's `/var/lib/boltd` comes along so the dock is already enrolled at first boot.

## 1. Prepare

- [x] Anything important in `~` is backed up (confirmed 2026-11-20).
- [x] Unlock Bitwarden on liquidark, because the SSH key lives there. Work from `~/code/homelab-nix` on an up-to-date `main`.

## 2. Carry-over (right before the install)

Re-run this even though the tree already exists from 2026-10-13, so pairings made since are kept. Arch's sudo wants a password, so `ssh -t`. A tty mangles binary output, so the tar goes through a file. Both copies hold the Wi-Fi password, so the last line deletes them.

- [x] **Carry over Wi-Fi profiles, Bluetooth pairings and the bolt enrolment.**
  ```bash
  ssh -t brian@celes 'sudo tar -C / -cf /tmp/carry.tar etc/NetworkManager/system-connections var/lib/bluetooth var/lib/boltd && sudo chown brian /tmp/carry.tar'
  scp brian@celes:/tmp/carry.tar /tmp/ \
    && tar -C ~/.local/share/celes-install -xpf /tmp/carry.tar \
    && rm /tmp/carry.tar && ssh brian@celes rm /tmp/carry.tar
  ```
- [x] **Check the tree.** Profiles in `etc/NetworkManager/system-connections/` should be `-rw-------`, `var/lib/bluetooth` should be `drwx------`, and `var`, `var/lib` and `var/lib/boltd` should be `drwxr-xr-x`.
  ```bash
  find ~/.local/share/celes-install -printf '%M %p\n'
  ```

What carries over, as checked on 2026-10-13:
- `noctropolis` is WPA3 (SAE) with `psk-flags=0`, so the password is stored in the profile file and not in a keyring. The profile is pinned to `wlp3s0`, and NixOS uses the same predictable naming.
- The three hotel profiles are open networks. They come along at no cost.
- Bluetooth pairing keys are tied to the laptop's own adapter MAC, which isn't changing.
- NixOS manages none of the destinations. It leaves `/etc/NetworkManager/system-connections` alone, and `/var/lib/bluetooth` and `/var/lib/boltd` are just their services' `StateDirectory`.
- nixos-anywhere extracts with `--no-same-owner`, so the files land root-owned. NetworkManager requires that and ignores profiles owned by anyone else.

## 3. kexec probe

- [ ] **Turn celes's Wi-Fi off**, so the installer restores only the wired address (it re-applies the old system's addresses by MAC, and a dead `wlp3s0` route could win):
  ```bash
  ssh brian@10.0.1.85 nmcli radio wifi off
  ```
- [ ] Kexec only. This touches no disk:
  ```bash
  nix run github:nix-community/nixos-anywhere -- \
    --flake .#celes --phases kexec brian@10.0.1.85
  ```
- [ ] **If it reconnects** (`ssh root@10.0.1.85 true`), the dock survived the kexec; go to 4a.
- [ ] **If it does not**, at the laptop's console (log in as root if prompted): `echo 1 > /sys/bus/thunderbolt/devices/0-2/authorized`, then check `ip -br addr`. If the NIC still does not appear, power-cycle back into Arch and use 4b. Record which it was in the log.

## 4a. Install (wired)

- [ ] Partition, install and reboot from the running installer:
  ```bash
  nix run github:nix-community/nixos-anywhere -- \
    --flake .#celes \
    --extra-files ~/.local/share/celes-install \
    --phases disko,install,reboot \
    root@10.0.1.85
  ```
  The closure builds on liquidark and is copied over the dock's 2.5GbE; celes reboots on its own.

## 4b. Fallback: USB stick on Wi-Fi

Only if the dock's NIC cannot be brought up in the kexec installer.

- [x] Write a current NixOS ISO (<https://nixos.org/download/>) to a stick, checking the device with `lsblk` first: `sudo dd if=nixos-*.iso of=/dev/sdX bs=4M status=progress conv=fsync`.
- [x] Boot it: **Esc** at power-on opens the boot menu (F2 is BIOS setup). Secure Boot is already off.
- [x] At the installer's console:
  ```bash
  nmtui                                   # join noctropolis
  mkdir -p ~/.ssh && curl -s https://github.com/bcrescimanno.keys > ~/.ssh/authorized_keys
  ip -br addr show wlp3s0                 # note the address
  ```
- [x] Install. nixos-anywhere sees `VARIANT_ID=installer` and skips the kexec on its own:
  ```bash
  nix run github:nix-community/nixos-anywhere -- \
    --flake .#celes \
    --extra-files ~/.local/share/celes-install \
    nixos@<ip>
  ```
  Take the stick out once celes reboots.

## 5. First boot

- [x] Log in at SDDM with the password from `brian_password_hash`.
- [x] Wi-Fi: the radio comes up on (step 3 turned off Arch's radio, and that state is not carried), and `nmcli connection show --active` lists `noctropolis`.
- [x] Dock: `boltctl list` shows the CalDigit dock `authorized`, and `ip -br addr show enp100s0` has 10.0.1.85.
- [x] Bluetooth: `bluetoothctl devices Paired` lists the old pairings.
- [x] Secrets decrypted: `ls /run/secrets/` shows `attic_push_token` and `tailscale_auth_key`.
- [x] Tailscale: `tailscale status` shows celes. The install creates a new node, so if the Arch install was on the tailnet, remove its old node in the admin console.
- [x] On liquidark, forget the old SSH host key; the new system has a new one:
  ```bash
  ssh-keygen -R celes; ssh-keygen -R celes.home.theshire.io; ssh-keygen -R 10.0.1.214; ssh-keygen -R 10.0.1.85
  ```
- [ ] On liquidark, `rm -rf ~/.local/share/celes-install`. It holds celes's private age key and the Wi-Fi password.
- [x] `deploy celes` succeeds, which proves the deploy path works.

## 6. Post-install checks

Claude can do most of these over SSH. Ask once celes is up.

- [ ] **dGPU idle wakeups.** Measure twice, with Steam closed and with Steam open. Watch `/sys/bus/pci/devices/0000:01:00.0/power/runtime_status` and `runtime_active_time`. **Don't run `lspci` while measuring**, because it wakes the card. Then decide two things:
  - Should KWin be pinned to the iGPU with `KWIN_DRM_DEVICES`? That would cost HDMI, which is wired to the NVIDIA card.
  - Should Steam's menu entry drop `PrefersNonDefaultGPU`? With it, Plasma runs the Steam client itself on the 4070.
- [x] **dGPU for games.** A DXVK/Proton game should land on the 4070 with no offload command.
- [x] **Lighting.** `asusctl leds` and the Slash bar both respond.
- [x] **Charge limit.** `cat /sys/class/power_supply/BAT1/charge_control_end_threshold` reads 80.
- [x] **Power profiles.** In Plasma, under System Settings → Power Management, set Performance on AC and power-saver on battery. asusd's own profile switching is off.
- [x] **Charging.** On a USB-C PD charger, UPower reports AC. The nightly upgrade only runs on AC power.
- [x] **Keys.** Check the mic-mute key (works). Binding Fn+F5 (it does nothing until the desktop binds it) is **deferred**: see Follow-ups.
- [ ] **Lutris.** If you restore Lutris config, set the Wine runner's GPU option back to **Auto**. Arch had `gpu: card1`, and card numbers aren't stable.
- [ ] **Dotfiles cleanup.** Retire `machines/celes.nix` and rename `celes-nixos` to `celes`.

## Follow-ups

- [ ] **Bind Fn+F5.** Deferred on 2026-11-24. It does nothing until Plasma binds it; pick an action and bind it in System Settings → Shortcuts.
- [ ] **Laptop panel stays off after lid-open resume while docked.** Accepted for now on 2026-11-24, an upstream KWin race (looks like [KDE bug 515550](https://bugs.kde.org/show_bug.cgi?id=515550)). Recheck after each Plasma update. Recovery: close and reopen the lid, or over SSH `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus kscreen-doctor output.eDP-1.enable` (the socket is `wayland-1`, not `-0`). A resume hook running that was considered and rejected, because it would fight KWin's own output handling and undo a deliberate clamshell setup. See the Log, 2026-11-24 evening.

## Not carried over yet

These need deciding:
- qbt-tui and its sops activation
- Bambu Studio
- qsynth
- the macOS cursor theme
- backups for celes (no `backup.nix`)
- Tailscale client settings (it has the hosts' default role, `accept-dns=false`)

## Log

Note anything that went differently from the steps above, with the date.

### 2026-11-24 — installed from the USB stick (4b)

- **Section 3 skipped by choice.** Went straight to 4b. Whether the dock survives the kexec installer is still unknown.
- **Stick:** NixOS 26.05 graphical ISO (`nixos-graphical-26.05.15079.0dc498bfe49b`), SHA-256 verified. Pick the default boot menu entry; the graphical ISO boots into Plasma as `nixos`, so the console steps are done in Konsole (Wi-Fi via the panel applet or `nmtui`). It came up on 10.0.1.213, the same lease Arch's Wi-Fi had.
- **Carry-over refreshed from Arch** right before (same contents as 11-19/11-20: five Wi-Fi profiles, one Bluetooth pairing, the dock enrolment). The `sudo tar` half was run at celes's own keyboard instead of `ssh -t`. `key.txt` was checked against `&celes` in `.sops.yaml` (`age-keygen -y`) before the install.
- **Host keys:** liquidark had no entry for 10.0.1.85, so the Arch, installer and installed-system keys were each checked against `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` at the console. The live ISO makes a new key every boot, so a new key alone proves nothing.
- **Installed `main` at fb45845** (`nixos-system-celes-26.11.20261121.93a9ed0`, prebuilt on liquidark, so only the copy went over Wi-Fi). nixos-anywhere ran clean through disko → install → reboot.
- **Tailscale enrolment failed on first boot, a race:** on NetworkManager, `network-online.target` is just `nm-online -s`, which returned at 15:14:05 before Wi-Fi had an address, so `tailscaled-autoconnect` hit `lookup api.tailscale.com on [::1]:53: connection refused` and failed. (The tailscale module's ordering assumes dhcpcd's `wait = "ipv4"` gates network-online, which isn't true on an NM host.) `systemctl restart tailscaled-autoconnect` enrolled it. That's a one-off: once logged in, autoconnect only waits for Running. The node came up as plain `celes`, so no stale Arch node existed.
- **Dock NIC lost after Thunderbolt runtime PM.** boltd authorized the dock and `enp100s0` came up, but after a Thunderbolt link drop the dock re-authorized (`auto-auth: authorization successful`) with no NIC behind it. The USB4 PCIe hotplug root port `0000:00:03.1` was runtime-suspended and never saw the link. `echo on > /sys/bus/pci/devices/0000:00:03.1/power/control` brought it straight back (`pciehp: Card present / Link Up`, `enp100s0` got 10.0.1.85). Fix in a separate PR: a udev rule pinning the USB4 tunnel ports awake. Not `pcie_port_pm=off`, which would also hold the 4070's bridge awake.
- **power-profiles-daemon raced powerdevil:** the per-source Power Profile settings were missing from System Settings. PPD was only D-Bus-activated (the nixpkgs module ships the unit via `systemd.packages`, whose `WantedBy=` NixOS ignores) and came up in the same second as powerdevil. Restarting powerdevil showed them. It's now started at boot before SDDM (`hosts/celes.nix`).
- **The 4070 never sleeps: `Runtime D3 status: Not supported`** in `/proc/driver/nvidia/gpus/0000:01:00.0/power` (615.78.08 open), active 60/60 s idle with Steam closed. The modprobe options are applied (`NVreg_DynamicPowerManagement=0x02`), the MUX is hybrid (`gpu_mux_mode=1`, `dgpu_disable=0`), and the parent bridge `00:01.1` has ACPI `power_resources_D3hot`, so the cause is still unknown. KWin also holds `/dev/nvidia0` open (`card0`). Until RTD3 works, the `KWIN_DRM_DEVICES` / `PrefersNonDefaultGPU` decisions are moot. Open investigation.
- **asusd's `Unknown or invalid slash: "19b6"` is harmless:** `19b6` is the keyboard aura device, probed as a Slash candidate first. The Slash bar and aura both respond to asusctl.
- **dGPU for games: passes, by the inherited route (2026-11-24, after Steam was added in #1021).** FINAL FANTASY (Pixel Remaster) under Proton Experimental ran on the 4070 (`nvidia-smi`: C+G, 349 MiB, P0), with no offload command. But it carried `__NV_PRIME_RENDER_OFFLOAD=1` / `__VK_LAYER_NV_optimus=NVIDIA_only`, inherited from Steam, which Plasma launched via `PrefersNonDefaultGPU` (steamwebhelper is on the 4070 too, ~400 MiB). So DXVK's own discrete-first choice is **untested**. Re-test it with a game launched without the offload env before dropping `PrefersNonDefaultGPU`. That decision waits on RTD3 anyway.
- **Still open:** Lutris, dotfiles cleanup, and the deletion of `~/.local/share/celes-install` (Brian is doing that one).

### 2026-11-24 (evening) — dock, RTD3 and PPD fixes verified; first lid-close sleep

Celes cold-booted on `main` plus both open branches (the dock udev rule, and the nvidia-open RTD3 patch).

- **RTD3 fixed.** The cause was nvidia-open on Linux ≥7.3 ([NVIDIA/open-gpu-kernel-modules#1507](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1507)): the `nv-probe` kthread can no longer open the device's sysfs `config`, so RTD3 is silently disabled. The fix is upstream PR #1512, carried as `patches/nvidia-open-rtd3-kthread-nullfs.patch`. After the reboot:
  - `/proc/driver/nvidia/gpus/0000:01:00.0/power` reads `Runtime D3 status: Enabled (fine-grained)` and `Video Memory: Off`.
  - The 4070 stayed suspended for the full 60 s sample, and its bridge `00:01.1` was in D3cold, with KWin running and Steam closed. KWin holding `card0` therefore doesn't keep the card awake.
  - The `KWIN_DRM_DEVICES` / `PrefersNonDefaultGPU` decisions (section 6) are live again.
- **PPD cold-boot ordering holds.** power-profiles-daemon started at 16:18:34 and powerdevil at 16:18:52. The Power Profile settings are present.
- **Dock port pinned.** `0000:00:03.1` reads `power/control=on` from boot, and `enp100s0` had 10.0.1.85 at boot.
- **First lid-close sleep (18:23–22:07, docked to the LG UltraGear):**
  - Each suspend aborted once (`errno -16`: a wakeup event during the suspend) and powerdevil re-entered it immediately. Harmless.
  - **The Thunderbolt link dropped during sleep** (`0:2: failed to reach state TB_PORT_UP ... lost during suspend`). On resume the kernel removed the dock and re-added it within a second. igc's teardown printed `Trying to free already-free IRQ` and `disabling already-disabled device` warnings (harmless). boltd re-authorized the dock, then `pciehp: Slot(0-1): Card present / Link Up` with no manual wake, and `enp100s0` came back. **That exercised the dock fix's hotplug path, via resume rather than a cable pull.** A real replug is still worth doing once.
  - **The laptop panel never came back.** KWin re-enabled `eDP-1` on lid-open before it had the DRM device back (`drmModeListLessees() failed: Permission denied`, `Applying output configuration failed: EACCESS`) and never retried. The desktop, lock screen included, was only on the LG (`DP-5`), which was dark behind a burst of `DPIA AUX failed` errors. `kscreen-doctor output.eDP-1.enable` over SSH restored it. Accepted as an upstream race: see Follow-ups.
  - **`celes.home.theshire.io` resolves only to the dock NIC (10.0.1.85).** With the dock unplugged, reach celes on its Wi-Fi lease, 10.0.1.213.
