# host-ipv4-access — Plan Closeout Summary

## What was planned and why

Give a container created via `ai-sandbox instances create` (and the normal
create/start path generally) a supported, documented, stable way to reach a
host-side service by a fixed IPv4 address, robust to Docker Desktop's shifting
`host.docker.internal` resolution behavior. Docker Desktop 4.82 stopped
reliably resolving `host.docker.internal` to IPv4 on the planning host, and
the immediate downstream consumer — Flow's flow-run-optimizer — needs the
in-container process to report OpenTelemetry data to a host-side collector at
`host.docker.internal:4318`.

Empirical investigation on the planning host confirmed that "Docker no longer
auto-injects `host.docker.internal`" reproduces, but "`host-gateway` resolves
IPv6-only / `getent ahostsv4` empty" does not reproduce on an
identical-versioned host — the failure is environment-variable. Independent
research into Docker Desktop 4.82 networking confirmed there is no reliable
host-side mechanism to detect or override this (Docker Desktop's per-install
`IPv6Only` network-mode setting legitimately omits the IPv4 subnet with no
documented override). That was the decisive argument for a caller-pinned IPv4
flag rather than any host-side auto-detection.

The plan scoped four changes:

1. A caller-controlled `--add-host <name>:<ip>` pass-through flag, documented
   as the stable contract a downstream automation caller can build against.
2. Full config-persistence-triad wiring for that flag, mirroring the
   `--allow-egress` precedent exactly.
3. Closing the pre-existing config-persistence gap tracked by followup `yS0R`
   (`AI_SANDBOX_LAN_CIDR` / `AI_SANDBOX_HOST_LISTEN_PORTS` had no
   `ai.sandbox.*` label and were absent from `running_config_matches()`,
   allowing silent host-state-drift recreates of a running `host-access`/
   `lan-access` container with no consent prompt).
4. Hardening the visibility of `host-access`'s existing fail-soft
   `host.docker.internal` resolution: surfacing a resolution failure in
   `ai-sandbox detail`/status output instead of only a stderr log line.

Explicit non-goals: no host-side IPv4 auto-detection/default injection ships;
the existing default-deny firewall posture, the macOS-first stance of
host-side network-fact detection, and the config-input/consent-gate model
were all preserved unchanged.

## What shipped

### Phase 1 — `add-host-passthrough` (5 tasks)

1. **`add-host-flag-parsing`** (merge `f6733c6`) — Added a repeatable
   `--add-host <name>:<ip>` flag, modeled on `--allow-egress`. `src/utils.sh`
   gained `is_valid_add_host_spec()` (reusing `is_valid_ipv4_literal()` and
   `is_valid_egress_hostname()`); `src/options.sh` gained a new case arm
   accumulating validated specs into `CLI_ADD_HOST`, exported alongside the
   other `CLI_*` arrays. `make lint`/`make build` passed; manual smoke covered
   the happy path and all failure modes.

2. **`thread-add-host-extra-hosts`** (merge `19bfef7`) — Threaded
   `CLI_ADD_HOST` specs into `GENERATED_COMPOSE`'s `extra_hosts:` block for the
   ai-sandbox service (`src/volume-override.sh`), omitting the key entirely
   when there are no caller entries. Empirically confirmed Compose appends
   rather than replaces `extra_hosts` across `-f` files, so only caller
   entries needed emitting. Fixed an incidental `set -u` bug the new code
   exposed in existing unit tests, and added targeted unit coverage.

3. **`config-persistence-triad`** (merge `e2a6776`) — Wired `--add-host`
   through the full config-persistence triad exactly like `--allow-egress`
   (JSON conversion, config-input record field, compose env var on both
   services, `ai.sandbox.add-host` label, `restore_saved_config()`
   rehydration with `is_valid_add_host_spec()` re-validation,
   `running_config_matches()` comparison), and closed the pre-existing
   `yS0R` gap by adding `ai.sandbox.lan-cidr`/`ai.sandbox.host-listen-ports`
   labels and comparisons — host-state drift on a `lan-access`/`host-access`
   container now triggers the existing consent prompt instead of a silent
   recreate. Also fixed the stale `WjsY` field-count comment in
   `src/status.sh`. `make lint`/`make build` green, no regressions vs.
   baseline.

4. **`host-access-visibility`** (merge `5cacf9e`) — Added a durable,
   fail-soft-preserving visibility signal for `docker/init-firewall.sh`'s
   `host-access` resolution-failure path: a timestamped marker on the shared
   firewall-handshake volume on failure, cleared on success.
   `src/status.sh` gained `_status_gather_host_access()`, wired into
   `do_status()`, reading the marker via `docker exec -u root` (the root
   override was a real bug found and fixed during implementation). Human
   output gets a `Warnings:` line only when unresolved; JSON gets an explicit
   `host_access.resolved` boolean. Verified via a scripted harness against the
   real `init-firewall.sh` plus 5 new unit tests. `make lint` and the unit
   suite were clean relative to baseline.

