# Unit Tests

## Purpose and scope

Add ShellSpec unit coverage for the `--static-playground` flag's parsing,
config-persistence round-trip, running-config matching, and the
`generate_volume_override()` skip-guard, mirroring the existing patterns in
`test/unit/ai_sandbox_spec.sh` exactly. Fast, no-Docker tests that load
`bin/ai-sandbox.sh` with `__SOURCED__=1`.

Depends on Tasks 001 (flag/config/restore/matches) and 003 (volume-override
skip-guard). Single file: `test/unit/ai_sandbox_spec.sh`. No standard skill;
follow the design note and the surrounding spec conventions.

## Requirements

Implement the **Unit** portion of part 8 of the
[design note](../notes/static-playground-design.md). Mirror the cited existing
blocks closely (naming, structure, `container_exec`/eval harness usage, tags):

1. **Flag parsing** — alongside the `NO_ISOLATE_CONFIG` parsing block
   (~line 1507): assert `--static-playground` sets `STATIC_PLAYGROUND=true` and
   `CONFIG_FLAGS_PROVIDED=true`, and that its absence leaves
   `STATIC_PLAYGROUND=false`.

2. **`restore_saved_config()` round-trip + regression** — mirroring the
   `NO_ISOLATE_CONFIG=true` case (~line 792): a config label whose decoded JSON
   carries `"static_playground": true` restores `STATIC_PLAYGROUND=true`; a label
   without the field (or with it false/absent) leaves the default `false`
   (regression guard for the additive-field no-op behavior).

3. **`running_config_matches()` match/mismatch** — mirroring the `cur_no_isolate`
   cases (~line 1116): a running container whose `ai.sandbox.static-playground`
   label agrees with the current `STATIC_PLAYGROUND` matches; a disagreement
   (flag flipped on/off vs. the label) is detected as a mismatch and returns
   non-zero.

4. **`generate_volume_override()` skip-guard** — new coverage for both the
   pre-existing `file://` marketplace skip and the new volume-maps skip under
   `${HOME}/playground` (the Task 003 fix; note this exact case was previously
   untested even for the marketplace path). Assert that an entry under
   `${HOME}/playground` produces no mount line while an entry outside it does.

Do **not** add a unit test for `COMPOSE_FILES` assembly — it is inline top-level
script with no unit seam (same as the existing `~/.config` mode-branching); that
branch is covered at the integration level in Task 005, consistent with
precedent.

## Validation

- `make build` (so the spec loads the current `bin/ai-sandbox.sh`) then
  `make test.unit` passes, including the new examples.
- `shellspec test/unit/ai_sandbox_spec.sh -e '<pattern>'` runs each new example
  in isolation and passes.
- `make lint` passes for the spec file.
- The new examples fail against a build **without** Tasks 001/003 changes (sanity
  that they actually exercise the new behavior) — optional spot-check, not
  required to leave in place.

## Assumptions

- Tasks 001 and 003 have landed. If run before Task 003, the
  `generate_volume_override()` volume-maps skip example is expected to fail until
  that fix merges — note this in the report rather than weakening the assertion.

## References

- [static-playground design note](../notes/static-playground-design.md) — part 8
  (Unit).
- `test/unit/ai_sandbox_spec.sh` — the `NO_ISOLATE_CONFIG` parsing (~1507),
  restore (~792), and `running_config_matches` (~1116) blocks to mirror.
- `docs/architecture.md` § "Test strategy" — unit-tier conventions
  (`__SOURCED__=1`, tags).

## Status

- **Outcome:** succeeded (2026-07-14).
- Added 8 new ShellSpec examples to `test/unit/ai_sandbox_spec.sh`, mirroring
  the cited existing blocks:
  - `parse_options()`: default-false and `--static-playground` flag-parsing
    examples (mirrors the `NO_ISOLATE_CONFIG` block, ~1507).
  - `restore_saved_config()`: `static_playground:true` round-trip and an
    additive-field-omitted regression example (mirrors the
    `NO_ISOLATE_CONFIG=true` case, ~792).
  - `running_config_matches()`: match and mismatch examples for the
    `ai.sandbox.static-playground` label (mirrors the `cur_no_isolate`
    cases, ~1116); extended the local `mock_inspect_line()` test helper from
    10 to 11 positional fields (existing 9/10-arg callers are unaffected —
    unset trailing `%s` slots default to empty, same precedent already
    documented for the 9→10 allow-egress extension).
  - `generate_volume_override()`: new `Describe` block covering the
    `user_maps`/volume-maps skip-guard under `${HOME}/playground` (the Task
    003 fix) for both the in-guard and outside-guard cases.
- **Validation:**
  - `make build` then `make test.unit`: 308 examples, 7 failures. The 7
    failures are the same pre-existing, unrelated failures confirmed present
    before this task's changes (verified via `git stash` — identical 7
    failure descriptions at baseline); none of the 8 new examples are among
    them.
  - `shellspec test/unit/ai_sandbox_spec.sh --example '<glob-pattern>'`
    (note: the project's `-e` shorthand collides with ShellSpec's `--env`
    flag in this ShellSpec version (0.28.1); the working per-example filter
    is `-E`/`--example` with a `*substring*` glob, not a bare substring) run
    individually and pass: `*STATIC_PLAYGROUND*` (6/6),
    `*volume-maps*` (2/2), `*redundant read-only mount*` (1/1, pre-existing
    marketplace-skip example unaffected).
  - `make lint`: passes. Added inline `shellcheck disable=SC2016` comments
    (with reason) on the two new volume-maps examples, where a literal
    `$HOME` is intentionally written unexpanded to the mocked
    `volume-maps` file for `generate_volume_override()`'s own `eval` to
    expand at read time.
  - Optional sanity spot-check (not left in place): confirmed against the
    pre-Task-003 `src/volume-override.sh` (i.e., without the `user_maps`
    skip-guard) that the new volume-maps "does not add a mount ... under
    HOME/playground" example fails, and against a build without Task 001
    (`--static-playground` unimplemented) that the flag-parsing example
    fails — both via reasoning over the diff rather than re-checking out
    prior commits, since Tasks 001/003 are already merged into this branch.
- **Assumptions applied:** Tasks 001 and 003 have landed (confirmed:
  `STATIC_PLAYGROUND`/`--static-playground` exist in `src/options.sh`, and
  the `user_maps` skip-guard exists in `src/volume-override.sh`).
- **Note:** the design note/task doc's premise that the `${HOME}/playground`
  skip-guard was "previously untested even for the marketplace path" does
  not match this branch's current state — a marketplace-skip example
  (`does not add a redundant read-only mount for a path already under
  HOME/playground`) already exists in `test/unit/ai_sandbox_spec.sh`
  (predates this plan, commit `f223177`). Left that existing example
  untouched and added only the volume-maps half that was genuinely missing,
  per Requirement 4's actual ask ("new coverage for both"). Flagged for the
  manager below rather than silently reconciling the design note.
</content>
