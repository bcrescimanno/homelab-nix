# Build & Deploy Streamlining Proposals

Proposals to address fragility in the current build / cache / deploy / auto-upgrade pipeline. Ordered roughly by leverage (impact ÷ effort), with rationale grounded in the concrete failure modes each addresses.

---

## 1. ✅ Stagger auto-upgrade timers per host

**Current state.** `modules/base.nix` schedules `homelab-upgrade.timer` at `OnCalendar=04:00` with `RandomizedDelaySec=15m` on every host. All four hosts upgrade in the same 15-minute window with no coordination.

**Why it matters.** When the closure on `main` isn't already in attic (e.g. a direct push to `main`, or a `flake.lock` change that the pre-build runners haven't completed yet), four hosts simultaneously hit attic for store paths that don't exist, then independently rebuild the same closures on their own CPUs. The 4GB Pis (mirkwood, pirateship) are particularly bad candidates for parallel kernel builds.

**Proposal.** Replace the single 04:00 timer with explicit offsets keyed off `config.networking.hostName`:

| Host | Time |
|---|---|
| `orthanc` | 04:00 (warms cache for the rest) |
| `mirkwood` | 04:20 |
| `rivendell` | 04:40 |
| `pirateship` | 05:00 |

The first host to upgrade primes attic for everything that follows. Drop `RandomizedDelaySec` to a small value (e.g. `2m`) — it's there to avoid GitHub rate limiting, not contention with peer hosts.

**Cost.** ~10 lines in `base.nix`, one `lib.attrByPath` lookup keyed on hostname.

---

## 2. ✅ Trigger `pre-build.yml` on push to main, not just PRs

**Current state.** `.github/workflows/pre-build.yml` runs only on `pull_request` events touching `flake.lock`. `check.yml` runs on push to main but only does `nix flake check --no-build`.

**Why it matters.** Any path that lands a closure-changing commit on `main` *without going through a `flake.lock` PR* leaves attic cold:
- Direct commits to main (rare but happens — see recent `5cfb95d`, `6516dca`).
- PRs that change `*.nix` modules without touching `flake.lock`.
- Renovate container-digest PRs that auto-merge without invoking the pre-build runners (current Renovate config only schedules nix flake updates on Saturdays — but the regex digest manager fires anytime).

When auto-upgrade fires at 04:00, every host independently rebuilds.

**Proposal.** Add a `push: branches: [main]` trigger to `pre-build.yml` with `paths` filtered to `flake.lock` + `**/*.nix` + `flake.nix`. The job is idempotent — if the closure is already in attic it short-circuits. Worst case it runs once per merge, which is what we want.

**Cost.** 4 lines of YAML.

---

## 3. ✅ Either finish or remove the remote-builder-client wiring

**Current state.** `hosts/orthanc.nix` declares the `nix-remote-builder` SSH user with `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`. `MEMORY.md` notes that the `nix_remote_builder_key` private key is in every Pi's sops secrets. But **no `nix.buildMachines` block exists anywhere in the repo**, and `modules/base.nix` sets `max-jobs = 4` (the comment explains: "Build locally on all hosts — heavy aarch64 artifacts are pre-built by the rivendell CI runner").

This is a half-removed feature. The server side is configured; the client side isn't.

**Why it matters.** The current architecture works *only* if the cache is always warm. Proposal 2 closes most of that gap, but cache misses still happen (attic GC, atticd downtime, key rotation, network blip during push). Today, a cache miss on a 4GB Pi means a kernel build on a 4GB Pi.

**Proposal.** Pick one:

**Option A — finish it.** Add a `modules/remote-builder-client.nix`:

```nix
nix.buildMachines = [{
  hostName = "orthanc.home.theshire.io";
  systems = [ "aarch64-linux" "x86_64-linux" ];
  sshUser = "nix-remote-builder";
  sshKey = config.sops.secrets.nix_remote_builder_key.path;
  maxJobs = 16;
  speedFactor = 4;
  supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
}];
nix.distributedBuilds = true;
nix.settings.builders-use-substitutes = true;
```

Set `max-jobs = 0` on Pis (per-host, not in `base.nix`). Cache miss now flows: Pi → attic miss → orthanc builds → orthanc pushes to attic → Pi pulls. Pis stop building anything heavy.

**Option B — remove it.** Delete the `nix-remote-builder` user from `orthanc.nix`, drop `boot.binfmt.emulatedSystems`, remove the `nix_remote_builder_key` secret from all four sops files. Smaller attack surface, less drift.

**Recommendation:** Option A. The pre-build runner on rivendell already does what orthanc-as-builder would do for *predicted* builds; orthanc-as-builder catches the *unpredicted* ones (and lets you run `deploy <host>` from a laptop without it cross-compiling).

**Cost.** ~30 lines for option A, an afternoon to verify activation paths. Option B is purely deletion.