5. **`add-host-tests`** (merge `1f00377`) — Added ShellSpec coverage for the
   feature landed by tasks 001–004: 34 new unit examples (predicate tests,
   `--add-host` parsing/validation, `restore_saved_config()` round-trip,
   `running_config_matches()` add-host and `yS0R` drift detection), plus a new
   `test/integration/add_host_spec.sh` mirroring `allow_egress_spec.sh`, run
   successfully against a real Docker boot. Lint clean; unit suite showed the
   same 7 pre-existing failures before and after, no new failures.

**Phase-1 review-fix commit** (`7768240`, landed directly on the plan branch
after the phase-1 review gate, not a TODO.yaml task):

- Rejected `--add-host host.docker.internal:<ip>` at parse time
  (`src/options.sh`) and on restore of a previously-saved config
  (`is_valid_add_host_spec()`, `src/utils.sh`), via a new single-source-of-truth
  `is_reserved_add_host_name()` helper. This closed an undefined-behavior
  collision: `host.docker.internal` is already the base compose file's static
  host-gateway alias, and since Compose's `extra_hosts` lists append rather
  than replace across `-f` files, a caller-supplied mapping for the same name
  collided nondeterministically with it — and because `host-access`'s
  firewall rule resolves that exact same name, the collision could
  indeterminately retarget which IP `host-access` opens.
- Fixed `docker/init-firewall.sh` to clear the host-access-unresolved marker
  unconditionally whenever `host-access` is absent from the current boot's
  capability list, not just inside the success branch of the `host-access`
  case arm. Previously a container recreated without `host-access` (e.g.
  switching profiles) never cleared a marker left by an earlier boot, so
  status/detail kept reporting a false resolution warning indefinitely.
- Removed the dead `AI_SANDBOX_ADD_HOST` declaration from the firewall-init
  sidecar's `environment:` block (confirmed `docker/init-firewall.sh` never
  reads it) and replaced stale "depends on phase-01/004" comments with the
  resolved facts.
- Added/updated shellspec coverage for the new rejection and the
  restore-path drop-with-warning behavior; marker-clearing behavior verified
  via a scratchpad scripted harness (stubbed iptables/getent, real script
  execution).

### Phase 2 — `doc-updates` (1 task)

1. **`update-architecture-docs`** (merge `6164555`) — Updated
   `docs/architecture.md` and `docs/ai-sandbox-profiles-spec.md` to document
   the as-built phase-1 work: the `--add-host` flag (parsing/validation,
   `host.docker.internal`-reserved-name rejection, `extra_hosts` threading,
   Compose append-not-replace semantics), its full config-persistence-triad
   participation as the tenth config-input field, the `yS0R` gap closure, and
   host-access resolution-failure visibility. Grounded in the actual merged
   code; no new top-level sections added.

**Phase-2 review-fix commit** (`af09074`, landed directly on the plan branch
after the phase-2 review gate, not a TODO.yaml task):

- Corrected a self-contradictory claim in `docs/architecture.md`: the
  `AI_SANDBOX_ADD_HOST` paragraph had claimed the env var feeds both
  `running_config_matches()` *and* `restore_saved_config()` via the
  `ai.sandbox.add-host` label, but `restore_saved_config()` actually never
  reads that env var or label — it rehydrates `CLI_ADD_HOST` from the
  separate `ai.sandbox.config` label's `add_host` field, which contradicted
  the doc's own later "Why restore and matches don't read the same labels"
  section.
- Added a completeness note to both `docs/architecture.md`'s "Reserved name"
  paragraph and `docs/ai-sandbox-profiles-spec.md`'s reserved-name text that
  the `host.docker.internal` rejection in `is_reserved_add_host_name()` is
  case-insensitive (it lowercases via `tr` before comparing).

## Key decisions

- **Caller-pinned IPv4, no auto-detection (V1 direction).** Ship
  `--add-host <name>:<ip>` only; no host-side IPv4 auto-detection/default
  injection. Decisive because the underlying resolution failure is
  environment-variable and Docker Desktop's `IPv6Only` network-mode setting
  has no documented override — solving it host-side isn't reliably possible.
- **`host-access` visibility-only hardening.** Keep the fail-soft
  log-and-skip behavior for `host-access`'s `host.docker.internal`
  resolution; only surface the failure in `detail`/status output. Do not
  reroute `host-access` to consume the new pinned host.
- **Full triad participation plus closing the pre-existing `yS0R` gap in the
  same effort.** `--add-host` joins the config-persistence triad exactly like
  `--allow-egress`, and `AI_SANDBOX_LAN_CIDR`/`AI_SANDBOX_HOST_LISTEN_PORTS`
  were given their own labels/comparisons at the same time rather than
  deferred.
- **Reject `host.docker.internal` collisions outright, not merge them.**
  At the phase-1 review gate, the user made an explicit decision to reject a
  caller-supplied `--add-host host.docker.internal:<ip>` at parse/restore
  time (via the new `is_reserved_add_host_name()` helper) rather than adopt
  Compose's `!override` merge tag to make the caller's value win
  deterministically. This was a user decision made at the review gate, not a
  task-agent's own call — it closed an undefined-behavior collision between
  the caller-pinned flag and `host-access`'s existing firewall target for the
  same name.
