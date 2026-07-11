# Gate The Proxy-Label Fallback On Explicit-Invocation, Not CMD Alone

## Purpose and scope

Task 004 scoped the `EFFECTIVE_PROXY` label-fallback (`src/index.sh`,
guarded by `should_force_proxy_label_fallback()` in `src/utils.sh`) to fire
only for `CMD` in `{stop, delete, clean, fix-ssh}`, explicitly excluding
`start`/`enter`/`up` so that an invocation which *explicitly* changes
composition via `--profile` (etc.) is allowed to take effect — including
deliberately dropping the `docker` capability. That fixed round 3's
security/architecture findings (silently re-granting a dropped capability on
`start --profile no-docker`).

The fourth phase-review round — independently, from the correctness lens and
the architecture-conformance lens — found that task 004's `CMD`-only gating
is the wrong axis: **whether an invocation is "explicit" is decided by
`CONFIG_FLAGS_PROVIDED`, not by which `CMD` was typed.** Two concrete gaps
result from conflating the two:

**Gap 1 (correctness-001, major): bare `start`/`enter` with profile drift
silently loses the capability again.** A *bare* `start`/`enter` (no
`--profile` this run, `CONFIG_FLAGS_PROVIDED=false`) is not an explicit
composition choice — it is a restore/resume, and `restore_saved_config()` is
the one deciding composition, not the user. If the instance's
docker-granting profile has since become unresolvable (the same drift
scenario task 003 fixed for teardown), `restore_saved_config()` drops it
(task 002's graceful-degradation warning) and `profile_has_capability docker`
resolves `false` for this invocation — but `should_force_proxy_label_fallback()`
excludes `start`/`enter` unconditionally, so `EFFECTIVE_PROXY` is never
corrected back to `true` even though the persisted `ai.sandbox.docker-proxy`
label says so. Concretely: if the container is **currently stopped** (the
common re-entry case after a prior `stop`), `src/index.sh`'s `start`/`enter`
branch (`if is_container_running && ! running_config_matches; then
confirm_stop_running ...; fi`) skips its confirmation gate entirely — there
is nothing running to stop — and proceeds straight to `docker compose ... up
-d`, silently recreating the container **without** `docker-compose.proxy.yaml`
and with no prompt, no warning, and no fallback correction. This is the
phase's target bug class, reintroduced for the bare-`start`/`enter`-with-drift
path.

**Gap 2 (arch-review-002, minor): explicit `fix-ssh --profile <x>` can't
actually drop the capability.** `--profile` is not restricted per-`CMD` in
`src/options.sh`'s flag parser — it can be passed alongside `fix-ssh` too,
setting `CONFIG_FLAGS_PROVIDED=true`. `fix_ssh()` force-recreates the
`ai-sandbox` service (`docker compose ... up -d --force-recreate --no-deps
ai-sandbox`) — the same recreate mechanism `start`/`enter` use — so an
explicit `fix-ssh --profile no-docker` intending to drop the capability
*should* have that explicit choice honored, exactly as task 004 now honors it
for `start`/`enter`. But `should_force_proxy_label_fallback()` returns `true`
for `fix-ssh` unconditionally, regardless of `CONFIG_FLAGS_PROVIDED`, so the
label fallback silently overrides the explicit choice — the same class of
least-privilege violation round 3 found for `start`/`enter`, narrowed to
`fix-ssh`.

**`stop`/`delete`/`clean` are correctly exempt from this refinement.** These
commands don't recompose anything a user's `--profile` flag could
meaningfully redirect — they tear down (or pause) whatever composition
*actually exists*. There is no legitimate "explicit invocation" story for
"delete with a different profile than what was created," so forcing the
label-authoritative value for these three regardless of
`CONFIG_FLAGS_PROVIDED` is correct as-is and **must not change**.

**Do not** touch tasks 001–004's own fixes beyond what's needed here —
`should_restore_config()`, `is_docker_proxy_label_true()`, and the overall
shape of `should_force_proxy_label_fallback()` are correct and stay; this
task only makes the predicate (or its `src/index.sh` call site) sensitive to
`CONFIG_FLAGS_PROVIDED` in addition to `CMD`.

## Requirements

### 1. Make the label-fallback's scope depend on explicitness, not just CMD (major/critical, high confidence — two independent review lenses)

Change the gating so the fallback applies when:

- `CMD` is `stop`, `delete`, or `clean` — **unconditionally**, regardless of
  `CONFIG_FLAGS_PROVIDED` (unchanged from task 004), **or**
- `CMD` is `fix-ssh`, `start`, `enter`, or `up` — **only when
  `CONFIG_FLAGS_PROVIDED != "true"`** (i.e., this invocation did not itself
  pass a composition-changing flag; it's a restore/resume, not an explicit
  override).

Every other `CMD` (`create`, `detail`, `build`, `user-exec`, `root-exec`,
`attach`, and anything else in `PER_INSTANCE_COMMANDS`) stays outside the
fallback's scope entirely, as task 004 left it.

Implement this however reads most naturally against the existing
`should_force_proxy_label_fallback()` shape — either widen its own signature
to take `CONFIG_FLAGS_PROVIDED` as a second argument (mirroring how
`restore_saved_config()` already reads the global), or keep the predicate
`CMD`-only and add the `CONFIG_FLAGS_PROVIDED` check at the `src/index.sh`
guard site for the `fix-ssh`/`start`/`enter`/`up` branch specifically. Prefer
whichever keeps the predicate's doc-comment and unit-test shape closest to
its current form. Update the fallback's inline comment (`src/index.sh`) and
`should_force_proxy_label_fallback()`'s own doc-comment to state the
corrected rule precisely — the current comment's "NOT
start/enter/up/.../create/..." framing must be corrected to reflect that
`start`/`enter`/`up` are now *conditionally* in scope.

### 2. Regression test: bare start/enter with profile drift (gap 1)

New live-Docker integration test (new file or an added `Describe` block in
an existing one — your call) mirroring `docker_proxy_dropped_profile_spec.sh`
(task 003)'s scenario but for `start`/`enter` instead of teardown:

1. Create a docker-capable instance.
2. Make its docker-granting profile unresolvable (same technique task 003's
   spec used — e.g. rename/remove the profile file or otherwise force
   `profile_exists()` to fail for it).
3. Stop the container (`ai-sandbox <name> stop`) so the subsequent `start` is
   a **not-currently-running** recreate (the concrete path where
   `is_container_running && ! running_config_matches` never fires).
4. Run a **bare** `ai-sandbox <name> start` (no `--profile` flag —
   `CONFIG_FLAGS_PROVIDED=false`).
5. Assert the recreated container's `ai.sandbox.docker-proxy` label is still
   `true` and `DOCKER_HOST` still resolves inside the container — the
   capability must survive the drift, unlike pre-fix.

A/B-verify against task 004's merge commit (`a16c5c1`) via the same
disposable-detached-worktree technique tasks 001–004 used: confirms the test
fails pre-fix (capability silently lost) and passes post-fix.

### 3. Regression test: explicit fix-ssh --profile actually drops the capability (gap 2)

New test (mirroring `docker_proxy_explicit_profile_override_spec.sh`'s
shape, task 004) proving `fix-ssh --profile <non-docker>` against a
docker-capable instance now correctly drops the capability instead of being
silently overridden:

1. Create a docker-capable instance.
2. Run `ai-sandbox <name> fix-ssh --profile <non-docker>`.
3. Assert the recreated container's `ai.sandbox.docker-proxy` label is
   `false` and `DOCKER_HOST` no longer resolves inside the container.

A/B-verify the same way (fails pre-fix — fallback silently re-forces
`true` — passes post-fix).

### 4. Confirm existing suites still pass unmodified

Re-run (or confirm still passing) `docker_proxy_teardown_spec.sh` (task 001),
`docker_proxy_dropped_profile_spec.sh` (task 003), and
`docker_proxy_explicit_profile_override_spec.sh` (task 004) — none of their
scenarios should be affected by this refinement (`stop`/`delete`/`clean`
stay unconditional; task 004's `start --profile base` scenario already has
`CONFIG_FLAGS_PROVIDED=true`, so it stays correctly excluded under the new
rule too).

### 5. Unit-level predicate coverage

Extend (or add alongside) `should_force_proxy_label_fallback()`'s existing
unit `Describe` block to enumerate the CMD × CONFIG_FLAGS_PROVIDED matrix:
`stop`/`delete`/`clean` → true regardless of `CONFIG_FLAGS_PROVIDED`;
`fix-ssh`/`start`/`enter`/`up` → true only when `CONFIG_FLAGS_PROVIDED`
is not `"true"`, false when it is; every other CMD → false regardless.

### 6. Log the two non-blocking round-4 findings as followups, do not fix them here

Round 4 also surfaced two findings that do **not** block this task and are
**out of scope** for this task's own diff:

- **arch-review-003** (missing `--remove-orphans` on the `start`/`enter`
  recreate `up -d`, `src/index.sh`, and `create`'s `up -d`, `src/create.sh`):
  leaves the docker-socket-proxy sidecar running as an orphan even when an
  explicit capability-drop correctly updates `EFFECTIVE_PROXY`/the label.
  Real, but a separate cleanup-hygiene gap, not a correctness regression this
  task needs to fix.
- **efficiency-001** (redundant same-container `docker inspect` calls across
  `restore_saved_config()` and `is_docker_proxy_label_true()` for the four
  teardown/preserve commands): a real but non-blocking consolidation
  opportunity.

Do not fix either in this task's diff. Confirm both are already recorded in
`plan/followups.yaml` (tagged `fix-orphaned-sidecar-teardown`) by the time
this task starts — if either is missing, that's the manager's gap to close
via `followups_add`, not something to backfill from inside this task.

## Validation

- `make build` after any `src/` edits.
- `make lint` — shellcheck stays clean.
- `make test.unit` passes, including the new/extended
  `should_force_proxy_label_fallback()` predicate matrix tests.
- The two new live-Docker regression tests (requirements 2 and 3) both pass,
  each A/B-verified against task 004's merge commit (`a16c5c1`) via a
  disposable detached git worktree (fails pre-fix, passes post-fix).
- `docker_proxy_teardown_spec.sh`, `docker_proxy_dropped_profile_spec.sh`,
  and `docker_proxy_explicit_profile_override_spec.sh` all still pass
  unmodified.
- Grep-verify nounset/quoting handling in any touched code remains correctly
  guarded.

## Metadata

architectural_impact: true

## Assumptions

- A live, reachable Docker daemon is available for the two new integration
  tests; a unit-level mocked-docker equivalent is an acceptable alternative
  if it adequately proves the compose-file-list/label outcome without a real
  container recreate (mirroring task 002's precedent) — same latitude tasks
  002–004 were given.

## References

- `plan/phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md`
- `plan/phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md`
- `plan/phase-01-fix-orphaned-sidecar-teardown/003-fix-capability-loss-on-profile-drop.md`
- `plan/phase-01-fix-orphaned-sidecar-teardown/004-scope-proxy-label-fallback.md`
  — the task whose `CMD`-only gating this task refines.
- `src/utils.sh` — `should_force_proxy_label_fallback()`,
  `is_docker_proxy_label_true()` (unchanged, reused as-is),
  `restore_saved_config()`.
- `src/index.sh` — the `EFFECTIVE_PROXY` fallback block (guard site), the
  `start`/`enter` dispatch branch (`is_container_running &&
  ! running_config_matches` confirmation gate), `fix_ssh()`'s call site.
- `src/options.sh` — flag parsing confirming `--profile`/`--mode`/etc. are
  not `CMD`-restricted (so `fix-ssh --profile ...` is a real, reachable
  invocation shape).
- `docs/architecture.md` — the "Matches" subsection's "explicit invocation
  always wins" invariant this task extends correctly to `fix-ssh` and
  correctly preserves for bare `start`/`enter`.
- `test/integration/docker_proxy_dropped_profile_spec.sh` (task 003) — the
  pattern to mirror for requirement 2's profile-drift scenario.
- `test/integration/docker_proxy_explicit_profile_override_spec.sh` (task
  004) — the pattern to mirror for requirement 3's explicit-override
  scenario.

## Checkpoint hints

- After `should_force_proxy_label_fallback()` (or its `src/index.sh` call
  site) is widened to consider `CONFIG_FLAGS_PROVIDED` per requirement 1.
- After the bare-start/enter-with-drift regression test (requirement 2) is
  written and A/B-verified.
- After the explicit-fix-ssh-override regression test (requirement 3) is
  written and A/B-verified.
- After confirming tasks 001/003/004's own integration suites still pass
  unmodified.

## Status

**Outcome:** succeeded. Date: 2026-07-10.

Widened `should_force_proxy_label_fallback()` (`src/utils.sh`) to a
two-argument predicate: `$1` is `CMD` as before, `$2` is this invocation's
`CONFIG_FLAGS_PROVIDED`. `stop`/`delete`/`clean` still return true
unconditionally; `fix-ssh`/`start`/`enter`/`up` now return true only when
`$2 != "true"` (`[ "${2:-}" != "true" ]`, nounset-safe); every other CMD
still returns false regardless of `$2`. Updated the call site
(`src/index.sh`'s `EFFECTIVE_PROXY` fallback block) to pass
`"${CONFIG_FLAGS_PROVIDED}"` as the second argument, and rewrote both the
function's doc-comment and the call site's inline comment to state the
corrected rule (no more "NOT start/enter/up/.../create/..." framing).
Also updated the fallback's stderr warning message text (same file, same
diff) since its old wording ("'${CMD}' is a teardown/preserve command") was
no longer accurate once `start`/`enter`/`fix-ssh`/`up` can also enter this
branch under `CONFIG_FLAGS_PROVIDED=false`.

Extended `should_force_proxy_label_fallback()`'s unit `Describe` block
(`test/unit/ai_sandbox_spec.sh`) to the full CMD x CONFIG_FLAGS_PROVIDED
matrix described in Requirement 5 (unset/false/true variants for the four
conditionally-scoped CMDs, unconditional coverage for the three
unconditionally-true and several unconditionally-false CMDs).

Added two new live-Docker integration regression tests:
- `test/integration/docker_proxy_start_drift_spec.sh` (Requirement 2, gap
  1): creates a docker-capable instance on a throwaway custom profile,
  stops it, deletes the profile file to make it unresolvable, then runs a
  bare `start` (no `--profile`) and asserts the recreated container's
  `ai.sandbox.docker-proxy` label is still `true` and `DOCKER_HOST` still
  resolves.
- `test/integration/docker_proxy_fix_ssh_explicit_override_spec.sh`
  (Requirement 3, gap 2): creates a docker-capable instance, runs `fix-ssh
  --profile base`, and asserts the recreated container's
  `ai.sandbox.docker-proxy` label is `false` and `DOCKER_HOST` no longer
  resolves.

Both new tests were A/B-verified against task 004's merge commit
(`a16c5c1`) via a disposable detached `git worktree` (mirroring tasks
001-004's precedent): both fail pre-fix (gap 1: label/DOCKER_HOST lost
after the drifted-profile bare start; gap 2: label/DOCKER_HOST incorrectly
retained despite the explicit `--profile base`) and pass post-fix.

`docker_proxy_teardown_spec.sh` (001), `docker_proxy_dropped_profile_spec.sh`
(003), and `docker_proxy_explicit_profile_override_spec.sh` (004) all still
pass unmodified (verified together with the two new suites: 22 examples, 0
failures).

**Validation summary:**
- `make build`: no-op (sources already current from iterative builds during
  implementation); rollup output matches the edited `src/` sources.
- `make lint`: clean (shellcheck across `src/`, `docker/`, `test/`,
  including both new test files).
- `make test.unit`: 253 examples, 0 failures (includes the extended
  predicate matrix).
- New regression tests (Requirements 2 and 3): both pass on current code;
  both A/B-verified to fail pre-fix / pass post-fix against `a16c5c1`.
- `docker_proxy_teardown_spec.sh` / `docker_proxy_dropped_profile_spec.sh` /
  `docker_proxy_explicit_profile_override_spec.sh`: all pass unmodified.
- Grep/read verification of nounset/quoting: `${2:-}` guards the predicate's
  now-optional second positional param; the call site passes
  `"${CONFIG_FLAGS_PROVIDED}"` (always set by `parse_options()`, no `:-`
  needed there, matching `restore_saved_config()`'s existing convention).

**Requirement 6:** confirmed both round-4 non-blocking findings
(arch-review-003's missing `--remove-orphans`, and efficiency-001/002/003's
redundant-inspect-calls) are already recorded in `plan/followups.yaml`
under tag `fix-orphaned-sidecar-teardown` (ids `j7jf` and the entry
immediately preceding it) as of task start; neither was touched in this
task's diff.

No deviations from the task doc's `## Assumptions`; the live-Docker
integration path (not the mocked-docker alternative) was used for both new
tests, mirroring tasks 001/003/004's own precedent for this exact scenario
shape.