---

## 4. ✅ Active health check for the attic cache

**Current state.** `scripts/validate` checks `http://orthanc:8080` returns 200/400/404. `modules/base.nix` post-build hook prints `attic-push: push failed for $path (non-fatal)` to stderr and continues. There's no monitoring beyond that.

**Why it matters.** Silent cache failures are the worst class of failure here — the system keeps working, slowly, and you only notice when an upgrade takes 40 minutes instead of 4. JWT expiry, signing-key mismatch in `extra-trusted-public-keys`, atticd OOM, Caddy upstream failure, and DNS issues all manifest as silent cache misses.

**Proposal.** Two complementary checks:

1. **Functional probe in Gatus** (rivendell): an HTTPS check on `https://cache.theshire.io/nixpkgs/nix-cache-info` that asserts the response contains the expected `StoreDir: /nix/store` and a known signing key prefix. ntfy alert if the body changes or status drifts.
2. **Push success counter on each host.** Wrap the post-build hook to increment a per-host counter (e.g. `/var/lib/attic-push/{success,failure}.count`), exposed via Prometheus node_exporter textfile collector. Grafana panel + alert on `failure_rate > 5%` over 1h.

**Cost.** ~20 lines in `gatus.nix`, ~15 lines added to the post-build hook + a textfile collector path in `monitoring.nix`. Optional Grafana panel.

---

## 5. ✅ Bump attic GC retention to 6–8 weeks

**Current state.** `modules/attic.nix` sets `default-retention-period = "2 weeks"`.

**Why it matters.** Storage on orthanc's NVMe is not constrained — the entire homelab closure is small in cache terms. Two weeks means any host that doesn't deploy for two weeks rebuilds from scratch. With Renovate-driven Saturday cadence + occasional skipped weeks (travel, holidays), this triggers more often than expected. The cost of recompiling a kernel on a 4GB Pi is much higher than the cost of an extra few GB of cache.