- **No platform-decision work needed.** Because no auto-detection ships, the
  `--add-host` flag is cross-platform by construction; the plan's Q-U4
  platform-decision question was resolved as not applicable.

## Follow-up items

Tagged `add-host-passthrough` (added 2026-07-18) or `doc-updates` (added
2026-07-19) during this plan's execution, per `plan/followups.yaml`:

- **`BV5P`** — 7 pre-existing `make test.unit` failures (`ai_sandbox_spec.sh`
  lines 3181, 3190, 3199, 3273, 3283, 3293, 3392 — teardown/dropped-profile/
  fix-ssh dispatch regressions), confirmed present on baseline and unrelated
  to this plan.
- **`UoDr`** — Observed `./bin/ai-sandbox.sh start <name>` occasionally
  producing a container named `ai-sandbox-` with an empty sandbox-name
  component and a garbled `instances ls` listing; reproduced with and
  without `--add-host` so unrelated to this plan's diff. Unverified against a
  clean environment; flagged as an observation only.
- **`Dd3N`** — The `-u root` fix in `_status_gather_host_access()` is a
  correctness fix required for the visibility requirement to function, not
  optional hardening — worth confirming no other `docker exec`-based
  diagnostic in the codebase makes the same non-root-default assumption
  against a root-owned path on the firewall-handshake volume.
- **`uZmo`** — `running_config_matches()`'s hand-maintained, positionally
  ordered `docker inspect` format string now sits at 14 fields (grown from 9
  to 11 to 14 across three phases including this one). A misordered insertion
  or forgotten local declaration would silently misalign every later field,
  with no structural check to catch it — only test coverage. Suggests a
  future follow-up to consider a self-describing comparison (e.g. decoding
  the same jq-parseable structure the `ai.sandbox.config` input record
  already uses) instead of continuing to extend the fixed-position delimited
  string.
- **`9gvY`** — After removing the dead `AI_SANDBOX_ADD_HOST` declaration from
  the firewall-init sidecar's `environment:` block, the remaining copy on the
  ai-sandbox service's `environment:` block may itself be unconsumed
  in-container — `src/volume-override.sh` only ever reads the pre-join bash
  array `CLI_ADD_HOST`, never the `AI_SANDBOX_ADD_HOST` env var/label. No
  in-container reader was found. Left untouched (out of the review-fix
  task's scope); worth investigating whether it's dead code too.
- **`t1on`** — `README.md`'s Network access section documents
  `--allow-egress` in prose but has no equivalent coverage for `--add-host`
  (pre-existing convention gap, not a regression). Candidate follow-up doc
  task, out of the doc-updates task's scope (`docs/architecture.md` and
  `docs/ai-sandbox-profiles-spec.md` only).
- **`C8NT`** — `plan/notes/investigation-findings.md`'s "Firewall-interaction
  subtlety" section is now stale against the as-built
  `host.docker.internal`-reserved-name rejection. Plan notes are outside
  `docs/*` scope and are informational only — no action needed; plan notes
  are cleaned up at plan close-out.

## Final Task State

# TODO

## Purpose and scope

Tracking document for the active plan.

## Tasks

### Phase 01 — Add-Host Pass-Through Flag

- [x] [001-add-host-flag-parsing.md](./phase-01-add-host-passthrough/001-add-host-flag-parsing.md) — tier `sonnet-med` · branch `phase-01-task-01-add-host-flag-parsing-and-vali` · commit `29a0df6` · merge `f6733c6`
- [x] [002-thread-add-host-extra-hosts.md](./phase-01-add-host-passthrough/002-thread-add-host-extra-hosts.md) — tier `sonnet-high` · branch `phase-01-task-02-thread-add-host-entries-into-c` · commit `1176048` · merge `19bfef7`
- [x] [003-config-persistence-triad.md](./phase-01-add-host-passthrough/003-config-persistence-triad.md) — tier `sonnet-high` · branch `phase-01-task-03-wire-add-host-into-config-pers` · commit `341b48c` · merge `e2a6776`
- [x] [004-host-access-visibility.md](./phase-01-add-host-passthrough/004-host-access-visibility.md) — tier `sonnet-high` · branch `phase-01-task-04-surface-host-access-resolution` · commit `4d8df07` · merge `5cacf9e`
- [x] [005-add-host-tests.md](./phase-01-add-host-passthrough/005-add-host-tests.md) — tier `sonnet-med` · branch `phase-01-task-05-test-add-host-flag-persistence` · commit `7f4aa21` · merge `1f00377`

### Phase 02 — Documentation Updates

- [x] [001-update-architecture-docs.md](./phase-02-doc-updates/001-update-architecture-docs.md) — tier `sonnet-high` · branch `phase-02-task-01-update-architecture-docs` · commit `a1451a0` · merge `6164555`
