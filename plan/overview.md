# host-ipv4-access — Plan Overview

## Purpose and scope

Give a container created via `ai-sandbox instances create` (and via the normal
create/start path generally) a **supported, documented, stable way to reach a
host-side service by a fixed IPv4 address**, robust to Docker Desktop's shifting
`host.docker.internal` resolution behavior. The immediate downstream consumer is
Flow's flow-run-optimizer, which needs the in-container process to report
OpenTelemetry data to a host-side collector at `host.docker.internal:4318`.

**What must change:** add a caller-controlled IPv4-reachability mechanism (a
pass-through `--add-host <name>:<ip>` flag is the leading candidate) and document
it as the stable contract a downstream automation caller can build against.

**What must not change:** the existing default-deny firewall posture, the
macOS-first stance of host-side network-fact detection, and the config-input
model — new work must not regress or bypass the consent gate
(`running_config_matches()`), and must not blindly repeat the known
config-persistence gap tracked in followup `yS0R`.

**Success criteria:** a downstream caller has one documented way to pin a stable
IPv4 for a host service and reach it from inside an ai-sandbox container under
the normal create/start path; `docs/ai-sandbox-profiles-spec.md` and
`docs/architecture.md` describe it, including from the perspective of an
automation consumer.

## Current status

Planning is **blocked on scope decisions and one research gap** — this is a
multi-phase plan returned with `needs input`. The core deliverable
(Phase 1, the `--add-host` pass-through flag) is confident and its phase is
registered; the conditional Phase 2 (auto-inject an IPv4 host.docker.internal by
default + host-access hardening) is drafted but **not registered**, pending the
answers below. Task-level breakdown of both phases is deferred until the scope
questions and the Docker Desktop 4.82 networking research are resolved.

The regression was investigated empirically on the planning host (see
[investigation findings](./notes/investigation-findings.md)). Summary: the
"Docker no longer auto-injects host.docker.internal" part reproduces, but the
"`host-gateway` resolves IPv6-only / `getent ahostsv4` empty" part **does not
reproduce** on this identical-versioned host — `host-gateway` yields IPv4
`192.168.65.254` and `getent ahostsv4` returns it (exit 0) on Alpine and Ubuntu,
default and user-defined bridge. The reported failure is therefore
environment-variable, which is itself the strongest argument for a
caller-pinned IPv4 (option (a)) that does not depend on ai-sandbox solving
resolution.

## Overview

### Phase 1 — `add-host-passthrough` (registered; core deliverable, option (a))

Add a repeatable `--add-host <name>:<ip>` CLI flag (modeled on the existing
`--allow-egress` parsing precedent in `src/options.sh`) that threads
caller-supplied host→IPv4 entries into the container's `extra_hosts` (via the
generated compose override, `GENERATED_COMPOSE`), so a caller like Flow can pin a
stable IPv4 for `host.docker.internal` (or any name) without ai-sandbox needing
to solve host.docker.internal resolution at all. Includes: config-persistence
participation (subject to Q-U3), and documentation of the
name-resolution-vs-egress-allowance coupling (pinning a name does not by itself
grant egress under the default-deny firewall — the caller composes it with
`host-access` or `--allow-egress`; see the investigation findings). This phase's
mechanism is cross-platform by construction (caller supplies the IP; no
host-side detection).

### Phase 2 — `host-gateway-ipv4-default` (drafted, NOT registered; conditional, option (b))

Conditional on Q-U1/Q-U2/Q-U4 and the research below. Would (a) auto-detect a
host-side IPv4 for `host.docker.internal` and pin it via `extra_hosts` as a
literal by default — restoring pre-4.82 reachability without a caller flag — and
(b) harden `docker/init-firewall.sh`'s `host-access` capability so its current
silent log-and-skip on a missing IPv4 (line ~281) surfaces a visible warning.
Feasibility of the auto-detection hinges on the research gap (the Docker Desktop
gateway IPv4 is not the LAN IP `compute_lan_cidr()` yields — see investigation
findings §"Option (b) feasibility subtlety").

### Phase 3 — `doc-updates` (added at completion)

Per the architectural-implications check: update `docs/architecture.md` and
`docs/ai-sandbox-profiles-spec.md` to describe the chosen mechanism, including
the downstream-consumer contract. Registered only when the plan reaches
`complete`.

### Open decisions (user questions) and research

The following must be resolved before task decomposition; see the structured
report's `user_questions` and `research_requests` for the exact items:

- **Q-U1** direction: option (a) alone in V1, or (a) + (b)?
- **Q-U2** host-access scope: harden its silent-fail (and/or reroute its
  resolution) in this plan, or defer to a followup? (Not reproducibly broken
  here; plausibly broken downstream.)
- **Q-U3** config-persistence: does the new flag join the full triad
  (env + `ai.sandbox.<field>` label + `running_config_matches()` + the
  `ai.sandbox.config` JSON), per the `--allow-egress` precedent and NOT
  repeating followup `yS0R`'s gap?
- **Q-U4** platform: option (a) is cross-platform by construction; should
  option (b)'s host-side detection be macOS-only for V1 (consistent with
  `compute_lan_cidr()` and followup `uL4v`) or cross-platform?
- **Research** ([docker-desktop-4.82-networking.md](./notes/docker-desktop-4.82-networking.md)):
  root cause of the downstream IPv6-only/empty-`ahostsv4` divergence, and
  whether a reliable host-side detector of the Docker Desktop gateway IPv4
  exists (feasibility of option (b1)).