**Proposal.** Set retention to `6 weeks` (or `8 weeks`). Reassess if storage becomes a real constraint (it won't soon).

**Cost.** One line.

---

## 6. ✅ Hoist the SSH key to one place

**Current state.** The `ssh-ed25519 AAAAC3...` Brian SSH key appears in three places:
- `flake.nix:43` (`brianSshKey` let binding, used only by `orthanc-installer`)
- `modules/base.nix:29` (the `users.users.brian.openssh.authorizedKeys.keys` list)
- `hosts/orthanc.nix:142` is a *different* key — the `nix-remote-builder` key — which is fine; but the duplication of the brian key is the issue.

**Why it matters.** Key rotation requires editing in two places (with a third nearby that's unrelated and easy to confuse). Easy to miss one.

**Proposal.** Define `brianSshKey` once in `flake.nix`, pass it through `specialArgs`, consume it in `base.nix`. Same for the orthanc-installer.

**Cost.** ~5 line refactor.

---

## 7. ✅ Consolidate overlays

**Current state.** `flake.nix` has two `nixpkgs.overlays` declarations:
- `piModules` injects `[ glancesOverlay prometheusOverlay ]`
- The orthanc config injects `[ glancesOverlay ]` only

**Why it matters.** The next overlay added has to be added in two places, and it's easy to miss the orthanc one (the Pi configs are visually close, orthanc is at the bottom). The `prometheusOverlay` itself is currently aarch64-only because of where it's wired — if x86 ever needs it, you have to remember.

**Proposal.** Extract a `commonOverlays = [ glancesOverlay ]` and a `piOverlays = commonOverlays ++ [ prometheusOverlay ]` and use them by name. Or, if you prefer a single overlay set, just put `prometheusOverlay` in common — it's a no-op on x86.

**Cost.** ~5 lines.

---

## 8. ✅ Move the post-build hook script out of `base.nix`

**Current state.** `modules/base.nix:223-247` contains a 25-line embedded shell script (the attic post-build hook) inside `pkgs.writeShellScript`. It's the most operationally critical piece of code in `base.nix` and the hardest to read because it's nested inside a string in a Nix expression.

**Why it matters.** This script is load-bearing for the entire caching story. It contains a workaround for an upstream bug (serial pushes), a JWT validity check, a temp-HOME ritual to avoid polluting `/root/.config`, and silent failure semantics. When (not if) it breaks, debugging a 25-line bash script wedged inside a Nix string at line 223 of `base.nix` is unpleasant.

**Proposal.** Move to `modules/attic-push.nix`. Imports stay clean (`base.nix` imports it explicitly). The script is in its own file, version-controllable, lintable with shellcheck. Adds zero runtime change — purely organizational.

**Cost.** Pure code move, ~5 minutes.

---

## 9. ✅ Generalize `scripts/merge-renovate`

**Current state.** The script hardcodes `BRANCH="renovate/lock-file-maintenance"`. It can only handle the Saturday lockfile maintenance PR. Other Renovate PRs (nix input updates, container digest updates that *don't* automerge for some reason) get the manual treatment — `git checkout`, `nix flake check`, `deploy`, `validate`, `gh pr merge` by hand.

**Why it matters.** The script captures real institutional knowledge (cache priming order, EPP boost on orthanc, settle delay, validate-before-merge gating). That knowledge applies to *any* Renovate PR, not just lockfile maintenance.

**Proposal.** Parameterize:

```bash
scripts/merge-renovate                    # default: lock-file-maintenance (today's behavior)
scripts/merge-renovate --pr 123           # any PR number
scripts/merge-renovate --branch <name>    # any branch
```

Keep the cleanup trap, EPP handling, and validate gate. Most of the script stays as-is.

**Cost.** ~20 lines of arg parsing + a `gh pr view` lookup to map PR → branch.

---

## 10. Add post-upgrade validation to `homelab-upgrade.service`

**Current state.** `homelab-upgrade.service` runs `nixos-rebuild switch`. On success/failure it pings ntfy. "Success" here means the rebuild script returned 0 — not that services are healthy.

**Why it matters.** A rebuild can succeed and still leave services broken (e.g. a config that activates but crashes on first request, a container that exits 0 then restart-loops, a backend that fails health checks). Today these only surface on the next manual `validate` run or when something fails to alert downstream.

**Proposal.** Add a post-activation health check service in the `OnSuccess` chain that runs a host-local subset of `scripts/validate` (skipping cross-host checks). On failure, ntfy with priority 4. Keep it short (10s ceiling) so it doesn't hold the upgrade timer.

**Cost.** ~30 lines: a small bash script that hits `127.0.0.1` for the services declared on this host, plus the unit wiring.

---

## 11. ✅ Helper for the dynamic-user / sops pattern

**Current state.** Three services in this repo (`atticd`, `cloudflared`, `services.github-runners.*`) need static `users.users.x = { isSystemUser = true; group = "x"; }; users.groups.x = {};` declarations *only because* sops-nix needs to resolve the owner at eval time and `DynamicUser=true` services don't surface their user in `config.users.users`. This is documented in `MEMORY.md` and as comments in each module, but the pattern is easy to forget.

**Why it matters.** The next service that uses `DynamicUser=true` and a sops secret will fail eval with an opaque error. Future-Brian (and future-Claude) will have to rediscover this each time.

**Proposal.** Add a `lib/homelab.nix` with one helper:

```nix
mkDynamicUser = name: {
  users.users.${name} = { isSystemUser = true; group = name; };
  users.groups.${name} = {};
};
```

Consume as `imports = [ (lib.homelab.mkDynamicUser "atticd") ];`. Optional refinement: have the helper take a list.

**Cost.** ~10 lines + three call-site simplifications.

---

## 12. ✅ Delete the stale `homelab-upgrade-orchestrator` comment

**Current state.** `modules/base.nix:97-103` references a `homelab-upgrade-orchestrator` "declared in `hosts/mirkwood.nix`" that orchestrates upgrades across hosts via SSH. **No such service exists in the repo.** Each host upgrades independently via its own timer.

**Why it matters.** The comment is actively misleading. Anyone reading `base.nix` to understand the upgrade flow will look for the orchestrator and not find it — or worse, assume it exists somewhere they haven't looked yet and make decisions based on it.

**Proposal.** Replace the comment with an accurate description: "Each host upgrades independently via its own timer. Stagger is configured below." (Especially natural to do alongside Proposal 1.)

**Cost.** Trivial.

---

## Summary table

| # | Proposal | Effort | Risk | Closes which failure mode |
|---|---|---|---|---|
| 1 | Stagger upgrade timers | XS | Low | Concurrent rebuilds, attic contention |
| 2 | Pre-build on push to main | XS | Low | Cold cache after main commits |
| 3 | Wire (or remove) remote builder | M | Med | Cache-miss → Pi rebuild |
| 4 | Cache health probe | S | Low | Silent push/fetch failures |
| 5 | Bump GC retention | XS | Low | Cold cache after a skipped week |
| 6 | Single-source SSH key | XS | Low | Drift on rotation |
| 7 | Consolidate overlays | XS | Low | Forgotten overlay on new host |
| 8 | Hook to its own file | XS | None | Maintainability |
| 9 | Generalize merge-renovate | S | Low | Manual toil on non-lockfile PRs |
| 10 | Post-upgrade validation | S | Low | Silent service breakage |
| 11 | Dynamic-user helper | XS | Low | Future eval errors |
| 12 | Delete stale comment | XS | None | Misleading documentation |

Highest combined leverage: **1, 2, 3A, 4** — together they make a cache miss during auto-upgrade essentially impossible, give you alerting when the cache misbehaves, and stop relying on a 4GB Pi to compile a kernel.
