# Fix Robustness Regressions From Restore Broadening

## Purpose and scope

Task 001 of this phase fixed the orphaned-sidecar bug by broadening
`restore_saved_config()`'s trigger (via the new `should_restore_config()`
predicate in `src/utils.sh`) from `start`/`enter` only to every per-instance
`CMD` except `create`. The phase-1 gate review (four independent lenses —
correctness, efficiency, security, architecture-conformance) confirmed the
core fix is correct and well-tested, but two lenses (correctness and
architecture-conformance) independently surfaced the same root concern from
different angles, plus a second, distinct regression. This task fixes both
before the phase can close.

**Do not** touch the orphaned-sidecar fix itself (`should_restore_config()`,
the broadened `src/index.sh` call site, the `-p "${COMPOSE_PROJECT}"` additions)
— that part of task 001 is correct and already merged. This task only
hardens two second-order consequences of that broadening.

## Requirements

### 1. Profile-restore hard-failure on teardown commands (major, high confidence)

**Root cause:** Every per-instance `CMD` now unconditionally runs
`bin/profile-installer.js` using the config `restore_saved_config()` restores
— including the restored `profiles` list (`src/utils.sh` — the
`IFS='|' read -ra PROFILES <<< "${saved_profiles}"` line inside
`restore_saved_config()`). Unlike the marketplace-restore branch a few lines
below (which validates each restored marketplace's URL scheme and silently
drops/warns on an invalid one rather than failing), the profile-name restore
has no such fallback. If a restored profile name no longer resolves to a file
(deleted, renamed, or a project-local profile that was only resolvable
relative to the `create`-time working directory), `bin/profile-installer.js`'s
`loadProfile()` calls `die()` → `process.exit(1)`, and `src/index.sh`'s
`PROFILE_INSTALLER_OUTPUT="$(node ...)" || exit $?` propagates that failure,
aborting the entire invocation **before** the CMD dispatch section is ever
reached. This now blocks `delete`, `clean`, `stop`, `build`, `fix-ssh`,
`detail`, `user-exec`, `root-exec`, `attach`, and `up` for any instance whose
saved profile has become unresolvable — including `delete`/`clean`/`stop`,
the exact commands a user needs when something about an instance is broken.

**Fix:** Make profile-name restoration degrade gracefully instead of hard-failing
the whole invocation, mirroring the existing marketplace-scheme validation
pattern (warn and skip/drop rather than propagate a fatal error) — scope the
graceful-degradation specifically to the case where `CONFIG_FLAGS_PROVIDED`
was `false` before restore ran (i.e., the failure was caused solely by a
restore-injected value, not something the user explicitly requested this run).
Exact mechanism is your call — options include: catching a profile-resolution
failure in `bin/profile-installer.js`'s invocation from `src/index.sh` and
falling back to an empty/default profile composition with a warning that the
persisted profile could not be resolved, or validating restored profile names
against the known search locations before setting `PROFILES` and dropping
unresolvable ones the same way the marketplace check drops invalid schemes.
Preserve existing behavior for `start`/`enter` and for any invocation where
the user passed explicit flags (`CONFIG_FLAGS_PROVIDED == true` already skips
restore entirely, unchanged).

