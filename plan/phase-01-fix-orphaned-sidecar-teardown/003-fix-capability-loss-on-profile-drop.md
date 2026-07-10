# Fix Capability Loss When Restore Drops An Unresolvable Profile

## Purpose and scope

Task 002 fixed a hard-failure regression: when a restored profile name no
longer resolves to a file, `restore_saved_config()` now drops it with a
warning instead of letting `bin/profile-installer.js` hard-`die()` and abort
`delete`/`stop`/`clean`/etc. before dispatch. The second phase-1 gate review
(after task 002 merged) found that this graceful-degradation fix has its own
narrow but real edge case: if the *specific* profile dropped is the one that
was providing the `docker` capability, the invocation silently loses that
capability, `EFFECTIVE_PROXY` becomes `false`, and the compose-file list for
this invocation omits `docker/docker-compose.proxy.yaml` — which is **the
exact orphaned-sidecar bug this entire phase exists to fix**, reintroduced in
a narrower scenario (a docker-capability-providing custom profile becomes
unresolvable between `create` time and a later teardown command).

This task closes that gap and adds the live-Docker integration coverage that
task 002's own `## Validation` section called for but did not deliver (only
unit-level tests were added for task 002).

**Do not** touch task 001's or task 002's fixes themselves beyond what's
needed here — `should_restore_config()`, the broadened `src/index.sh` call
site, the `-p "${COMPOSE_PROJECT}"` additions, and the profile-name /
`fix-ssh` credential-guard fixes are all correct and already merged.

## Requirements

### 1. Capability loss on profile drop (major, medium confidence)

**Root cause:** `restore_saved_config()` (`src/utils.sh`) drops any restored
profile name `profile_exists()` can't resolve. When the dropped profile was
the sole source of the `docker` capability, `PROFILES` ends up not
containing it, `profile_has_capability docker` (consumed via
`bin/profile-installer.js`'s resolved `PROFILE_CAPABILITIES`) returns false
for this invocation, `EFFECTIVE_PROXY` becomes `false`
(`src/index.sh` — the `if profile_has_capability docker; then EFFECTIVE_PROXY=true;
else EFFECTIVE_PROXY=false; fi` block), and `COMPOSE_FILES` omits
`docker/docker-compose.proxy.yaml`. No command in this codebase passes
`--remove-orphans` to `docker compose down`/`stop` (confirmed via grep — no
occurrence), so for `delete`/`clean` (`docker compose ... down`) and `stop`
(`docker compose ... stop`), the sidecar container/network defined only in
the omitted overlay is left behind or left running — the orphaned-sidecar
bug this phase exists to fix.

**Fix:** The container's actual historical Docker-capability status is
already durably recorded independent of profile resolution: the
`ai.sandbox.docker-proxy` container label (already read by
`running_config_matches()` in `src/utils.sh` for the `start`/`enter`
recreate-confirmation check). Use that label as an authoritative fallback
for `EFFECTIVE_PROXY` whenever a container already exists for `SANDBOX_NAME`:
if the label says `true` but the current invocation's resolved profile
composition would otherwise set `EFFECTIVE_PROXY=false`, force
`EFFECTIVE_PROXY=true` (and thus force-include
`docker/docker-compose.proxy.yaml` in `COMPOSE_FILES`) for this invocation,
regardless of whether the profile that originally granted the capability
still resolves. This makes the sidecar/proxy inclusion resilient to profile
drift generally, not just to the specific graceful-degradation path task 002
added — which is appropriate, since the same class of drift (profile
renamed/moved/deleted) could affect `EFFECTIVE_PROXY` even without
`restore_saved_config()`'s profile-drop path being involved (e.g., a
directly-provided `--profile` flag naming a profile that no longer has the
`docker` capability it once had). Scope the fallback to when a container
already exists (mirroring `is_container_running_or_stopped()`'s guard
pattern) — for `create`, there is no prior label to consult and none of this
applies.

Do not force the reverse (label says `false` but current resolution says
`true`) — that direction is not a regression risk (an invocation that
correctly resolves `docker` capability today should get it), so only guard
the "label true, current resolution false" direction.

Choose whichever call site cleanly reads the label (a small new helper
mirroring `running_config_matches()`'s single multi-field `docker inspect`
pattern is preferable to yet another separate `docker inspect` round trip if
one is already being made nearby — check `EFFECTIVE_PROXY`'s computation
site in `src/index.sh` and what's already been read by that point in the
pipeline before adding a new `docker inspect` call).

### 2. Live-Docker integration test for both this fix and task 002's profile-drop scenario (closes a task-002 validation gap)

