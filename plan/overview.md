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

**Resolved and task breakdown complete.** The first invocation of `analyze-change-request`
investigated the codebase (`README.md`, `docs/architecture.md`,
`docs/ai-sandbox-profiles-spec.md`, `src/options.sh`, `src/index.sh`, `src/create.sh`,
`src/list.sh`, `src/new-profile.sh`, `src/help.sh`, `src/status.sh`, `src/utils.sh`, and
`test/unit/ai_sandbox_spec.sh`; findings recorded in
`plan/notes/current-dispatch-audit.md`) and surfaced one genuine, load-bearing contradiction
within the settled requirements — the profile-deletion command syntax (see
`plan/notes/profiles-delete-ambiguity.md`) — that could not be resolved without guessing.
That invocation returned `status: needs input`, registering four phases
(`dispatch-foundation`, `profiles-resource`, `docs-and-help`, `test-coverage`) with
goals/inputs/outputs drafted under `plan/phases/` but no task-level breakdown.

The blocking question was escalated to the user and answered directly:
**Option B — the explanatory paragraph wins.** `profiles`/`instances` noun words support
only `ls` and `create`; profile deletion is exclusively `ai-sandbox <name> delete` via the
shared flat-namespace per-name dispatch mechanism, symmetric with instance deletion. No
`ai-sandbox profiles delete <name>` three-token form exists. Full resolution detail and its
concrete task-breakdown implications are recorded in
`plan/notes/profiles-delete-ambiguity.md`'s "## Resolution" section.

With the question resolved, this second invocation completed full task-level breakdown for
all four phases and populated `plan/TODO.yaml` accordingly (see `plan/TODO.yaml` and each
phase's task documents under `plan/phase-NN-<slug>/`). The architectural-implications check
was run (this restructure rewrites the CLI's dispatch grammar and command-flow topology
documented in `docs/architecture.md`); rather than registering a separate `doc-updates`
phase, its scope was folded into the already-planned `docs-and-help` phase (which was
expanded to also cover `docs/ai-sandbox-profiles-spec.md`'s `new-profile` command section —
a gap in the original phase draft) per that phase's own stated design intent to stand in
for the automatic doc-updates check. See the structured report returned by this invocation
for the full rationale.

Two additional findings from the first invocation were resolved without escalation
(recorded as `assumptions_applied`, not blocking):

1. Bare `ai-sandbox` (zero args) currently lists all sandboxes (confirmed via
   `src/options.sh` and the existing test asserting this); this plan resolves that to
   "enter the default instance" instead, matching README's long-standing Quick Start
   description and the per-instance "no verb → enter" pattern, with the old bare-list
   behavior folded into the new explicit `ls` word. See the audit note for the reasoning.
2. Dropping the `status` CLI word does not require renaming the internal `STATUS_JSON`/
   `STATUS_TEST_CHECK` globals or the `status.sh` filename — only the recognized command
   token changes.

Execution can now proceed via `execute-implementation-plan`, starting with
`dispatch-foundation`'s first task.

## Overview

Four phases, in dependency order (no parallel-eligible groups across phases; within-phase
parallelism, if any, will be determined at full task-breakdown time):

1. **`dispatch-foundation`** — noun-based grammar for `instances`/`profiles` `ls`/`create`,
   bare `ls`, corrected bare-no-args behavior, alias collapsing (`status`/`connect`
   removed), single-source-of-truth reserved-word derivation, and a stubbed extension point
   for per-name instance-or-profile resolution. Blocked on nothing — ready for task
   breakdown once re-invoked, independent of the open question.
2. **`profiles-resource`** — profile CRUD (`profiles ls`/`create`; deletion via `<name>
   delete`, per the resolved question), the `instance_exists`/`profile_exists` helpers, and
   completion of the per-name resolve-then-verb-gate dispatch mechanism.
3. **`docs-and-help`** — README.md, `docs/ai-sandbox-profiles-spec.md`,
   docs/architecture.md, src/help.sh updates reflecting the final grammar (expanded from
   the original draft to include `docs/ai-sandbox-profiles-spec.md`'s `new-profile` section,
   which the profiles-resource phase's rename to `profiles create <name>` makes stale).
   Depends on phases 1 and 2 landing.
4. **`test-coverage`** — ShellSpec updates/additions for the full new grammar, the
   collision check, and removed-alias assertions. Depends on all prior phases.

See `plan/phases/dispatch-foundation.md`, `plan/phases/profiles-resource.md`,
`plan/phases/docs-and-help.md`, and `plan/phases/test-coverage.md` for each phase's
Goals/Inputs/Outputs.
