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
</content>