Task 002's `## Validation` section called for live-Docker `integration`-tagged
tests covering "unresolvable-profile teardown" and "clean-slate fix-ssh
credential preservation," but only unit-level tests (some end-to-end via
`When run script` against the real built binary, with `docker` itself
mocked) were actually added. The fix-ssh credential-preservation scenario's
task doc wording explicitly permitted a mocked unit test as an acceptable
alternative, so that part is not a gap. The profile-resolution scenario's
wording did not offer that alternative explicitly, and this task's own new
behavior (the capability-loss fix above) specifically needs live-Docker
verification to be a meaningful regression guard (`EFFECTIVE_PROXY`/compose
overlay inclusion is exactly the kind of behavior a mocked-`docker` test
cannot fully validate).

Add a live-Docker integration test (tagged `integration`, following
`test/integration/docker_proxy_teardown_spec.sh`'s pattern from task 001 —
dedicated named instance, `BeforeAll`/`AfterAll` setup/teardown):

1. Create a docker-capable instance using a **project-local custom profile**
   (not the bundled `docker` profile) that declares `capabilities: [docker]`
   — e.g. author a throwaway `./profiles/<test-name>-docker.yaml` for the
   test's duration.
2. Delete that profile file (simulating it becoming unresolvable) while the
   instance still exists.
3. Run `delete` (or `stop`/`clean` — pick at least one, ideally covering the
   `down`-based teardown path) with **no** `--profile` flag.
