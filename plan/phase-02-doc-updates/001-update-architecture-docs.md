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

## Status

**Outcome: succeeded.** Implemented 2026-07-10.

- **Restore subsection** (`docs/architecture.md`, "Config persistence and
  restore"): replaced the "On a bare `start`/`enter`..." opening with a
  description of the broadened trigger — every per-instance `CMD` except
  `create`, decided by `should_restore_config()` (`src/utils.sh`), with the
  `src/index.sh` call site quoted verbatim (`if should_restore_config
  "${CMD}"; then restore_saved_config; fi`). The unchanged guard
  (`CONFIG_FLAGS_PROVIDED != true` + container-exists) is called out
  explicitly as unchanged. The "no fallback of any kind" sentence's "on a
  bare `enter`/`start`" qualifier was generalized to "for any command that
  would otherwise restore it" so it no longer implies the old narrower scope.
- **"Why restore and matches don't read the same labels"** (same section):
  updated "after a bare-enter restore" to "after a restore (any per-instance
  `CMD` except `create` that triggers it, not just `start`/`enter`)" — the
  task doc's Requirements explicitly called out this subsection as needing
  the same broadening.
- **"Docker access: proxy, not socket or DinD"**: replaced "auto-reapplied on
  every subsequent bare `enter`/`start`" (the `ai.sandbox.config` label
  restore) with "restored on every subsequent per-instance command via
  `restore_saved_config`", then added a new paragraph describing the second,
  independent durability mechanism: `is_docker_proxy_label_true()`
  (`src/utils.sh`) forcing `EFFECTIVE_PROXY` back to the persisted label's
  value, scoped by `should_force_proxy_label_fallback()` — unconditional for
  `stop`/`delete`/`clean`, conditional (`CONFIG_FLAGS_PROVIDED != "true"`)
  for `fix-ssh`/`start`/`enter`/`up`, and out of scope entirely for
  `create`/`detail`/`build`/`user-exec`/`root-exec`/`attach`, matching
  `should_force_proxy_label_fallback()`'s doc comment and the
  `src/index.sh` guard-site comment exactly.
- **"Matches" subsection**: confirmed its own description doesn't need a
  behavioral correction (tasks 004/005 were written to conform to it, not
  change it) and added a cross-reference/worked-example paragraph naming the
  "explicit invocation always wins" invariant explicitly and pointing at the
  `EFFECTIVE_PROXY` label fallback (linked to the "Docker access" section)
  as the same invariant applied in the opposite direction (an override that
  deliberately stops short when `CONFIG_FLAGS_PROVIDED == "true"`).
- **`docs/ai-sandbox-profiles-spec.md`**: read in full, including "Image
  tagging by profile" and the capabilities reference section. No changes
  needed or applied — nothing in that file assumes the old start/enter-only
  restore scope; its `start`/profile-composition examples are orthogonal to
  the restore trigger.
- **Consistency re-check**: re-read the "Command flow" numbered list (no
  restore-scope claims there to begin with) and the other `start`/`enter`
  mentions in `docs/architecture.md` (plugin-conflict preflight scope, the
  SSH-mount-staleness warning scope) — both are independent, unrelated
  command scopes that phase-1 did not touch, so they remain accurate as-is
  and were left untouched.
- `grep -n "bare .start.*enter\|start/enter" docs/architecture.md`: no
  matches after the edits (previously matched the two sentences fixed
  above).

### Validation results

- `docs/architecture.md`'s Restore subsection no longer scopes restore to "a
  bare `start`/`enter`": passed (verified by re-reading the edited section
  and by the grep check below).
- `docs/architecture.md`'s "Docker access" section describes
  `is_docker_proxy_label_true()`'s fallback and its exact `CMD` x
  `CONFIG_FLAGS_PROVIDED` scope: passed.
- "Matches" subsection either already consistent or gained a
  cross-reference: passed (added a cross-reference paragraph naming the
  invariant and pointing at the fallback as a worked example).
- `docs/ai-sandbox-profiles-spec.md` requires no changes: confirmed by
  reading the full file; no edits applied.
- No other section of `docs/architecture.md` contradicts the new behavior:
  confirmed by re-reading "Command flow" and the remaining `start`/`enter`
  mentions (plugin-conflict preflight, SSH-mount staleness) — both are
  unrelated, unchanged scopes.
- `grep -n "bare .start.*enter\|start/enter" docs/architecture.md`: exit 1
  (no matches) after the edits — passed.

Only `docs/architecture.md` was modified; no source files were touched (this
is a documentation-only task, consistent with the phase-1 tasks it
documents already being merged).
