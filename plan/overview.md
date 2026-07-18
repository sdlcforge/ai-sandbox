# host-ipv4-access — Plan Overview

## Purpose and scope

Give a container created via `ai-sandbox instances create` (and via the normal
create/start path generally) a **supported, documented, stable way to reach a
host-side service by a fixed IPv4 address**, robust to Docker Desktop's shifting
`host.docker.internal` resolution behavior. The immediate downstream consumer is
Flow's flow-run-optimizer, which needs the in-container process to report
OpenTelemetry data to a host-side collector at `host.docker.internal:4318`.

**What must change:**

1. Add a caller-controlled `--add-host <name>:<ip>` pass-through flag that
   threads caller-supplied host→IPv4 entries into the container's `extra_hosts`,
   and document it as the stable contract a downstream automation caller can
   build against.
2. Wire that flag fully into the existing config-persistence triad (compose
   `environment:` entry + `ai.sandbox.<field>` label + `running_config_matches()`
   comparison + the `ai.sandbox.config` JSON), mirroring the `--allow-egress`
   precedent exactly.
3. Close the pre-existing config-persistence gap tracked by followup `yS0R`:
   `AI_SANDBOX_LAN_CIDR` and `AI_SANDBOX_HOST_LISTEN_PORTS` currently get no
   `ai.sandbox.*` label and are absent from `running_config_matches()`'s
   comparison set, so host-state drift can silently recreate a running
   `host-access`/`lan-access` container with no consent prompt. Route them
   through the same consent gate.
4. Harden the visibility of `host-access`'s existing fail-soft resolution:
   `docker/init-firewall.sh` currently only logs a stderr line when
   `getent ahostsv4 host.docker.internal` yields no IPv4 and then silently
   allow-lists nothing. Surface that failure in `ai-sandbox detail`/status
   output so it is impossible to miss.

**What must not change:** the existing default-deny firewall posture, the
macOS-first stance of host-side network-fact detection, and the config-input
model — new work must not regress or bypass the consent gate
(`running_config_matches()`). `host-access`'s existing fail-soft behavior is
preserved (log-and-skip); only its *visibility* is improved. No host-side
IPv4 auto-detection / default injection ships (see the direction decision).

**Success criteria:** a downstream caller has one documented way to pin a stable
IPv4 for a host service and reach it from inside an ai-sandbox container under
the normal create/start path; the flag survives `start`/restore and routes
through the `running_config_matches()` consent gate like `--allow-egress`; the
`yS0R` config-persistence gap is closed; a `host-access` resolution failure is
visible in status output; and `docs/ai-sandbox-profiles-spec.md` and
`docs/architecture.md` describe all of it, including the downstream-consumer
contract.

## Current status

Planning is **complete**. All prior scope questions are resolved (see the
decision notes below); no knowledge gaps remain. The plan collapsed from its
earlier conditional multi-phase framing to a **single implementation phase**
(the `--add-host` flag plus its config-persistence wiring, the related
pre-existing triad-gap fix, and the host-access visibility hardening are one
coherent area — container host-reachability configuration and its
persistence/visibility) followed by a `doc-updates` phase.

The regression was investigated empirically on the planning host (see
[investigation findings](./notes/investigation-findings.md)). Summary: the
"Docker no longer auto-injects host.docker.internal" part reproduces, but the
"`host-gateway` resolves IPv6-only / `getent ahostsv4` empty" part **does not
reproduce** on this identical-versioned host. The reported failure is
environment-variable, and the
[Docker Desktop 4.82 networking research](./notes/docker-desktop-4.82-networking.md)
independently confirmed there is no reliable host-side mechanism to detect or
override it (Docker Desktop's per-install `IPv6Only` network-mode setting
legitimately omits the IPv4 subnet with no documented override). That is the
decisive argument for a caller-pinned IPv4 (option (a)) that does not depend on
ai-sandbox solving resolution — and against any host-side auto-detection.

### Resolved decisions

- **[Q-U1 direction](./notes/direction-decision.md):** ship the caller-pinned
  `--add-host <name>:<ip>` flag **only** for V1; no host-side IPv4
  auto-detection/default injection.
