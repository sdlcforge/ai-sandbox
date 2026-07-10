# Scope Proxy-Label Fallback To Teardown Commands Only

## Purpose and scope

Task 003 added a fallback: when this invocation's profile resolution would
set `EFFECTIVE_PROXY=false` but the container's persisted
`ai.sandbox.docker-proxy` label says `true`, force `EFFECTIVE_PROXY=true` for
this invocation. That was correct for the bug it targeted (a
docker-capability-providing profile becoming unresolvable before
`delete`/`stop`/`clean`), but the third phase-1 gate review — independently,
from both the security lens and the architecture-conformance lens — found it
applies far too broadly: it fires unconditionally for **every** per-instance
`CMD`, including `start`/`enter` and the docker-compose passthrough
(`up`/etc.), the commands whose entire documented purpose (per
`docs/architecture.md`'s "Matches" invariant) is to let an explicit,
confirmed invocation change the container's composition — including
deliberately dropping a capability.

**Concrete scenario this task closes:** a user runs
`ai-sandbox myinstance start --profile no-docker` on an instance previously
created with the `docker` capability, specifically to remove Docker-daemon
network access. `CONFIG_FLAGS_PROVIDED=true` so `restore_saved_config()`
correctly no-ops; `profile_has_capability docker` correctly resolves `false`
for this invocation; but task 003's fallback then forces
`EFFECTIVE_PROXY=true` anyway because the persisted label from create time
is still `true`. The recreated container silently keeps network access to
`docker-socket-proxy` and `DOCKER_HOST` — the exact access the user just
explicitly asked to remove, re-persisting the label as `true` again with no
warning. `docker/docker-compose.proxy.yaml`'s own comment documents this
access as an escape vector; silently re-granting it against explicit user
intent is a least-privilege violation with no escape hatch short of a full
`delete` + `create`.

**Do not** touch tasks 001/002/003's own fixes beyond what's needed here —
`should_restore_config()`, the broadened restore call site, the `-p`
additions, the profile-name/`fix-ssh` credential-guard fixes, and
`is_docker_proxy_label_true()` itself are all correct and stay as-is. This
task only narrows *which commands* the label-fallback applies to.

## Requirements

### 1. Scope the fallback to the teardown/preserve command set only (critical/major, high confidence — confirmed by two independent review lenses)

The orphaned-sidecar bug this fallback protects against only ever manifests
via the `docker compose ... down`/`stop` calls made by `delete`, `clean`, and
`stop`, plus the credential-loss-adjacent `--force-recreate` in `fix_ssh()`
(all four of these commands act on an *existing* instance without
necessarily re-specifying its original composition). `start`/`enter`/the
passthrough branch, by contrast, are the commands where an explicit,
user-confirmed composition change (via `running_config_matches()`'s
recreate-confirmation prompt) must be allowed to actually take effect —
"explicit invocation always wins" is an already-documented invariant
(`docs/architecture.md`'s "Matches" subsection) that this fallback currently
violates for those commands.

**Fix:** Add a small named predicate in `src/utils.sh`, mirroring
`should_restore_config()`'s existing shape and doc-comment style — e.g.
`should_force_proxy_label_fallback()` — that returns true only for `CMD` in
`{stop, delete, clean, fix-ssh}` (the exact set that can silently lose the
sidecar/leave it running/lose the recreated container's Docker access if the
fallback doesn't apply) and false for everything else, including
`start`/`enter`/`up`/the passthrough branch/`create`/`detail`/`build`/
`user-exec`/`root-exec`/`attach`. Guard the `EFFECTIVE_PROXY` fallback block
in `src/index.sh` with this predicate instead of applying unconditionally.

(Folding `create`/`detail`/`build`/`user-exec`/`root-exec`/`attach` out of
the true-returning set also resolves a separate minor efficiency finding
from the same review round — the fallback's `docker inspect` was provably
wasted work on `create`, since `do_create()`'s own collision guard means no
prior container/label exists at that point in the pipeline, and on
`detail`, since `do_status()` never consumes `EFFECTIVE_PROXY` at all. No
extra work needed beyond scoping the predicate correctly — this falls out
for free.)

### 2. Warn when the fallback actually overrides EFFECTIVE_PROXY (minor)

Even scoped to the teardown/preserve set, the fallback silently changes
behavior with no diagnostic — unlike its sibling patterns in the same file
(`restore_saved_config()`'s profile-drop warning, the marketplace-scheme
drop warning), which both print a `Warning: ...` to stderr whenever they
override something. Add a one-line stderr warning whenever the fallback
actually flips `EFFECTIVE_PROXY` from `false` to `true`, naming the instance
and noting that the persisted `ai.sandbox.docker-proxy` label is being
honored for this teardown/preserve command over what this invocation's
profile resolution would otherwise produce.

### 3. Regression tests (both directions)

1. **Confirm `start`/`enter` with an explicit capability-removing `--profile`
   actually removes the capability** (the path this task's scoping fix
   protects): create a docker-capable instance, then run
   `enter --profile <a-non-docker-profile>` (or `start`) against it and
   confirm the recreated/re-entered container's compose invocation does
   **not** include `docker/docker-compose.proxy.yaml` — i.e. the explicit
   profile change actually takes effect, not silently reverted. This is the
   scenario the third gate review found untested; task 003's own new tests
   only covered `delete`/`stop`/`clean` with no `--profile` flag, never
   `start`/`enter` with one.
2. **Confirm the teardown/preserve safety net still works** — re-run (or
   confirm still passing) task 003's own `docker_proxy_dropped_profile_spec.sh`
   and task 001's `docker_proxy_teardown_spec.sh`; both must be unaffected by
   this narrowing since they only exercise `delete`/`stop`/`clean`/`fix-ssh`,
   which remain in the predicate's true-returning set.
3. Cover the new predicate at the unit level, mirroring
   `should_restore_config()`'s existing test `Describe` block: enumerate the
   representative `CMD` values and assert `stop`/`delete`/`clean`/`fix-ssh` →
   true, everything else (`start`, `enter`, `up`, `create`, `detail`, `build`,
   `user-exec`, `root-exec`, `attach`) → false.

Confirm the new `start`/`enter` regression test (item 1) actually reproduces
the bug against the code as task 003 left it (before this task's scoping
fix) and passes after — the same A/B technique tasks 001–003 used (a
disposable detached `git worktree` at task 003's merge commit).

### 4. Amend phase 2's doc-update task to cover all of tasks 001–004 (housekeeping, not part of this task's own diff)

`plan/phase-02-doc-updates/001-update-architecture-docs.md`'s Requirements
section currently references only task 001. The second and third gate
reviews both flagged that it should be amended to also reference tasks 002
and 003 before phase 2 runs, so `docs/architecture.md` ends up describing
the final, fully-corrected behavior in one pass rather than needing a
second doc-update round. This amendment is plan-document housekeeping, not
part of this task's code diff — **do not edit that file as part of this
task's own work**; it will be handled by the manager separately before phase
2 is dispatched.

## Validation

- `make build` after any `src/` edits.
- `make lint` — shellcheck stays clean; any new `# shellcheck disable=...`
  includes an inline reason comment.
- `make test.unit` passes, including the new predicate tests and the new
  `start`/`enter`-with-explicit-profile regression test.
- The new live-Docker (or mocked-docker, if a unit-level end-to-end test is
  sufficient to prove the compose-file-list outcome — your call, matching
  the precedent set by tasks 002/003's mixed unit/integration coverage)
  regression test for requirement 3 item 1 passes, confirmed via A/B against
  task 003's merge commit (fails pre-fix — capability silently retained —
  passes post-fix — capability correctly removed).
- Re-run `test/integration/docker_proxy_dropped_profile_spec.sh` (task 003)
  and `test/integration/docker_proxy_teardown_spec.sh` (task 001) — confirm
  all examples in both still pass; this task must not regress either.
- Grep-verify `ARGS`/nounset handling in any touched code remains correctly
  guarded.

## Metadata

architectural_impact: true

## Assumptions

- A live, reachable Docker daemon is available if a live-Docker integration
  test is chosen for requirement 3 item 1; a unit-level mocked-docker
  end-to-end test (mirroring task 002's `When run script` pattern) is an
  acceptable alternative if it adequately proves the compose-file-list
  outcome without needing a real container recreate.

## References

- `plan/phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md`
- `plan/phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md`
- `plan/phase-01-fix-orphaned-sidecar-teardown/003-fix-capability-loss-on-profile-drop.md`
  — the task whose fallback this task narrows in scope.
- `src/utils.sh` — `should_restore_config()` (pattern to mirror for the new
  predicate), `is_docker_proxy_label_true()` (unchanged, reused as-is),
  `restore_saved_config()`'s warning pattern (to mirror for requirement 2).
- `src/index.sh` — the `EFFECTIVE_PROXY` fallback block (guard site),
  `PER_INSTANCE_COMMANDS` dispatch.
- `src/options.sh` — `PER_INSTANCE_COMMANDS` definition, for the
  authoritative CMD set.
- `docker/docker-compose.proxy.yaml` — the sidecar/network this predicate
  protects, and its own security-note comment on the access it grants.
- `docs/architecture.md` — the "Matches" subsection's "explicit invocation
  always wins" invariant this task restores conformance with.
- `test/integration/docker_proxy_dropped_profile_spec.sh` (task 003),
  `test/integration/docker_proxy_teardown_spec.sh` (task 001) — must both
  keep passing unmodified.

## Checkpoint hints

- After the `should_force_proxy_label_fallback()` predicate lands and the
  `src/index.sh` guard site is updated.
- After the warning message (requirement 2) is added.
- After the new `start`/`enter`-with-explicit-profile regression test is
  written and A/B-verified.
- After confirming tasks 001's and 003's own integration suites still pass
  unmodified.
