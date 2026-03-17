---
name: deploy-and-test-agent
description: This skill should be used when an agent is instructed to deploy a host configuration and verify or test the result. Covers the full workflow: pre-deployment review, deployment execution, activation verification, and functional testing of the specific changes made. Rollback is handled automatically by deploy-rs and is not the agent's responsibility.
version: 1.0.0
---

# Deploy and Test Agent

This skill governs the full deploy-verify-test workflow for homelab NixOS hosts. Work through each phase in order. Do not skip phases.

## Permissions Model

These rules apply to all actions taken on target hosts via SSH:

| Action | Permission required? |
|---|---|
| Read systemd journal (`journalctl`) | No — freely allowed |
| Read service status (`systemctl status`) | No — freely allowed |
| Read log files under `/var/log/` | No — freely allowed |
| Read any other file on the target host | **Ask the user first** |
| Write any file on the target host | **Ask the user first** |
| Run commands that modify system state on the target | **Ask the user first** |

When asking permission, state the full path and the reason you need it before proceeding.

---

## Phase 1: Pre-Deployment Review

Before deploying, establish a clear baseline.

1. **Identify what changed**: Read the relevant module(s) and host config in the local repo to understand exactly what is being deployed. Do not deploy blind.
2. **State the expected outcome**: Write a one-sentence summary of what the change is supposed to do. This becomes the acceptance criterion for Phase 4.
3. **Identify affected services**: List every systemd service, container, or network interface that the change touches on the target host.
4. **Capture pre-deployment state** (via SSH):
   - For each affected service: `systemctl is-active <service>` and `systemctl is-failed <service>`
   - For network-dependent changes: capture relevant listening ports or interface state
   - Note any services that are already degraded before deployment — do not count pre-existing failures against the deployment

---

## Phase 2: Deploy

Run the deployment using the `deploy` shell function:

```bash
deploy <hostname>
```

Where `<hostname>` is one of: `pirateship`, `rivendell`, `mirkwood`.

**Important**: `deploy` is a zsh shell function and is only available in interactive zsh sessions — it will not be present in non-interactive shells or subprocesses. Always invoke deploy-rs using the exact command below, which is what the `deploy` function does internally:

```bash
# Deploy a specific host:
nix run github:serokell/deploy-rs -- ~/code/homelab-nix#<hostname>

# Deploy all hosts:
nix run github:serokell/deploy-rs -- ~/code/homelab-nix
```

The flake is configured with `remoteBuild = true` — the build runs on the target Pi, not locally. This is required because the Pis are aarch64 and the local machine is x86_64. Do not add `--remote-build` or other flags; the flake already encodes the correct settings.

**deploy-rs behavior to know:**
- Build output will stream from the remote Pi; this is normal and expected
- `magicRollback = true` — if SSH is lost during activation, the host rolls back automatically
- `autoRollback = true` — if the activation script exits non-zero, the host rolls back automatically
- A successful deploy exits 0 and prints confirmation; a rolled-back deploy will show the rollback in output

**If deploy-rs rolls back**: Report the rollback to the user with the relevant error output. Do not attempt to re-deploy or work around the rollback. Stop and wait for user instructions.

**If deploy-rs is genuinely unavailable**, fall back to:
```bash
nixos-rebuild switch --flake .#<host> --target-host brian@<host> --build-host brian@<host> --sudo
```

---

## Phase 3: Activation Verification

Verify the new configuration is live before running functional tests.

1. **Confirm the generation switched**:
   ```bash
   ssh brian@<host> -- sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -3
   ```
2. **Check affected services started cleanly**:
   ```bash
   ssh brian@<host> -- systemctl is-active <service>
   ssh brian@<host> -- systemctl status <service> --no-pager -n 50
   ```
3. **Scan the journal for errors since activation**:
   ```bash
   ssh brian@<host> -- journalctl -b -p err --no-pager -n 100
   ```
4. **Verify no services entered failed state**:
   ```bash
   ssh brian@<host> -- systemctl --failed --no-pager
   ```

If any affected service failed to start or logged critical errors during activation, report the full relevant journal output to the user before proceeding to Phase 4. Do not proceed to functional testing if the service is not running.

---

## Phase 4: Functional Testing

Test the specific change against the acceptance criterion established in Phase 1. The tests here are specific to the type of change — use judgement based on what was deployed.

### Service / container changes
- Confirm the service responds on its expected port: `curl -sf http://localhost:<port>/` or equivalent
- If the service has a health endpoint, check it
- If the service is proxied via Caddy, verify the vhost responds (from the host itself if external access isn't available)

### DNS changes (dns.nix)
- Test resolution from the host: `ssh brian@<host> -- dig @127.0.0.1 <test-domain>`
- Test DoH if applicable: `curl -sf 'http://localhost:4000/dns-query?name=<test-domain>'`
- Verify Blocky metrics endpoint: `curl -sf http://localhost:4000/metrics | grep blocky_`

### Caddy / reverse proxy changes (caddy.nix)
- Verify TLS certificate is valid: `curl -svf https://<vhost>.theshire.io 2>&1 | grep -E 'SSL|issuer|expire'`
- Confirm the correct backend is being proxied (check response headers or body)

### Networking / VLAN / firewall changes
- Verify connectivity where expected: `ssh brian@<host> -- ping -c3 <target-ip>`
- Verify isolation where expected: confirm blocked traffic is still blocked if that was the intent

### NUT / UPS changes (nut.nix)
- Check UPS status: `ssh brian@rivendell -- upsc <ups-name>`
- Verify upsmon is running and connected

### Secrets changes (sops-nix)
- Confirm the secret rendered: `ssh brian@<host> -- sudo ls -la /run/secrets/<secret-name>`
- Do not read the secret contents without user permission

### Backup changes (backup.nix)
- Check that the restic service/timer is active: `systemctl status restic-backups-*`

---

## Phase 5: Report

Summarize the outcome for the user:

1. **Deployment**: succeeded / rolled back (with reason)
2. **Activation**: all affected services started cleanly / issues found (with details)
3. **Functional tests**: pass / fail for each test run, with specific output
4. **Acceptance criterion**: met / not met — reference the one-sentence statement from Phase 1
5. **Any anomalies**: pre-existing issues noted in Phase 1 baseline, unexpected log entries, services that were already degraded

If any phase failed, stop at that phase and present findings to the user before taking further action.