- **[Q-U2 host-access scope](./notes/host-access-scope.md):** harden
  *visibility* only — keep the fail-soft log-and-skip, but surface the
  resolution failure in `detail`/status. Do not reroute host-access to consume
  the new pinned host.
- **[Q-U3 config-persistence](./notes/config-persistence-decision.md):** the new
  flag joins the full triad, mirroring `--allow-egress`; additionally close the
  pre-existing `yS0R` gap for `AI_SANDBOX_LAN_CIDR`/`AI_SANDBOX_HOST_LISTEN_PORTS`
  in the same effort.
- **[Q-U4 platform](./notes/platform-decision.md):** not applicable — no
  auto-detection ships; the `--add-host` flag is cross-platform by construction.

## Overview

Single implementation phase (`add-host-passthrough`) plus a `doc-updates` phase.

### Phase 1 — `add-host-passthrough` (registered)

Delivers the caller-pinned `--add-host` flag, its full config-persistence
triad participation, the pre-existing `yS0R` triad-gap fix, and the host-access
visibility hardening. Tasks:

1. **`add-host-flag-parsing`** — parse a repeatable `--add-host <name>:<ip>`
   flag in `src/options.sh` (modeled on the `--allow-egress` case), validating
   `<name>` as a hostname and `<ip>` as an IPv4 literal; populate a
   `CLI_ADD_HOST` array, set `CONFIG_FLAGS_PROVIDED=true`, and export it in both
   `src/options.sh` export lists. Add validation helpers to `src/utils.sh`
   mirroring the `is_valid_egress_*` precedent.
2. **`thread-add-host-extra-hosts`** — thread `CLI_ADD_HOST` entries into the
   container's `extra_hosts` via the generated compose override
   (`GENERATED_COMPOSE`), composing with the static
   `host.docker.internal:host-gateway` entry already in
   `docker/docker-compose.yaml`. Must confirm Compose's `extra_hosts` list-merge
   semantics (append vs. replace) and emit accordingly.
3. **`config-persistence-triad`** — wire `--add-host` fully into the triad
   (config JSON `add_host` field + `AI_SANDBOX_ADD_HOST` env derivation in
   `src/index.sh`; `environment:` passthrough + `ai.sandbox.add-host` label in
   `docker/docker-compose.yaml` for both services; `running_config_matches()` +
   `restore_saved_config()` in `src/utils.sh`), AND close the `yS0R` gap by
   giving `AI_SANDBOX_LAN_CIDR`/`AI_SANDBOX_HOST_LISTEN_PORTS` their own
   `ai.sandbox.*` labels and `running_config_matches()` comparisons. Also fixes
   the stale `src/status.sh` field-count comment (followup `WjsY`).
4. **`host-access-visibility`** — on the `host-access` resolution-failure path in
   `docker/init-firewall.sh`, record a marker on the shared firewall-handshake
   volume, and surface it in `ai-sandbox detail`/status output (human + JSON) via
   `src/status.sh`. Preserves the existing fail-soft behavior.
5. **`add-host-tests`** — shellspec unit coverage for flag parsing/validation and
   the config-persistence round-trip, plus integration coverage where feasible
   (mirroring `test/integration/allow_egress_spec.sh`).

### Phase 2 — `doc-updates` (registered at completion)

Per the architectural-implications check: update `docs/architecture.md` and
`docs/ai-sandbox-profiles-spec.md` to describe the new flag, its
config-persistence wiring, the closed `yS0R` gap, and the host-access visibility
change — including the downstream-consumer contract and the
name-resolution-vs-egress-allowance coupling (pinning a name does not by itself
grant egress under the default-deny firewall; the caller composes it with
`host-access` or `--allow-egress` — see the
[investigation findings](./notes/investigation-findings.md) §"Firewall-interaction
subtlety").

### Followup housekeeping

Followup `yS0R` is closed by task 3 and followup `WjsY` by task 3's comment fix.
Removing those entries from `plan/followups.yaml` is the manager's job (via
`apply-task-report`/`followups_remove`) once the relevant task lands — not the
planning agent's.
</content>
</invoke>
