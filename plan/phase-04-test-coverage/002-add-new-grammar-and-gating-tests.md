# Add New Grammar And Gating Tests

## Purpose and scope

Add new ShellSpec coverage in `test/unit/ai_sandbox_spec.sh` for the `instances`/`profiles`
noun grammar, the single-source-of-truth reserved-word derivation's structural guarantee,
name-collision checks, and per-name verb-gating (instance vs. profile). Depends on `001`
having landed first (same file, sequential — avoids merge conflicts and lets this task
build on `001`'s already-updated `Describe 'parse_options()'` block without racing it).
Skill: none — direct ShellSpec editing following this file's existing conventions.

## Requirements

1. **`instances ls` / `instances create <name> [options]` end-to-end parse behavior.** New
   `It` blocks (within `Describe 'parse_options()'` or a new nested `Describe 'instances
   noun'`, implementer's choice matching existing file organization patterns) replacing the
   old bare `create <name>` coverage's end-to-end shape: `parse_options instances ls` →
   `CMD=ls`; `parse_options instances create foo --profile base --mode static` → `CMD=create`,
   `SANDBOX_NAME=foo`, `PROFILES=(base)`, `MODE_OVERRIDE=static` (mirroring today's existing
   `create <name> --profile ...`-style flag-parsing tests, updated for the noun prefix).
2. **`profiles ls` / `profiles create <name> [options]` / profile-deletion.** New coverage
   (likely a new `Describe 'profiles noun'` or `Describe 'profiles CRUD'` block, matching
   this file's existing per-function `Describe` organization — e.g. the existing `Describe
   'new_profile()'` block at ~line 1489 is the natural place to extend/rename): assert
   `parse_options profiles ls` → appropriate `CMD`; `parse_options profiles create bar
   --mode mirror` → `CMD`/`SANDBOX_NAME=bar`/mode flag threaded through correctly. For
   profile deletion, test at the level `profiles-resource` actually implemented it: `<name>
   delete` where `<name>` resolves to a profile — this likely requires mocking
   `profile_exists`/`instance_exists` (follow this file's existing `docker()` function
   mocking pattern, e.g. as seen in the `running_config_matches()` Describe block, to mock
   whatever `profile_exists` shells out to, or mock the function directly if it's pure
   bash). Assert a bundled/read-only profile name is refused deletion with a clear error
   (per `profiles-resource`'s task `002` Requirements item 3).
3. **Reserved-word derivation structural test.** A test asserting the reserved-word set is
   *computed from* (not independently listed alongside) the live per-name verb table and
   noun words — e.g. temporarily/locally extend the per-name verb table or noun-word list
   inside the test (if the implementation exposes it as an overridable array/function) and
   assert the reserved-word check picks up the addition automatically, OR — if the
   implementation doesn't lend itself to that kind of injection — assert structural equality
   between the reserved-word derivation's output and the union of the actual live tables
   read directly from the sourced script (e.g. `reserved_words | tr ' ' '\n' | sort` equals
   the expected union computed independently in the test). This is the drift-can't-happen-
   again guarantee requirement 5 of the original user request asks for — the test must
   actually exercise the *derivation mechanism*, not just re-assert today's known reserved
   words (which `001`'s expanded rejection tests already cover).
4. **Name-collision checks.** New coverage for `instances create`/`profiles create`
   colliding with: an existing instance (mock `instance_exists`/`docker ps -a` per this
   file's existing Docker-mocking conventions), an existing profile (mock `profile_exists`),
   and a reserved word (already covered by `001`'s expanded rejection tests — do not
   duplicate, just confirm the cross-kind cases: `profiles create <existing-instance-name>`
   and `instances create <existing-profile-name>` are both rejected).
5. **Per-name verb-gating.** New coverage asserting `<name> <instance-only-verb>` against a
   resolved profile name (e.g. `<profile-name> enter`) produces the "X is a profile, not an
   instance"-style error from `profiles-resource` task `002`, and (if implemented
   symmetrically — check the landed behavior first) the inverse for an instance-only-verb
   attempted where relevant. Also cover the `unknown` resolution case (`<name>` matching
   neither an instance nor a profile) producing its own distinct error, per that task's
   Requirements item 2.

## Validation

- `shellspec test/unit/ai_sandbox_spec.sh` — full suite passes, including this task's new
  blocks and `001`'s updated blocks.
- `make test.unit` passes.
- `make qa` (lint + tests) passes — this is the final task in the plan; run the full
  project QA gate as the last validation step.
- Manual read-through: every new assertion traces back to a specific Requirement in
  `dispatch-foundation`'s and `profiles-resource`'s task documents (no invented behavior not
  actually implemented by those phases).
- Confirm no test in this file still references `profiles delete <name>` as a parse
  path (per the resolved [profiles-delete-ambiguity](../notes/profiles-delete-ambiguity.md)
  — only `<name> delete` is tested).

## References

- `plan/phase-04-test-coverage/001-update-existing-dispatch-tests.md` — prerequisite task,
  same file, sequential.
- `plan/phase-01-dispatch-foundation/001-rewrite-dispatch-grammar.md` and
  `plan/phase-02-profiles-resource/001-build-profiles-module.md` /
  `002-complete-name-resolution-and-verb-gating.md` — the implementation tasks whose landed
  behavior this task asserts against; read all three before writing tests so assertions
  match actual (not assumed) function signatures and error strings.
- `test/unit/ai_sandbox_spec.sh` — existing conventions, especially the `docker()` mocking
  pattern used throughout (e.g. `Describe 'running_config_matches()'`,
  `Describe 'cleanup_stale_container()'`) as a template for mocking `instance_exists`/
  `profile_exists`.