Add a regression test: create an instance with a custom profile, then
simulate that profile becoming unresolvable (e.g. delete/rename the profile
file, or use a test double for `bin/profile-installer.js`'s search), and
confirm `delete`/`stop`/`clean` with no `--profile` flag still succeed (with
a warning) rather than hard-aborting.

### 2. `fix-ssh` on clean-slate instances loses credentials on recreate (major, high confidence)

**Root cause:** Broadening `should_restore_config()` to include `fix-ssh`
means `restore_saved_config()` now restores `CLEAN_SLATE=true` for a
`--clean`-created instance even when `fix-ssh` is invoked with no flags
(previously `CLEAN_SLATE` stayed at its CLI-parsed default, `false`, for
`fix-ssh`, since restore never ran for it). `fix_ssh()` then runs
`docker compose ... up -d --force-recreate --no-deps ai-sandbox`. With
`CLEAN_SLATE` now correctly `true`, `COMPOSE_FILES` takes the
`AI_SANDBOX_CREDENTIALS_JSON_B64`-gated `docker-compose.claude-auth.yaml`
branch instead of `docker-compose.mirror-claude.yaml` — but
`AI_SANDBOX_CREDENTIALS_JSON_B64` is never populated for `fix-ssh`, because
the credential-snapshot phase (`src/index.sh`, the block guarded by
`{ [ "${CMD}" = "start" ] || [ "${CMD}" = "enter" ] || [ "${CMD}" = "create" ]
|| [ "${CMD}" = "up" ]; }`) doesn't include `fix-ssh`. Neither overlay ends up
applying credentials correctly, so the force-recreated container's
`docker/rootfs/etc/cont-init.d/04-write-credentials` init script sees an
empty `AI_SANDBOX_CREDENTIALS_JSON_B64` and writes nothing. Since clean-slate
mode never bind-mounts the host `~/.claude`, `--force-recreate` destroys the
previous container's writable-layer credentials with nothing to replace
them: the recreated container loses Claude authentication entirely.

**Fix:** Add `fix-ssh` to the credential-snapshot CMD guard in `src/index.sh`
(mirroring `start`/`enter`/`create`/`up`), or have `fix_ssh()` itself call
`ensure_clean_slate_credentials()` (see `src/credentials.sh`) when
`CLEAN_SLATE=true` before invoking the compose recreate. Add a regression
test: create an instance with `--clean`, run `fix-ssh` with no flags, and
assert credentials still resolve post-recreate (e.g. via the same
`user-exec` credential-check pattern used elsewhere in the test suite, or a
targeted unit test mocking the credential/compose calls).

## Validation

- `make build` after any `src/` edits.
- `make lint` — shellcheck stays clean; any new `# shellcheck disable=...`
  includes an inline reason comment.
- `make test.unit` passes, including new regression tests for both fixes
  above.
- New/extended integration tests (tagged `integration`) pass for both
  scenarios: unresolvable-profile teardown, and clean-slate `fix-ssh`
  credential preservation. Gate integration runs the same way task 001 did
  (`AI_SANDBOX_SKIP_PLUGIN_CHECK=1` if needed).
- Confirm each new regression test actually reproduces its bug against the
  code as task 001 left it (before this task's fix) — via a disposable
  detached `git worktree` at this phase's task-001 merge commit, the same
  A/B technique task 001 itself used — before relying on it as a regression
  guard.
- Neither fix touches or regresses the orphaned-sidecar behavior task 001
  fixed — re-run `test/integration/docker_proxy_teardown_spec.sh` and confirm
  all 4 scenarios (delete/stop/fix-ssh/clean) still pass.
- Grep-verify `ARGS`/nounset handling in any touched code remains correctly
  guarded; do not reintroduce the previously-fixed unbound-variable bug.

## Metadata

architectural_impact: true

## Assumptions

- A live, reachable Docker daemon is available for the integration
  regression tests, per project convention.
- The graceful-degradation mechanism for requirement 1 is an implementation
  choice within the stated constraint (don't hard-fail teardown commands on
  an unresolvable restored profile); pick whichever approach fits the
  existing `bin/profile-installer.js` / `src/index.sh` boundary most
  cleanly.

## References

- `plan/phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md`
  — the task whose broadening introduced both regressions; do not re-litigate
  its own scope, only harden its second-order effects.
- `src/utils.sh` — `should_restore_config()`, `restore_saved_config()`
  (marketplace-scheme validation pattern to mirror for requirement 1).
- `src/index.sh` — restore call site, credential-snapshot phase guard,
  `COMPOSE_FILES` assembly (clean-slate vs mirror-claude vs claude-auth
  branches), `fix-ssh` dispatch branch.
- `src/credentials.sh` — `ensure_clean_slate_credentials()`.
- `bin/profile-installer.js` — `loadProfile()` / `findProfile()` fatal-failure
  path (`die()`).
- `docker/docker-compose.claude-auth.yaml`, `docker/docker-compose.mirror-claude.yaml`
  — the two overlays whose selection this bug's interaction affects.
- `docker/rootfs/etc/cont-init.d/04-write-credentials` — consumes
  `AI_SANDBOX_CREDENTIALS_JSON_B64` at container init.

## Checkpoint hints

- After the profile-restore graceful-degradation fix (requirement 1) and its
  regression test.
- After the fix-ssh clean-slate credential fix (requirement 2) and its
  regression test.
- After confirming task 001's own orphaned-sidecar integration tests still
  pass unmodified.

## Status

**Outcome: succeeded.** Implemented 2026-07-10.

- Requirement 1 (profile-restore hard-failure): `restore_saved_config()`
  (`src/utils.sh`) now re-validates each restored profile name via the
  existing `profile_exists()` helper (`src/profiles.sh` — already checks the
  same three discovery locations `bin/profile-installer.js`'s `findProfile()`
  does: project-local, user-global, bundled) before assigning `PROFILES`,
  mirroring the marketplace-scheme re-validation a few lines below it in the
  same function. An unresolvable restored name is dropped with a warning to
  stderr instead of being restored verbatim; when every restored name is
  dropped, `PROFILES` is left untouched (empty), so
  `bin/profile-installer.js` falls back to its own default-profile
  resolution instead of `die()`-ing. Scoped automatically to
  `CONFIG_FLAGS_PROVIDED == false` since that's already `restore_saved_config()`'s
  own outer guard — no additional condition needed.
- Requirement 2 (fix-ssh clean-slate credential loss): added `fix-ssh` to
  `src/index.sh`'s credential-snapshot CMD guard, alongside
  `start`/`enter`/`create`/`up`. Chose this over the task doc's other listed
  option (`fix_ssh()` itself calling `ensure_clean_slate_credentials()`
  before the compose recreate) because `COMPOSE_FILES` — including the
  claude-auth-vs-mirror-claude overlay choice — is already fully assembled
  earlier in `src/index.sh`'s linear phase sequence, before command dispatch
  ever calls `fix_ssh()`; by the time `fix_ssh()` runs, populating the
  credential env var can no longer change which overlay was already selected
  into the `COMPOSE_FILES` string it's handed. The CMD-guard fix is a
  one-line addition consistent with the existing architecture and the
  pattern already used for the other three CMDs.
- Unit tests (`test/unit/ai_sandbox_spec.sh`):
  - Two new `restore_saved_config()` examples: drops an unresolvable
    restored profile while keeping a valid sibling; falls back to empty
    `PROFILES` (asserted via `should be undefined`, since bash's
    `${arr[@]+x}` existence test can't distinguish a zero-element array from
    an unset one) when every restored profile is unresolvable.
  - Three new end-to-end `When run script` examples (real built
    `bin/ai-sandbox.sh`, real `bin/profile-installer.js`/`profiles/` tree,
    mocked `docker`) confirming `delete`/`stop`/`clean` with no `--profile`
    flag succeed (with the warning) against a persisted config recording an
    unresolvable profile name, rather than hard-aborting before CMD
    dispatch.
  - One new end-to-end `When run script` example for `fix-ssh` on a
    restored-clean-slate instance: mocks `docker`, shadows `security` so the
    test never touches the real host Keychain, plants a fake
    `~/.claude/.credentials.json` under a throwaway `HOME`, and spins up a
    background Python UNIX-socket listener for `SSH_AUTH_SOCK` (a plain `-S`
    file check isn't sufficient — `ssh-add -l` against a dead/unbound socket
    path exits 2, which `ssh_preflight()` treats as fatal; a live-but-silent
    listener makes it exit 1, "communication with agent failed", which is
    tolerated). Asserts `docker-compose.claude-auth.yaml` is present in the
    logged `--force-recreate` compose invocation.
- A/B verification (per task doc's Validation section): built a disposable
  detached `git worktree` at task 001's merge commit (`55e5469`), copied over
  the updated spec file only (no source fix), and ran the full unit suite —
  all 6 new regression examples failed exactly as the root-cause analysis
  predicted (2 `restore_saved_config()` examples; 3 teardown-command
  end-to-end examples failing with `status: 1` and the real
  `profile-installer:` `die()` message on stderr; 1 fix-ssh example missing
  `docker-compose.claude-auth.yaml` from the logged compose call), with the
  other 191 pre-existing examples unaffected. Re-ran against the fixed
  worktree: all 197 examples pass.
- `make test.unit`: 222 examples, 0 failures. `make lint`: clean (no new
  `shellcheck disable` needed).
- `test/integration/docker_proxy_teardown_spec.sh` (task 001's own
  orphaned-sidecar regression suite, all 4 scenarios: delete/stop/fix-ssh/
  clean) re-run standalone: 10 examples, 0 failures — task 001's fix is
  unaffected by this task's changes.
- `make test.integration` (full suite, `AI_SANDBOX_SKIP_PLUGIN_CHECK=1`,
  live Docker daemon): 25 failures / 2 before-all-hook errors / 2 warnings,
  concentrated entirely in `clean_container_spec.sh`, `container_spec.sh`,
  `docker_proxy_spec.sh`, and `lifecycle_spec.sh` — all pre-existing and
  unrelated to this task's diff. Confirmed via the same disposable
  detached-worktree baseline at commit `55e5469`: identical 25
  failures / 2 errors / 2 warnings occur there too, with no source changes
  from this task applied. `docker_proxy_teardown_spec.sh`,
  `named_instance_enter_spec.sh`, and `plugin_install_spec.sh` (14 examples
  combined) pass cleanly both before and after this task's changes.
- Grep-verified: the new `_restored_profiles`/`_validated_profiles` arrays in
  `restore_saved_config()` are only ever expanded under a length guard
  (`"${#_validated_profiles[@]}" -gt 0`) or after a non-empty guard
  (`saved_profiles` non-empty before `_restored_profiles` is populated),
  matching the pre-existing `_validated_marketplaces` pattern in the same
  function — no unbound-variable risk reintroduced under `set -u`.
