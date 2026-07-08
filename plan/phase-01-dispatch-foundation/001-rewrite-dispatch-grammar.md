# Rewrite Dispatch Grammar

## Purpose and scope

Rewrite `src/options.sh`'s `parse_options()` (and its helpers `check_reserved_name`/
`validate_sandbox_name`) to the new noun-based CLI grammar for the `instances` resource,
replace the hand-maintained `RESERVED_NAMES` literal with a single-source-of-truth
derivation, collapse the `status`/`connect` aliases, add the bare `ls` word, and fix bare
no-args to default to `enter` instead of `list`. This is a bash-only change confined to
`src/options.sh`; no standard skill applies — this is novel dispatch-parser work specific to
this codebase. Do not implement `profiles` noun parsing here (deferred to
`plan/phase-02-profiles-resource/`) and do not edit `src/index.sh`/`src/create.sh`/
`src/list.sh` (that's `002-wire-index-and-call-sites.md`, which depends on this task's `CMD`
vocabulary).

Full investigation backing this task is recorded in
`plan/notes/current-dispatch-audit.md` (confirmed current table contents, line references,
and the reserved-word derivation design sketch) — read it before starting.

## Requirements

1. **Reserved-word derivation.** Replace the `RESERVED_NAMES` hand-maintained string
   literal (today: `create list help kill-local-ai new-profile status detail`) with a
   function or array computed from the live command tables, so a future addition to any
   underlying table is automatically reserved without a second edit. The derived set must
   include: the per-name verb table (see item 3 for its updated contents), the noun words
   `instances` and `profiles` (even though `profiles` verb-parsing isn't implemented until
   the next phase — it must already be unreachable as a sandbox name), the bare word `ls`,
   the word `create` (even though `create` is no longer a free-standing global word — see
   item 2), and the unchanged global words `help`, `kill-local-ai`, `new-profile`. Do **not**
   include `list` or `status` or `connect` in the derived set — none of these remain
   recognized command words after this task (see items 2 and 3), so keeping them reserved
   would reintroduce exactly the kind of stale, hand-maintained entry this derivation is
   meant to eliminate. `check_reserved_name()` itself is unchanged (same signature, same
   error message); only what's passed as its `reserved_names` argument changes.
2. **`instances` noun parsing.** Add recognition of `instances` as a noun word supporting
   exactly two sub-verbs:
   - `ai-sandbox instances ls` → `CMD=ls`, `SANDBOX_NAME=""` (same target as bare `ls`;
     see item 4 — for this phase, both produce identical behavior).
   - `ai-sandbox instances create <name> [options]` → same behavior as today's bare
     `create <name>` path (`CMD=create`, `SANDBOX_NAME=<name>` with the same
     `validate_sandbox_name`/`check_reserved_name` calls, same downstream `--profile`/
     `--mode`/etc. flag parsing in Phase 3, same `SANDBOX_PROFILES` assembly in Phase 4).
   `create` and `list` are removed as free-standing global command words — they are only
   reachable as sub-verbs of a noun word (`instances create`, bare/`instances` `ls`) going
   forward. A bare `ai-sandbox create` (no noun, no name) must fall through to the per-name
   path and be rejected by the reserved-word check from item 1 (this is the literal
   `ai-sandbox create enter`-shaped bug this plan fixes — verify it does NOT regress: the
   old bug was `create` defaulting to `SANDBOX_NAME=create`/`CMD=enter`; the fix is that
   `create` is now always reserved, so this path errors instead).
   Leave `help`/`kill-local-ai`/`new-profile` global-word recognition untouched in this
   task — `new-profile`'s replacement by `profiles create` is the next phase's job.
