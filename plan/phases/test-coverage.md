## Goals

Add/update `test/unit/ai_sandbox_spec.sh` ShellSpec coverage for the complete new dispatch
grammar, run last so it can assert against the final, landed behavior of every other phase.

- Update existing tests whose asserted behavior changes:
  - Line ~649 `'defaults CMD to list on bare invocation'` → bare invocation now defaults to
    `CMD=enter` with empty `SANDBOX_NAME` (see the audit note's resolution of the bare
    no-args discrepancy); add a new test asserting bare `ls` produces the grouped listing.
  - Lines ~923-941 `'rejects "create status"/"create detail" because ... is a reserved
    name'` → rewrite for the new `instances create`/`profiles create` invocation shape and
    the expanded reserved-word set (this is the direct regression test for the
    RESERVED_NAMES drift bug this plan fixes — should assert previously-uncovered names
    like `enter`, `start`, `up` are now also rejected, not just `status`/`detail`).
  - Lines ~950-965 `detail`/`status` alias-normalization tests → `detail` becomes the sole
    canonical spelling (no more normalization *to* anything; assert `status` is no longer
    recognized — e.g. it now parses as a bare instance name or produces whatever error the
    landed reserved-word/dispatch design produces for an unrecognized reserved-adjacent
    word) and `connect` is dropped in favor of `attach`-only. Use judgment matching existing
    test patterns for how "word no longer recognized" is best asserted (parses as a literal
    instance name attempt vs. an explicit error) — mirror whatever `dispatch-foundation`
    actually implements for unrecognized per-name verbs today (unchanged in this plan).
- New coverage for:
  - `instances ls` / `instances create <name> [options]` end-to-end parse behavior
    (replacing old bare `create <name>` tests).
  - `profiles ls` / `profiles create <name> [options]` / profile-deletion (exact form per
    the resolved question).
  - The single-source-of-truth reserved-word derivation itself — a test asserting the
    reserved-word set is computed from (not independently listed alongside) the live
    per-name verb table and noun words, so a future addition to that table is
    automatically reserved without a second edit (this is the structural
    drift-can't-happen-again guarantee requirement 5 asks for).
  - Name-collision checks: creating an instance or profile whose name collides with an
    existing instance, an existing profile, or a reserved word, for both `instances create`
    and `profiles create`.
  - Per-name verb-gating: `<name> <instance-only-verb>` against a resolved profile name
    (and vice versa if applicable) produces the "X is a profile, not an instance"-style
    error.

## Inputs

- Final implementation from all three prior phases.
- `test/unit/ai_sandbox_spec.sh` (current structure and ShellSpec conventions read this
  session — `Describe`/`It`/`When call`/`When run`/`The variable`/`The status`/`The
  stderr` patterns; existing tests at the line numbers cited above).

## Outputs

- `test/unit/ai_sandbox_spec.sh` updated with the changes and additions above; `make
  test.unit` (or the specific `shellspec` invocations named in `AGENTS.md`/root
  `CLAUDE.md`) passing.
