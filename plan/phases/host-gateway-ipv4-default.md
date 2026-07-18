# Phase: host-gateway-ipv4-default (conditional — not yet registered)

> **Status:** proposed, pending Q-U1/Q-U2/Q-U4 and the Docker Desktop 4.82
> networking research. Not registered in `plan/TODO.yaml`. Registered on
> re-invocation only if the answers keep it in scope; its precise shape depends
> on those answers and may reduce to the host-access-hardening core alone.

## Goals

Restore reliable default host reachability (no caller flag required) by
auto-injecting an IPv4-resolving `host.docker.internal`, and make the
`host-access` capability fail loudly instead of silently when host.docker.internal
yields no IPv4. This complements Phase 1 for the common case where a caller does
not (or cannot) pin an address itself.

Two components, separable by decision:

1. **Auto-inject an IPv4 `host.docker.internal` by default** (option (b)) —
   detect a host-side IPv4 and pin `host.docker.internal` to it as a literal via
   `extra_hosts`, instead of the bare `host-gateway` keyword, whenever the keyword
   is what produces IPv6-only resolution on a given host. Feasibility is gated on
   research: the Docker Desktop gateway IPv4 (`192.168.65.254`) is **not** the
   host LAN IP that `compute_lan_cidr()` yields, so the detector cannot simply
   reuse that mechanism (see
   [investigation findings](../notes/investigation-findings.md) §"Option (b)
   feasibility subtlety" for the (b1)/(b2) split).
2. **Harden `host-access`'s silent fail-soft** — `docker/init-firewall.sh`
   line ~281 currently logs to the firewall-init sidecar and skips when
   `getent ahostsv4 host.docker.internal` returns nothing, so `host-access`
   silently allow-lists nothing with no operator-visible signal. This component
   is valuable regardless of the option-(b) decision (it improves diagnosability
   of exactly the downstream failure), and could stand alone if (b) is descoped.

## Inputs

- **Research findings** — [docker-desktop-4.82-networking.md](../notes/docker-desktop-4.82-networking.md):
  root cause of the downstream IPv6-only behavior and whether a reliable
  host-side Docker-gateway-IPv4 detector exists. Blocks component 1.
- **Host-side detection precedent** — `src/utils.sh` `compute_lan_cidr()`
  (lines 422-455) and `src/index.sh`'s host-access `lsof` enumeration
  (lines 551-573): macOS-first, best-effort, warn-and-empty degrade pattern any
  new detector must follow, exported through the existing `AI_SANDBOX_*`
  env-passthrough (per `docs/architecture.md` §309-327).
- **host-access capability** — `docker/init-firewall.sh` lines 211-283, whose
  inline comment (lines 225-237) documents the `getent ahostsv4` rationale;
  component 2 modifies the `else` branch (line ~274-282) to surface a warning.
- **Phase 1 output** — if the caller-pinned `--add-host host.docker.internal:<ip>`
  path lands first, component 1 must decide precedence (an explicit caller pin
  must win over the auto-injected default).
- **Followups `uL4v` (Linux detection gap) and `yS0R` (config-persistence gap)**
  — any new host-side-detected value inherits both open questions.

## Outputs

- (Component 1, if in scope) a container whose `host.docker.internal` resolves to
  a working IPv4 by default on affected hosts, without a caller flag, with the
  detector degrading gracefully (warn + leave empty) off macOS / on unusual
  configs.
- (Component 2) a visible operator warning when `host-access` is active but
  host.docker.internal yields no IPv4 — replacing today's silent skip.
- Clear precedence rules between an explicit Phase 1 caller pin and any
  auto-injected default.
