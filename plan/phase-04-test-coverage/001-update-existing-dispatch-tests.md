# Update Existing Dispatch Tests

## Purpose and scope

Update the existing `parse_options()` ShellSpec tests in `test/unit/ai_sandbox_spec.sh`
whose asserted behavior changed under this restructure: bare-invocation default,
reserved-name rejection coverage, and the `detail`/`status`/`connect`/`attach` alias tests.
Depends on all prior phases (`dispatch-foundation`, `profiles-resource`, `docs-and-help`)
having landed, so the final behavior is stable to assert against. Runs before
`002-add-new-grammar-and-gating-tests.md` (same file — sequential to avoid merge
conflicts; `002` adds new `Describe`/`It` blocks that don't overlap with this task's edits
but touch the same file region closely enough that parallel dispatch is not worth the risk).
Skill: none — direct ShellSpec editing following this file's existing conventions.

## Requirements

Within the `Describe 'parse_options()'` block (today starting around line 648):

1. **Bare invocation** (today's `It 'defaults CMD to list on bare invocation'`, ~line 649):
   rewrite to assert `CMD` equals `enter` and `SANDBOX_NAME` equals `''`, matching the
   corrected bare-no-args behavior (see `plan/notes/current-dispatch-audit.md`'s "Bare
   no-args behavior" section). Add a new, separate `It` asserting bare `ls` produces
   `CMD=ls`/`SANDBOX_NAME=''`.
2. **`'routes list to CMD with empty SANDBOX_NAME'`** (today, ~line 655, calls
   `parse_options list`): `list` is no longer a recognized word. Rewrite this test's intent
   — either repurpose it to assert `ai-sandbox list` now parses as a literal (non-reserved)
   instance-name attempt (`SANDBOX_NAME=list`, `CMD=enter`), or replace it with the
   equivalent assertion for the new `ls` word (`parse_options ls` → `CMD=ls`,
   `SANDBOX_NAME=''`) plus a new test for `parse_options instances ls` producing the same
   result. Prefer covering both: one test for the literal-name fallthrough of the retired
   `list` word, one for the new `ls` word, one for `instances ls`.
3. **Reserved-name rejection tests** (today's three `It` blocks at ~lines 923-941: `'rejects
   "create status"...'`, `'rejects "create list"...'`, `'rejects "create detail"...'`):
   these assert against the old bare `create <name>` parse shape. Rewrite for the new
   `instances create <name>` invocation shape (`parse_options instances create <name>`),
   and expand the reserved-name coverage beyond just `status`/`list`/`detail` — add
   assertions for previously-uncovered names now correctly rejected, e.g. `enter`, `start`,
   `up`, `ls`, `instances`, `profiles`, `create` itself. This is the direct regression test
   for the `RESERVED_NAMES` drift bug this plan fixes (see
   `plan/notes/current-dispatch-audit.md`'s "Confirmed table contents" section) — the whole
   point is proving the derived reserved-word set actually covers the full live table, not
   just the subset today's hand-maintained literal happened to include. Keep (updated) an
   assertion that a legitimate non-reserved name (e.g. `mybox`) is still accepted via
   `instances create mybox`.
4. **`detail`/`status` alias-normalization tests** (today's three `It` blocks at ~lines
   950-967): `detail` is now the sole canonical spelling — there is no more normalization
   *to* anything. Rewrite:
   - `'normalizes the bare "detail" alias to CMD=status'` → assert `parse_options detail`
     produces `CMD=detail` directly (no normalization).
   - `'normalizes the "<name> detail" alias to CMD=status'` → assert `parse_options myname
     detail` produces `CMD=detail`, `SANDBOX_NAME=myname`.
   - `'defaults QUIET=0 for the "detail" alias, same as "status"'` → assert `QUIET=0` still
     applies for `CMD=detail` (the Phase 5 default-QUIET logic now checks `detail` instead
     of `status` — see `phase-01-dispatch-foundation/001-rewrite-dispatch-grammar.md` item
     3).
   - Add new assertions that `status` no longer parses as a recognized word: `parse_options
     status` → `SANDBOX_NAME=status`, `CMD=enter` (literal instance-name fallthrough, since
     `status` is not reserved — see that same task doc's item 1 for why `status` is
     deliberately excluded from the reserved-word set).
   - Add new assertions that `connect` no longer parses as a recognized word: `parse_options
     mybox connect` → `SANDBOX_NAME=mybox`, `CMD=connect` is **not** produced; confirm
     `connect` instead falls through as an unrecognized per-instance word (passed through to
     `ARGS` for docker-compose forwarding, per the existing "any other word" passthrough
     pattern) — mirror whatever `dispatch-foundation` actually implemented for unrecognized
     per-name verbs (this plan doesn't add special-case rejection for `connect`
     specifically; it's just no longer in `PER_INSTANCE_COMMANDS`).
   - Add an assertion that `parse_options mybox attach` still produces `CMD=attach`
     (unchanged spelling, included for completeness alongside the `connect` removal test).

## Validation

- `shellspec test/unit/ai_sandbox_spec.sh -e 'parse_options'` — all tests in this Describe
  block pass.
- `make test.unit` passes in full (this task's edits must not break any other Describe
  block in the same file — spot-check the immediately-following `do_status()` Describe
  block at ~line 970, which references `CMD`/`STATUS_JSON` state that this task's edits
  should not disturb).
- `shellcheck` is not applicable to the `.sh` spec file beyond what ShellSpec itself
  requires; no shellcheck step needed for this task.
- Manual read-through confirms every reserved-name/alias assertion in this task's edited
  block matches the actual behavior implemented by `dispatch-foundation` and
  `profiles-resource` (cross-check against those phases' landed `src/options.sh`).

## Assumptions

- This task does not add coverage for `instances`/`profiles` `ls`/`create`/verb-gating
  end-to-end behavior — that's `002-add-new-grammar-and-gating-tests.md`'s scope. This task
  only fixes/updates tests whose *existing* assertions changed.

## References

- `plan/phase-04-test-coverage/002-add-new-grammar-and-gating-tests.md` — the follow-on
  task in this same phase, sequential after this one.
- `test/unit/ai_sandbox_spec.sh` — existing `Describe`/`It`/`When call`/`When run`/`The
  variable`/`The status`/`The stderr` conventions (read the full `Describe
  'parse_options()'` block, lines ~648-968, before editing).
- `plan/notes/current-dispatch-audit.md` — investigation backing every behavior change
  asserted here.
