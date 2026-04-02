# Orthanc Setup Checklist

## 1. Fill in real secrets

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/orthanc.yaml
```

Set:
- `restic_password` — can reuse the same value as other hosts
- `restic_r2_env` — Cloudflare R2 credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)

## 2. Prepare the age key for nixos-anywhere

The private age key for orthanc's sops-nix must be uploaded during install:

```bash
mkdir -p /tmp/orthanc-extra/var/lib/sops-nix
echo "AGE-SECRET-KEY-1X3JLPUJAUEZ64CF32SEPQDGRXSJUU0C9PMW6F6ZUUDNKLSKRGEDQAXNN3Q" \
  > /tmp/orthanc-extra/var/lib/sops-nix/key.txt
chmod 600 /tmp/orthanc-extra/var/lib/sops-nix/key.txt
```

## 3. Boot orthanc from the installer USB

- BIOS: UEFI mode, Secure Boot off, USB first in boot order
- Find orthanc's IP in the UDM Pro DHCP leases after boot (hostname will be `nixos`)
- Verify SSH works: `ssh root@<ip>`

## 4. Run nixos-anywhere

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#orthanc \
  --extra-files /tmp/orthanc-extra \
  root@<orthanc-ip>
```

This will partition `/dev/nvme0n1`, install NixOS, and reboot.

## 5. First deploy after install

Once orthanc is up and reachable at `orthanc.home.theshire.io`:

```bash
deploy orthanc
```

## 6. Set up the Nix remote builder (one-time, after first deploy)

Generate a dedicated SSH key pair:

```bash
ssh-keygen -t ed25519 -f /tmp/nix-remote-builder -C nix-remote-builder
```

Add the **public key** to `hosts/orthanc.nix`:

```nix
users.users.nix-remote-builder.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA... nix-remote-builder"
];
```

Add the **private key** to each Pi's secrets file:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/pirateship.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/rivendell.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/mirkwood.yaml
```

Add this key to each file:
```yaml
nix_remote_builder_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

Deploy orthanc first (to activate the authorized key), then redeploy the Pis:

```bash
deploy orthanc
deploy
```

## 7. Clean up

Once orthanc is healthy and backups are confirmed working, delete this file.
