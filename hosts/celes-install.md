# celes install checklist

Moving celes (ASUS Zephyrus G14 2024, GA403UI) from Arch + Hyprland to NixOS + Plasma 6. The config is `hosts/celes.nix`, merged in #874. Tick the boxes as you go, and note anything that went differently in the log at the end.

**This wipes celes's only disk.** Nothing in `/home` survives.

## Why a USB stick

terra was installed with nixos-anywhere's usual path: it kexecs the running system into an in-RAM installer. That installer only brings up wired networking. nixos-anywhere's `docs/requirements.md` says "nixos-anywhere does not support wifi networks", and the G14 has no Ethernet port.

So celes boots a real NixOS installer ISO, joins Wi-Fi there, and nixos-anywhere targets that. nixos-anywhere sees `VARIANT_ID=installer` in `/etc/os-release` and skips the kexec on its own, so no `--phases` flag is needed.

## Already done

- [x] Config merged: `hosts/celes.nix`, the deploy node, and `secrets/celes.yaml` (#874, #876).
- [x] dotfiles profile `machines/celes-nixos.nix` merged (bcrescimanno/dotfiles#3).
- [x] Login password hash set in `secrets/celes.yaml` (`brian_password_hash`, a yescrypt hash). If it were missing, activation would fail and nothing could log in at the console.
- [x] The host age key is in the extra-files tree on liquidark, already at its target path: `~/.local/share/celes-install/var/lib/sops-nix/key.txt`. Its public half is `&celes` in `.sops.yaml`.
- [x] That tree's `var/` and `var/lib/` are 0755. `--extra-files` copies modes as they are (`tar -p`), so a 0700 there would become `/var/lib`'s mode on celes.

## 1. Prepare

- [ ] **Find a USB stick** (any size over about 2 GB).
- [ ] Download a current NixOS ISO from <https://nixos.org/download/>. Minimal or graphical both work: every installer ISO runs NetworkManager and sshd, and its `nixos` user has passwordless sudo.
- [ ] Write it to the stick. Check the device with `lsblk` first, because `dd` overwrites whatever it is pointed at:
  ```bash
  sudo dd if=nixos-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
  ```

## 2. While celes is still on Arch

Do these as close to the wipe as you can, so nothing created in between is lost.

- [ ] **Back up `~`.** Anything not in a git repo or in Bitwarden is gone after the install.
- [ ] **Carry over the Wi-Fi profiles and Bluetooth pairings.** Arch's sudo wants a password, so `ssh -t`. A tty mangles binary output, so the tar goes through a file. Both copies hold the Wi-Fi password, so the last line deletes them.
  ```bash
  ssh -t brian@celes 'sudo tar -C / -cf /tmp/carry.tar etc/NetworkManager/system-connections var/lib/bluetooth && sudo chown brian /tmp/carry.tar'
  scp brian@celes:/tmp/carry.tar /tmp/ \
    && tar -C ~/.local/share/celes-install -xpf /tmp/carry.tar \
    && rm /tmp/carry.tar && ssh brian@celes rm /tmp/carry.tar
  ```
- [ ] **Check the tree.** Profiles in `etc/NetworkManager/system-connections/` should be `-rw-------`, `var/lib/bluetooth` should be `drwx------`, and `var` and `var/lib` should still be `drwxr-xr-x`.
  ```bash
  find ~/.local/share/celes-install -printf '%M %p\n'
  ```

What carries over, as checked on 2026-10-13:
- `noctropolis` is WPA3 (SAE) with `psk-flags=0`, so the password is stored in the profile file and not in a keyring. The profile is pinned to `wlp3s0`, and NixOS uses the same predictable naming.
- The three hotel profiles are open networks. They come along at no cost.
- Bluetooth pairing keys are tied to the laptop's own adapter MAC, which isn't changing.
- NixOS manages neither destination. It leaves `/etc/NetworkManager/system-connections` alone, and `/var/lib/bluetooth` is just bluetooth.service's `StateDirectory`.
- nixos-anywhere extracts with `--no-same-owner`, so the files land root-owned. NetworkManager requires that and ignores profiles owned by anyone else.

## 3. Boot the installer

- [ ] Plug in the stick and power on celes. **Esc** at power-on opens the boot menu (F2 is BIOS setup). Secure Boot is already off.
- [ ] At the installer's console:
  ```bash
  nmtui                                   # join noctropolis
  mkdir -p ~/.ssh && curl -s https://github.com/bcrescimanno.keys > ~/.ssh/authorized_keys
  ip -br addr show wlp3s0                 # note the address
  ```
  Your GitHub key list includes the key every host already trusts (`…eRzbHUv/0P2W`), so liquidark can log in.
- [ ] From liquidark, confirm you can log in: `ssh nixos@<ip> true`.

## 4. Install

- [ ] Unlock Bitwarden first, because the SSH key lives there. Then, from `~/code/homelab-nix` on an up-to-date `main`:
  ```bash
  nix run github:nix-community/nixos-anywhere -- \
    --flake .#celes \
    --extra-files ~/.local/share/celes-install \
    nixos@<ip>
  ```
  Use the address from step 3, not `celes.home.theshire.io`: the installer boots under a different hostname. The closure builds on liquidark (it has built it before, so most of it is cached), gets copied to celes over Wi-Fi, and celes reboots on its own. Take the stick out once it does.

## 5. First boot

- [ ] Log in at SDDM with the password from `brian_password_hash`.
- [ ] Wi-Fi: `nmcli connection show --active` lists `noctropolis`.
- [ ] Bluetooth: `bluetoothctl devices Paired` lists the old pairings.
- [ ] Secrets decrypted: `ls /run/secrets/` shows `attic_push_token` and `tailscale_auth_key`.
- [ ] Tailscale: `tailscale status` shows celes. The install creates a new node, so if the Arch install was on the tailnet, remove its old node in the admin console.
- [ ] On liquidark, forget the old SSH host key; the new system has a new one:
  ```bash
  ssh-keygen -R celes; ssh-keygen -R celes.home.theshire.io; ssh-keygen -R 10.0.1.214
  ```
- [ ] On liquidark, `rm -rf ~/.local/share/celes-install`. It holds celes's private age key and the Wi-Fi password.
- [ ] `deploy celes` succeeds, which proves the deploy path works.

## 6. Post-install checks

Claude can do most of these over SSH. Ask once celes is up.

- [ ] **dGPU idle wakeups.** Measure twice, with Steam closed and with Steam open. Watch `/sys/bus/pci/devices/0000:01:00.0/power/runtime_status` and `runtime_active_time`. **Don't run `lspci` while measuring**, because it wakes the card. Then decide two things:
  - Should KWin be pinned to the iGPU with `KWIN_DRM_DEVICES`? That would cost HDMI, which is wired to the NVIDIA card.
  - Should Steam's menu entry drop `PrefersNonDefaultGPU`? With it, Plasma runs the Steam client itself on the 4070.
- [ ] **dGPU for games.** A DXVK/Proton game should land on the 4070 with no offload command.
- [ ] **Lighting.** `asusctl leds` and the Slash bar both respond.
- [ ] **Charge limit.** `cat /sys/class/power_supply/BAT1/charge_control_end_threshold` reads 80.
- [ ] **Power profiles.** In Plasma, under System Settings → Power Management, set Performance on AC and power-saver on battery. asusd's own profile switching is off.
- [ ] **Charging.** On a USB-C PD charger, UPower reports AC. The nightly upgrade only runs on AC power.
- [ ] **Keys.** Check the mic-mute key, and bind Fn+F5 (it does nothing until the desktop binds it).
- [ ] **Lutris.** If you restore Lutris config, set the Wine runner's GPU option back to **Auto**. Arch had `gpu: card1`, and card numbers aren't stable.
- [ ] **Dotfiles cleanup.** Retire `machines/celes.nix` and rename `celes-nixos` to `celes`.

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
