# Test Updates + Build/Lint/Test Verification

## Purpose and scope

Bring the test suite in line with the profiles feature and run the full QA gate.
Remove/replace tests for deleted functions and flags (`variant_key` over
`NO_CHROMIUM`/`NO_DOCKER`, removed CLI flags), add unit coverage for the new
bash functions and the `profile-installer.js` interface, fix integration tests
that referenced removed flags, and confirm `make build` + `make lint` +
`make test` all pass.

This is the final task and depends on ALL prior tasks (001–006). It edits
`test/` files and may make small follow-up `src/` fixes if validation surfaces
defects (note any such fixes in the outcome).

## Requirements

### Update existing unit tests — `test/unit/ai_sandbox_spec.sh`

- The `Describe 'variant_key()'` block tests the old flag-based output
  (`full`, `no-chromium`, etc.). Replace it with tests for the new behavior:
  with `PROFILE_COMPOSITION_HASH=a1b2c3d4`, `variant_key` outputs
  `profile-a1b2c3d4`; with the var unset, it outputs the documented fallback
  (`profile-default`). Match the source-of-truth decision made in Task 005.
- The `ensure_image()` setup sets `NO_CHROMIUM=false; NO_DOCKER=false`. Update
  the setup to set `PROFILE_COMPOSITION_HASH` (or `AI_SANDBOX_IMAGE_TAG`)
  instead, so the docker stubs resolve a tag.
- Audit the rest of the file for any other `NO_CHROMIUM` / `NO_DOCKER` /
  `variant_image_tag` usages and update them.

### Add new unit tests

- **options parsing** (new `Describe`, in `ai_sandbox_spec.sh` or a new
  `test/unit/options_spec.sh`): `parse_options --profile base --profile docker`
  populates `PROFILES` with both names and sets `CONFIG_FLAGS_PROVIDED=true`;
  `parse_options --mode static` sets `MODE_OVERRIDE=static`; an invalid
  `--mode bogus` errors; a removed flag (`--docker`) errors with a message
  pointing at `--profile docker`.
- **is_build_stale** extension: a unit test that stubs `docker image inspect` to
  return an old `.Created` and confirms a freshly-touched profile input file
  (via the `PROFILE_INPUT_FILES` contract from Task 005) marks the image stale.
- **create_profile**: a unit test invoking `create_profile --name t --output
  <tmp>` and asserting the file is written and the success line printed (stub or
  point HOME to a temp dir to control discovery).
- **profile-installer.js** (new `test/unit/profile_installer_spec.sh` or a Node
  test): exercise the validation matrix — successful compose (`base mirror`),
  scalar conflict (`mirror static` → nonzero), not-found name → nonzero,
  path-separator name → nonzero, capabilities propagate to
  `PROFILE_CAPABILITIES` and change the hash. ShellSpec can drive `node
  bin/profile-installer.js ...` and assert on status/output. Keep these in the
  unit tier (no docker required).

### Fix integration tests

- `test/integration/docker_proxy_spec.sh`, `container_spec.sh`,
  `lifecycle_spec.sh`: audit for `--docker` / `--no-docker` / `--no-chromium`
  invocations and replace with the profile equivalents (`--profile docker`,
  `--profile chromium`, or default composition). Update any assertions that
  relied on the old `ai-sandbox:full` / `ai-sandbox:no-docker` image tags to the
  new `ai-sandbox:profile-<hash>` scheme.
- The `clean` command's image-removal logic already globs `ai-sandbox:*`, so
  profile-tagged images are still cleaned — verify the integration test for
  `clean` still passes and update expected output if tag strings appear in
  assertions.

### shellcheck / spec conventions

- New/edited spec files must pass `make lint` (shellcheck runs over `test/`).
  Reuse the existing `# shellcheck disable=SC2034,SC2155,SC2317,SC2329` header
  rationale where the ShellSpec DSL requires it.
- Honor the MEMORY.md ShellSpec notes: tags are a separate token after the
  description (e.g. `Describe '...' integration`).

### Final QA gate

Run and pass, in order:
1. `make build` — rolls `src/` into `bin/ai-sandbox.sh`. Confirm no manual edits
   to `bin/ai-sandbox.sh` are needed and the rollup is current.
2. `make lint` — shellcheck across `src/`, `docker/`, `test/`.
3. `make test.unit` — unit tier.
4. `make test.integration` if the environment permits (it is gated by
   `status --test-check`; if host AI processes block it, note that integration
   was skipped and why, and ensure unit tier is green). Do not let an
   environmental preflight failure be reported as a code failure — distinguish
   the two in the outcome.

## Validation

- `make build` exits 0 and `git diff --stat bin/ai-sandbox.sh` reflects only
  rolled-up changes (no hand edits).
- `make lint` exits 0.
- `make test.unit` exits 0 with the new and updated specs passing.
- `grep -rn 'no-chromium\|no-docker' test/` returns only intentional references
  (e.g. removed-flag-error tests), not stale flag invocations.
- `node bin/profile-installer.js base docker` and `node bin/profile-installer.js
  mirror static` behave as the new unit tests assert (sanity check outside
  ShellSpec).
- `make test.integration` passes, OR is documented as skipped due to host
  preflight (`Preflight checks failed; test not run.`) with unit tier green.

## Assumptions

- Integration tests may be skipped in CI-less/local-AI-running environments; the
  unit tier is the hard gate. Report integration status honestly.
- Small `src/` corrections discovered during verification are in scope and must
  be noted in the outcome.

## References

- `test/unit/ai_sandbox_spec.sh`, `test/unit/plugin_preflight_spec.sh`,
  `test/integration/*.sh`.
- `CLAUDE.md` — "Build, lint, test" + the `test.intgeration` typo note (use the
  Makefile target directly).
- MEMORY.md — ShellSpec tag/filter conventions.