4. Assert: the command succeeds (task 002's fix — no hard-abort), a warning
   about the dropped profile appears, **and** the sidecar container/network
   is properly torn down / not orphaned (this task's fix — the actual
   regression this task closes). Use the same project-label-filter
   assertions `docker_proxy_teardown_spec.sh` already uses for the
   `delete`/`clean` orphan-check.

Confirm this new test fails against the code as task 002 left it (before
this task's fix) and passes after — the same A/B technique tasks 001 and 002
used (a disposable detached `git worktree` at task 002's merge commit).

### 3. Symlinked-profile false-positive drop (minor, optional)

The gate review also surfaced a narrower, non-blocking edge case:
`profile_exists()` (`src/profiles.sh`) deliberately rejects symlinked profile
files (a documented security guard against a symlink planted in a cloned
repo), while `bin/profile-installer.js`'s `findProfile()` follows symlinks
and would successfully load the same path. Task 002 reuses `profile_exists()`
verbatim as its restore-time validation gate, so a restored profile name
that only resolves via a symlink gets spuriously dropped (falls back to
defaults with a warning) even though `profile-installer.js` would have
loaded it fine. The failure direction is safe (over-conservative fallback,
not a crash), so this is optional: at minimum, add a one-line comment on
`restore_saved_config()`'s validation block noting the divergence from
`profile-installer.js`'s symlink-following behavior, for a future reader's
benefit. A full fix (a symlink-following existence check used only for this
validation purpose, distinct from `profile_exists()`'s intentionally-stricter
security semantics used elsewhere) is welcome but not required.

## Validation

- `make build` after any `src/` edits.
- `make lint` — shellcheck stays clean; any new `# shellcheck disable=...`
  includes an inline reason comment.
- `make test.unit` passes, including any new/updated unit tests.
- The new live-Docker integration test (requirement 2) passes, and is
  confirmed via A/B (fails pre-fix against task 002's merge commit, passes
  post-fix).
- Re-run `test/integration/docker_proxy_teardown_spec.sh` (task 001's suite)
  and confirm all 4 scenarios still pass — this task must not regress it.
- Manually confirm (or via the new test's assertions) that no leftover
  sidecar container or `docker-proxy` network remains after the new test's
  teardown scenario.
- Grep-verify `ARGS`/nounset handling in any touched code remains correctly
  guarded.

## Metadata

architectural_impact: true

## Assumptions

- A live, reachable Docker daemon is available for the integration
  regression test.
- The `ai.sandbox.docker-proxy` label is reliably set at container-create
  time for every docker-capable instance (already an existing invariant this
  codebase depends on via `running_config_matches()`; not new to this task).

## References

- `plan/phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md`
  — original orphaned-sidecar fix; this task closes a narrower reintroduction
  of the same bug class.
- `plan/phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md`
  — the profile-drop graceful-degradation fix whose edge case this task
  closes.
- `src/utils.sh` — `restore_saved_config()`, `profile_has_capability()`,
  `running_config_matches()` (existing multi-field `docker inspect` pattern
  to mirror for reading `ai.sandbox.docker-proxy` without an extra round
  trip if avoidable).
- `src/index.sh` — `EFFECTIVE_PROXY` computation, `COMPOSE_FILES` assembly,
  `stop`/`delete`/`clean` dispatch branches.
- `src/profiles.sh` — `profile_exists()` (symlink-rejection behavior, for
  requirement 3).
- `bin/profile-installer.js` — `findProfile()` (symlink-following behavior,
  for requirement 3, context only).
- `test/integration/docker_proxy_teardown_spec.sh` — pattern to mirror for
  the new live-Docker integration test (dedicated named instance,
  `BeforeAll`/`AfterAll`, project-label-filter orphan assertions).
- `docker/docker-compose.proxy.yaml` — `ai.sandbox.docker-proxy` label
  definition and the sidecar/network this fix protects.

## Checkpoint hints

- After the `EFFECTIVE_PROXY` label-fallback fix lands in `src/utils.sh`/`src/index.sh`.
- After the new live-Docker integration test is written and A/B-verified.
- After confirming task 001's own integration suite still passes unmodified.

## Status

**Outcome:** succeeded. Date: 2026-07-10.

- Requirement 1 (capability loss on profile drop): added `is_docker_proxy_label_true()`
  (`src/utils.sh`) — a single-field `docker inspect` of the persisted
  `ai.sandbox.docker-proxy` label, naturally scoped to "a container already
  exists" because the inspect itself fails (and the function returns false)
  when no container exists for `SANDBOX_NAME`, so no separate
  `is_container_running_or_stopped()` round trip was needed. Wired into
  `src/index.sh`'s `EFFECTIVE_PROXY` computation immediately after the
  existing `profile_has_capability docker` check: only forces
  `EFFECTIVE_PROXY=true` when the current resolution says `false` and the
  label says `true` (the one required direction; the reverse is left alone
  per the task doc). No existing "nearby" multi-field `docker inspect` call
  could be reused for this without over-complicating scope (the only nearby
  inspect, inside `restore_saved_config()`, is conditionally skipped
  whenever `CONFIG_FLAGS_PROVIDED=true`, which would miss the
  directly-provided-`--profile`-flag drift scenario the task doc also calls
  out), so a new single-purpose inspect was added instead — see
  `decisions_made` in the structured report for the full reasoning.
- Requirement 2 (live-Docker integration test): added
  `test/integration/docker_proxy_dropped_profile_spec.sh` — creates a
  docker-capable instance via a throwaway project-local custom profile
  (`./profiles/td-capdrop-docker.yaml`), deletes the profile file to
  simulate it becoming unresolvable, then runs `delete` with no `--profile`
  flag and asserts success, the drop warning, and no orphaned sidecar
  container/network. Confirmed via A/B against a disposable detached
  `git worktree` at task 002's merge commit (`4f9708d`): the new test FAILS
  there (2 of 3 examples: orphaned `ai-sandbox-docker-proxy` container and
  `docker-proxy` network both left behind) and PASSES in this worktree
  post-fix (3 of 3). Also added unit-level coverage: an
  `is_docker_proxy_label_true()` `Describe` block and an end-to-end
  `When run script`-based `Describe` block (mocked `docker`, mirroring task
  002's own unit-test pattern) covering `delete`/`stop`/`clean`.
- Requirement 3 (symlinked-profile false-positive drop, optional): took the
  minimum documented option — added a one-line comment on
  `restore_saved_config()`'s validation block (`src/utils.sh`) noting the
  divergence from `bin/profile-installer.js`'s symlink-following
  `findProfile()`. No behavior change (deliberately out of scope per the
  task doc's "optional" framing).
- Validation: `make build`, `make lint` (shellcheck clean, no new
  `# shellcheck disable`s needed), `make test.unit` (229 examples, 0
  failures, including the new/updated ones) all green.
  `test/integration/docker_proxy_dropped_profile_spec.sh` and
  `test/integration/docker_proxy_teardown_spec.sh` (task 001's suite, run
  together, 13 examples) both pass with a live Docker daemon
  (`AI_SANDBOX_SKIP_PLUGIN_CHECK=1` to clear the host-side plugin-conflict
  preflight). Confirmed no leftover `ai-sandbox-docker-proxy` container or
  `*_docker-proxy` network after both suites via `docker ps -a` /
  `docker network ls`. Grep-verified the existing `ARGS[@]+`
  nounset-safe-expansion pattern in `src/index.sh` is unchanged and intact
  around the edited `EFFECTIVE_PROXY` block.
- Full `make test.integration` (whole suite, not just the two files above)
  shows 25 pre-existing failures + 2 errors + 2 warnings unrelated to this
  task (`lifecycle_spec.sh`, `container_spec.sh`, `clean_container_spec.sh`,
  `docker_proxy_spec.sh`) — confirmed identical in nature and count against
  the task 002 merge-commit baseline in the same disposable worktree, so
  these are a pre-existing local-environment issue, not a regression
  introduced here. See `flagged_for_manager` in the structured report.
