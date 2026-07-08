## Purpose and scope

Restructure the `ai-sandbox` CLI command surface: adopt plural resource nouns (`instances`,
`profiles`) with `ls`/`create` sub-verbs for the two operations that have no existing name
to dispatch through, extend the existing flat name-then-verb dispatch mechanism (today
used only for instances) to also resolve profile names and gate verbs by resolved type,
collapse redundant alias pairs (`status`/`detail` → `detail` only; `attach`/`connect` →
`attach` only), replace the hand-maintained and already-drifted `RESERVED_NAMES` literal
with a single source of truth derived from the live command tables, add genuinely new
profile CRUD capability (`profiles ls`, profile deletion — full profile management was
previously scaffold-only via `new-profile`), and fold in the README/architecture.md/help.sh
documentation updates and ShellSpec test coverage this implies. No backward compatibility
is required or wanted; dropped spellings are removed outright, not aliased.

Full detail on scope, hard constraints, and the settled command grammar is preserved in
this session's task-agent dispatch prompt (the user request is not restated here in full;
see the phase files under `plan/phases/` and the notes under `plan/notes/` for the
decomposed detail). Marketplace/plugin CRUD is explicitly out of scope — those remain flags
only (`--add-marketplace`, `--enable-plugin`, `--enable-all`) on instance/profile create,
per confirmed grep of the codebase (they are array fields inside instance/profile config,
not independent resources).

## Current status

This is the **first invocation** of `analyze-change-request` for this plan. Investigation
(reading `README.md`, `docs/architecture.md`, `docs/ai-sandbox-profiles-spec.md`,
`src/options.sh`, `src/index.sh`, `src/create.sh`, `src/list.sh`, `src/new-profile.sh`,
`src/help.sh`, `src/status.sh`, `src/utils.sh`, and `test/unit/ai_sandbox_spec.sh`) is
complete and recorded in `plan/notes/current-dispatch-audit.md`. That investigation
surfaced one genuine, load-bearing contradiction within the settled requirements
themselves — see `plan/notes/profiles-delete-ambiguity.md` — that this plan cannot resolve
without guessing. **This invocation returns `status: needs input`.** No tasks have been
added to `plan/TODO.yaml` yet; four phases are registered with goals/inputs/outputs drafted
(see `plan/phases/`) but no task-level breakdown, since the profiles-resource phase's task
shape depends directly on the open question and the docs/tests phases depend on
profiles-resource's landed grammar.

Two additional findings were resolved by this session without escalation (documented as
`assumptions_applied` in the structured report, not blocking):

1. Bare `ai-sandbox` (zero args) currently lists all sandboxes (confirmed via
   `src/options.sh` and the existing test asserting this); this plan resolves that to
   "enter the default instance" instead, matching README's long-standing Quick Start
   description and the per-instance "no verb → enter" pattern, with the old bare-list
   behavior folded into the new explicit `ls` word. See the audit note for the reasoning.
2. Dropping the `status` CLI word does not require renaming the internal `STATUS_JSON`/
   `STATUS_TEST_CHECK` globals or the `status.sh` filename — only the recognized command
   token changes.

Once the profiles-delete question is answered (via a re-invocation with
`is_reinvocation: true`), this skill should read `plan/notes/profiles-delete-ambiguity.md`'s
resolution, finalize the `profiles-resource` phase's task breakdown first, then
`docs-and-help` and `test-coverage`, and complete the plan (running the architectural-
implications check at that point, since this restructure modifies the CLI's public command
surface).

## Overview

Four phases, in dependency order (no parallel-eligible groups across phases; within-phase
parallelism, if any, will be determined at full task-breakdown time):

1. **`dispatch-foundation`** — noun-based grammar for `instances`/`profiles` `ls`/`create`,
   bare `ls`, corrected bare-no-args behavior, alias collapsing (`status`/`connect`
   removed), single-source-of-truth reserved-word derivation, and a stubbed extension point
   for per-name instance-or-profile resolution. Blocked on nothing — ready for task
   breakdown once re-invoked, independent of the open question.
2. **`profiles-resource`** — profile CRUD (`profiles ls`/`create`/delete), the
   `instance_exists`/`profile_exists` helpers, and completion of the per-name
   resolve-then-verb-gate dispatch mechanism. **Blocked on the profiles-delete-ambiguity
   open question.**
3. **`docs-and-help`** — README.md, docs/architecture.md, src/help.sh updates reflecting
   the final grammar. Depends on phases 1 and 2 landing.
4. **`test-coverage`** — ShellSpec updates/additions for the full new grammar, the
   collision check, and removed-alias assertions. Depends on all prior phases.

See `plan/phases/dispatch-foundation.md`, `plan/phases/profiles-resource.md`,
`plan/phases/docs-and-help.md`, and `plan/phases/test-coverage.md` for each phase's
Goals/Inputs/Outputs.
