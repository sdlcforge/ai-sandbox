# Update Architecture Docs

## Purpose and scope

Update `docs/architecture.md` (and review `docs/ai-sandbox-profiles-spec.md`)
to reflect the behavior change shipped in Phase 1: `restore_saved_config()` is
now invoked for every per-instance command except `create`, not just a bare
`start`/`enter`. Follow the `update-architecture-docs` task-procedure at
`plugins/flow/task-procedures/update-architecture-docs/SKILL.md` for the
review/update mechanics.

## Requirements

- **Implementation task that surfaced the architectural implications:**
  `phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md`
  (by the time this task runs, that task is complete and its changes are on
  the working branch).
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
    true` and the container already exists). Also check whether the "Docker
    access: proxy, not socket or DinD" section's escape-hatch/durability
    discussion needs a note that the restore now also protects
    `stop`/`delete`/`clean`/`build`/`fix-ssh` from dropping the `docker`
    capability's compose overlay, closing the orphaned-sidecar gap described
    there previously only in terms of `enter`/`start`.
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
