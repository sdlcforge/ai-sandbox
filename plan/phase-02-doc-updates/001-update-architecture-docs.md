# Update Architecture Docs

## Purpose and scope

Update `docs/architecture.md` (and review `docs/ai-sandbox-profiles-spec.md`)
to reflect the full, final behavior shipped across all five of Phase 1's
tasks — not just task 001's `restore_saved_config()` broadening. Follow the
`update-architecture-docs` task-procedure at
`plugins/flow/task-procedures/update-architecture-docs/SKILL.md` for the
review/update mechanics.

**Amended after Phase 1 completed (tasks 002-005 landed after this task doc
was first drafted against only task 001):** the phase-review gate ran five
rounds across Phase 1, and each of tasks 002-005 changed or added behavior
that `docs/architecture.md` does not yet describe. This task must document
the end state of all five, not just task 001's change:

- **Task 001** — broadened `restore_saved_config()`'s trigger from bare
  `start`/`enter` to every per-instance `CMD` except `create` (via
  `should_restore_config()`, `src/utils.sh`).
- **Task 002** — fixed two round-1 regressions: `restore_saved_config()` now
  validates a restored profile name via `profile_exists()` before use,
  gracefully dropping (with a warning) rather than hard-failing when a
  restored profile has become unresolvable; and `fix-ssh` was added to the
  clean-slate credential-snapshot `CMD` guard so `--clean` recreates via
  `fix-ssh` no longer lose SSH credentials.
- **Task 003** — added `is_docker_proxy_label_true()` (`src/utils.sh`), which
  reads the container's persisted `ai.sandbox.docker-proxy` Docker label as an
  authoritative fallback signal, independent of the current invocation's
  profile resolution.
- **Task 004** — added `should_force_proxy_label_fallback()` (`src/utils.sh`)
  to scope task 003's fallback to specific `CMD` values only, plus a
  diagnostic warning printed whenever the fallback actually overrides
  `EFFECTIVE_PROXY`.
- **Task 005** — refined `should_force_proxy_label_fallback()` into a
  two-argument `CMD` × `CONFIG_FLAGS_PROVIDED` predicate: `stop`/`delete`/
  `clean` force the fallback unconditionally (teardown commands have no
  legitimate "explicit override" story — they must act on whatever
  composition actually exists); `fix-ssh`/`start`/`enter`/`up` force it only
  when `CONFIG_FLAGS_PROVIDED != "true"` (a bare restore/resume, not an
  explicit user-driven composition change) — implementing
  `docs/architecture.md`'s own "Matches" subsection's "explicit invocation
  always wins" invariant correctly for every command that can recreate the
  container, not just `start`/`enter`.

## Requirements

- **Implementation tasks that surfaced the architectural implications** (all
  complete, changes on the working branch by the time this task runs):
  - `phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md`
  - `phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md`
  - `phase-01-fix-orphaned-sidecar-teardown/003-fix-capability-loss-on-profile-drop.md`
  - `phase-01-fix-orphaned-sidecar-teardown/004-scope-proxy-label-fallback.md`
  - `phase-01-fix-orphaned-sidecar-teardown/005-gate-label-fallback-on-explicit-invocation.md`
- **Architecture/spec files needing review:**
  - `docs/architecture.md` — specifically the "Config persistence and
    restore" section's **Restore** subsection, which currently states
    (verbatim): "On a bare `start`/`enter` (no config-changing flags passed
    — the existing `CONFIG_FLAGS_PROVIDED != true` gate), this reads only the
    `ai.sandbox.config` label...". This sentence (and any related framing
    elsewhere in that section, e.g. the "Why restore and matches don't read
    the same labels" subsection) must be updated to describe the new,
    broader trigger: every per-instance command except `create` (not just a
    bare `start`/`enter`), gated the same way (`CONFIG_FLAGS_PROVIDED !=
    true` and the container already exists).
  - The "Docker access: proxy, not socket or DinD" section's
    escape-hatch/durability discussion — currently states the persisted label
    is "auto-reapplied on every subsequent bare `enter`/`start`". This must be
    updated to also describe: (a) the `is_docker_proxy_label_true()` fallback
    (task 003) that forces `EFFECTIVE_PROXY` back to the persisted label's
    value, independent of the current invocation's profile resolution; and
    (b) the exact scope of when that fallback applies (task 004/005) —
    unconditionally for `stop`/`delete`/`clean`, and conditionally (only when
    `CONFIG_FLAGS_PROVIDED != "true"`) for `fix-ssh`/`start`/`enter`/`up` — so
    the doc no longer implies the label is *only* reapplied on a "bare"
    start/enter when in fact the mechanism now also protects teardown
    commands and is deliberately excluded when an invocation explicitly
    changes composition.
  - The "Matches" subsection's "explicit invocation always wins" invariant —
    confirm the doc's description of this invariant doesn't need updating
    itself (it shouldn't; tasks 004/005 were written to conform to it, not
    change it), but do add a cross-reference or note pointing at the new
    fallback mechanism as a worked example of the invariant in practice for
    readers trying to understand how `EFFECTIVE_PROXY` is actually computed.
  - `docs/ai-sandbox-profiles-spec.md` — reviewed via the `docs/*-spec.md`
    glob (resolves to exactly this one file in this project). No changes are
    expected (the profile schema/composition rules themselves are unchanged
    by Phase 1), but confirm nothing in its "Image tagging by profile" or
    capability sections implicitly assumes the old start/enter-only restore
    scope.
- **Role for this task:** `references/roles/architect-backend.md` (default —
  the change is a backend/CLI-launcher behavior change, not data-model,
  cloud/infra, or frontend).

## Validation

- `docs/architecture.md`'s "Config persistence and restore" → "Restore"
  subsection no longer says restore is scoped to "a bare `start`/`enter`";
  it accurately describes the broadened per-instance-command scope (every
  `CMD` except `create`) and still correctly describes the
  `CONFIG_FLAGS_PROVIDED != true` / container-exists guard, which is
  unchanged.
- `docs/architecture.md`'s "Docker access: proxy, not socket or DinD"
  section no longer says the persisted label is auto-reapplied "only" on a
  bare `enter`/`start`; it describes `is_docker_proxy_label_true()`'s
  fallback (task 003) and its exact `CMD` × `CONFIG_FLAGS_PROVIDED` scope
  (tasks 004/005): unconditional for `stop`/`delete`/`clean`, conditional
  (`CONFIG_FLAGS_PROVIDED != "true"`) for `fix-ssh`/`start`/`enter`/`up`.
- The "Matches" subsection's "explicit invocation always wins" invariant
  either already reads consistently with the fallback mechanism's scoping,
  or gained a cross-reference to it — confirm one or the other, not silence.
- Confirm (by reading, not necessarily editing) that
  `docs/ai-sandbox-profiles-spec.md` requires no changes; if it does, apply
  them and note what changed.
- No other section of `docs/architecture.md` contradicts the new behavior
  (e.g. re-check the "Command flow" numbered list and the "Docker access"
  section's cross-reference for consistency).
- `grep -n "bare .start.*enter\|start/enter" docs/architecture.md` (or
  equivalent) to catch any other stale "start/enter only" phrasing tied to
  `restore_saved_config`/config restore that this task's targeted edit might
  have missed.