3. **Alias collapse.** Remove `status` and `connect` from every table and code path:
   - `PER_INSTANCE_COMMANDS` becomes: `start enter attach fix-ssh build user-exec
     root-exec detail stop delete clean up` (removed: `connect`, `status`; `detail` was
     already present and is now the only spelling — no alias remains).
   - Delete the `detail`→`status` normalization block that runs immediately after Phase 2's
     `CMD` assignment (today's `src/options.sh` lines ~213-221 per the audit note).
   - Delete the duplicated inline `detail`→`status` normalization inside Phase 3's
     flag-parser loop, in the `promoted_cmd` handling (today's lines ~333-341 per the audit
     note) — the promoted word is now used as-is (`CMD="${rarg}"`), no special-casing for
     `detail` needed since there's nothing to normalize it to anymore.
   - `attach` remains the sole spelling for what was `attach`/`connect`.
   - Every downstream `[ "${CMD}" = "status" ]`-style check in *this file* must now read
     `detail` instead — but do not touch `src/index.sh`'s dispatch branch or `src/status.sh`
     (that's task `002`'s job; this task only owns `src/options.sh`). The `QUIET` default
     logic in Phase 5 of `parse_options()` (`[ "${CMD}" = "status" ]` → `QUIET=0`) is inside
     this file and must be updated to check `detail` instead.
4. **Bare `ls` word.** When zero positional args remain and the first token (after leading
   flags) is exactly `ls`, route to `CMD=ls`/`SANDBOX_NAME=""` — mirror the existing
   "per-instance command word without a name prefix" pattern already used for e.g. `clean`
   in Phase 2's `is_per_instance_cmd` branch, but `ls` is a new standalone bare word, not a
   per-instance verb (a sandbox instance's own `<name> ls` is not a thing — `ls` never takes
   a name prefix). For this task, `ls` and `instances ls` both simply route to `CMD=ls`; the
   grouped instances+profiles output is `002`'s (or task doc TBD in profiles-resource)
   concern via `src/index.sh`/`src/list.sh` — this task only owns getting `CMD=ls` set
   correctly from every valid spelling.
5. **Bare no-args fix.** Change the `n_remaining -eq 0` branch (Phase 2) from `CMD="list"` to
   `CMD="enter"` with `SANDBOX_NAME=""` — matching the existing "name given, no verb →
   enter" default already established for named instances. This is a deliberate, confirmed
   user-facing behavior change (old bare-list behavior now requires the explicit `ls` word);
   see `plan/notes/current-dispatch-audit.md`'s "Bare no-args behavior — resolved
   discrepancy" section for the full rationale. Do not add a compatibility shim.
6. **Per-name resolution stub.** In the per-name (`else`) branch of Phase 2 — where
   `SANDBOX_NAME` is set to the first positional arg because it matched no global/noun/
   per-instance-command word — add a call to a new function with a documented contract for
   later completion by `profiles-resource`:
   ```bash
   # resolve_name_kind <name>
   # Echoes one of: instance | profile | unknown
   # Stubbed in this phase to always echo "instance" (profile_exists doesn't exist yet).
   # profiles-resource completes this to consult profile_exists too and to drive
   # verb-gating (restricting which CMD values are valid for each kind).
   ```
   Call it immediately after `validate_sandbox_name`/`check_reserved_name` and before the
   existing per-instance-verb-or-default-enter logic. In this phase, do not act on its
   return value yet (no verb restriction) — just wire the call site so the extension point
   exists and is exercised (e.g. capture it into a local var even if unused further, so the
   the next phase's diff is additive rather than needing to re-locate the call site).
7. Leave Phase 3's flag-parsing block (`--profile`, `--mode`, `--add-marketplace`,
   `--enable-plugin`, `--enable-all`, `--clean`, `--no-isolate-config`, `--enter`, `--json`,
   `--test-check`, and the removed-flag errors for `--docker`/`--no-docker`/`--no-chromium`)
   unchanged except for the `detail`→`status` promotion normalization removal in item 3.

## Validation

- `shellcheck src/options.sh` passes with no new warnings (any newly-needed disable comment
  includes an inline reason, per this repo's convention).
- `make build` succeeds (rolls `src/` into `bin/ai-sandbox.sh` without errors).
- `grep -n 'RESERVED_NAMES=' src/options.sh` no longer shows a hardcoded space-separated
  literal — it shows a derivation (function call or array assembled from other tables).
- `grep -n '"status"' src/options.sh` and `grep -n 'connect' src/options.sh` return no
  matches (both spellings fully removed from this file).
- `grep -n 'CMD="list"' src/options.sh` returns no matches; the bare no-args branch sets
  `CMD="enter"`.
- Manual smoke checks (source `src/options.sh` — or use the existing ShellSpec harness's
  `parse_options` invocation pattern from `test/unit/ai_sandbox_spec.sh` — without editing
  the test file, since `test-coverage` is a separate phase):
  - `parse_options` (no args) → `CMD=enter`, `SANDBOX_NAME=""`.
  - `parse_options ls` → `CMD=ls`, `SANDBOX_NAME=""`.
  - `parse_options instances ls` → `CMD=ls`, `SANDBOX_NAME=""`.
  - `parse_options instances create foo` → `CMD=create`, `SANDBOX_NAME=foo`.
  - `parse_options create` (no noun) → exits nonzero with the reserved-name error
    mentioning `create`.
  - `parse_options status` and `parse_options mybox connect` no longer parse as those
    spellings — confirm they fall through to the per-name path (e.g. `SANDBOX_NAME=status`
    then rejected as reserved, since `status`... **note:** per item 1, `status` is NOT in
    the reserved set — confirm instead that `parse_options status` sets
    `SANDBOX_NAME=status`/`CMD=enter` (treated as a literal, non-reserved instance-name
    attempt), which is the correct/intended fall-through behavior now that `status` is not
    a recognized word.
  - `parse_options mybox detail` → `CMD=detail` (no normalization needed).

## Metadata

architectural_impact: true

## Assumptions

- `test/unit/ai_sandbox_spec.sh` is not modified by this task; its currently-failing
  assertions against the old grammar (e.g. bare invocation defaulting to `list`) are
  expected to fail after this task lands and are fixed in the `test-coverage` phase. Do not
  attempt to make the existing test suite pass as part of this task.
- `src/index.sh`'s dispatch branch still references `CMD="status"`/`CMD="connect"` after
  this task lands (those checks live outside `src/options.sh`) — this is expected
  intermediate state, resolved by task `002` next.

## References

- `plan/notes/current-dispatch-audit.md` — full investigation, line-level references into
  the current `src/options.sh`.
- `plan/phase-01-dispatch-foundation/002-wire-index-and-call-sites.md` — the dependent
  follow-on task that consumes this task's new `CMD` vocabulary.

## Status

- **Outcome:** succeeded
- **Date:** 2026-07-08
- **Summary:** `src/options.sh` rewritten to the noun-based grammar: `RESERVED_NAMES` is now
  derived via a new `compute_reserved_names()` helper from `GLOBAL_COMMANDS`,
  `PER_INSTANCE_COMMANDS`, `NOUN_WORDS`, and an `EXTRA_RESERVED_WORDS` set (`create ls`)
  instead of a hand-maintained literal; `instances ls` / `instances create <name>` noun
  parsing added; `status`/`connect` and both `detail`→`status` normalization blocks removed
  (`detail` is now the sole spelling, including in the Phase 5 `QUIET` default check); the
  bare `ls` word added as a standalone (non-per-instance) word; bare no-args now sets
  `CMD=enter`/`SANDBOX_NAME=""` instead of `CMD=list`; a `resolve_name_kind()` stub (always
  echoes `instance`) is wired into the per-name branch, captured but not yet acted on.
- **Validation:** `shellcheck src/options.sh` — passed, no new warnings. `make build` —
  passed. `make lint` (full project) — passed, no new warnings. All four required greps
  (`RESERVED_NAMES=` shows a derivation; `"status"`, `connect`, `CMD="list"` all absent) —
  confirmed. All manual smoke checks from `## Validation` — confirmed by sourcing
  `src/options.sh` directly and calling `parse_options` with each listed invocation; outputs
  matched exactly. `make test.unit` — run per repo convention (not part of this task's
  `## Validation`); 34 pre-existing `test/unit/ai_sandbox_spec.sh` examples now fail, all of
  them asserting old-grammar behavior this task deliberately replaces (bare `list`/`status`
  words, bare `create <name>`, `detail`→`status` normalization) — matches this task doc's
  `## Assumptions` and is left for the `test-coverage` phase per that assumption.
- **Affected source files:** `src/options.sh`, `bin/ai-sandbox.sh` (rollup output, rebuilt
  via `make build`).
