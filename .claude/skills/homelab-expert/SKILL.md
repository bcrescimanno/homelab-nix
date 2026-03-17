---
name: homelab-expert
description: This skill should be used when the user is asking for help designing, planning, or solving a problem in their homelab — e.g. "how should I...", "I want to add...", "what's the best way to...", "help me set up...", "I'm thinking about...". Activates problem-framing, solution evaluation, and research workflows for homelab decisions.
version: 1.0.0
---

# Homelab Expert

This skill guides homelab problem-solving through three sequential phases: framing, evaluation, and research. Work through them in order — never jump to solutions before the problem is well-understood.

## Phase 1: Frame the Problem

Before proposing anything, verify you understand what the user actually wants to achieve — not just what they asked for literally.

Ask clarifying questions if any of the following are unclear:

- **Goal**: What outcome are they trying to achieve? (e.g. "expose a service externally" vs. "monitor uptime" vs. "automate a task")
- **Scope**: Which host(s) or services are involved?
- **Constraints**: Any hardware limits, network topology requirements, or integration dependencies?
- **Trigger**: What prompted this — a new device, a broken workflow, a capability gap?
- **Prior attempts**: Have they already tried something that didn't work?

Do not proceed to Phase 2 until you can state the problem clearly in one or two sentences and the user has confirmed it.

## Phase 2: Evaluate Known Solutions

Once the problem is framed, survey solutions that fit the homelab's existing stack (from the `homelab-context` skill). Evaluate options against these criteria, in priority order:

1. **Declarative first**: Does a `services.*` NixOS module exist in nixpkgs? Prefer it over containers.
2. **Fits the existing stack**: Does it integrate naturally with Caddy (reverse proxy), Blocky+Unbound (DNS), sops-nix (secrets), deploy-rs (deployments), ntfy (alerts), Gatus (monitoring), Prometheus+Grafana (metrics)?
3. **Host fit**: Which host is the right home for this — rivendell (HA, networking, proxy), mirkwood (DNS primary, dashboards, metrics), pirateship (media)?
4. **Operational cost**: How much imperative setup (web UI config, manual steps, restore scripts) does it require? Less is better.
5. **Resource fit**: Does it fit within the target Pi's RAM/CPU budget?

Present options as a ranked list with a brief rationale for each. Be explicit about trade-offs. If one option is clearly best, say so and explain why.

## Phase 3: Research and Propose

If no known solution fits well, conduct research before proposing anything. When doing so:

- Search nixpkgs for available modules and packages
- Check whether the service supports config-file-based configuration (not just a web UI)
- Look for community NixOS examples or home-manager modules

**Always clearly label research-based proposals as new ideas** — use language like:
> "This is a new approach I haven't seen in your stack before — here's how it could work:"

Include:
- What the solution is and why it's a good fit
- How it would integrate with the existing stack
- Any unknowns or risks that would need validation
- Whether a proof-of-concept step makes sense before full implementation

## Ground Rules

- Never propose hardcoding secrets in Nix files.
- Never propose solutions that require significant imperative setup unless there is no declarative alternative and the trade-off is explicitly acknowledged.
- When proposing changes to existing modules, read the relevant file(s) first — don't suggest modifications to code you haven't seen.
- If a proposal touches multiple hosts or modules, call out the deployment order and any sequencing dependencies.
