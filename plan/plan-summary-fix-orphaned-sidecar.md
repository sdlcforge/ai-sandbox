# Plan Summary: fix-orphaned-sidecar

## What was planned and why

`ai-sandbox <name> delete` (and, as this plan's investigation found, several
sibling per-instance commands) could silently leave Docker resources behind
when an instance was built with the `docker` capability — the
`tecnativa/docker-socket-proxy` sidecar container plus its private
`docker-proxy` Compose network (both defined in
`docker/docker-compose.proxy.yaml`).

Root cause: `delete` already used the architecturally-correct
`docker compose down` (full-project teardown), so the originally-suspected
fix (`--remove-orphans` / full-project scoping) was not the actual defect.
The real bug was upstream — the set of `-f` compose files passed to that
otherwise-correct teardown was derived from the *current invocation's*
profile flags, not from the container's actual persisted composition, because
`restore_saved_config()` (which rehydrates the persisted `docker` capability
from the container's `ai.sandbox.config` label) was only ever invoked for
`start`/`enter`, never for `stop`/`delete`/`clean`/`fix-ssh`/`build`/etc.

The plan was scoped as one implementation phase (root-cause fix plus
regression tests across every affected command) followed by a documentation
phase, since the fix changes behavior `docs/architecture.md` explicitly
documented as scoped to "a bare `start`/`enter`".

## What shipped

### Phase 1 — Fix Orphaned Sidecar Teardown (5 tasks, all merged)

- **Task 1 — Restore Config For Teardown Commands** (merge `55e5469`).
  Extracted a `should_restore_config()` predicate (true for every per-instance
  `CMD` except `create`) and broadened `restore_saved_config()`'s trigger to
  use it, fixing the root cause for `delete`/`stop`/`clean`/`fix-ssh`/etc.
  Also fixed a missing `-p "${COMPOSE_PROJECT}"` flag on `do_build()`/
  `fix_ssh()`. Added integration tests reproducing the orphaned
  sidecar/network on `delete`/`clean`, the not-fully-stopped sidecar on
  `stop`, and the silently-dropped Docker capability on `fix-ssh`, each
  A/B-verified against the pre-fix commit.

- **Task 2 — Fix Robustness Regressions From Restore Broadening**
  (merge `4f9708d`). Round-1 gate review found two regressions in task 1's
  broadening: (a) an unresolvable restored profile name would hard-abort
  every teardown command via `profile-installer.js`'s `die()` — fixed by
  re-validating via `profile_exists()` and dropping with a warning instead;
  (b) a restored `CLEAN_SLATE=true` on `fix-ssh` wasn't triggering credential
  snapshot before `--force-recreate`, destroying SSH credentials with
  nothing to replace them — fixed by adding `fix-ssh` to the
  credential-snapshot `CMD` guard.

- **Task 3 — Fix Capability Loss When Restore Drops An Unresolvable Profile**
  (merge `4fa1bc2`). Round-2 review found task 2's graceful-degradation fix
  reintroduced the capability-loss bug in a narrower scenario: when the
  restore path drops an unresolvable profile, the docker capability was lost
  again for that invocation. Fixed via `is_docker_proxy_label_true()` — a
  fallback that reads the container's persisted `ai.sandbox.docker-proxy`
  label as an authoritative signal, forcing `EFFECTIVE_PROXY=true` when the
  label says so but this invocation's profile resolution would say otherwise.

- **Task 4 — Scope Proxy-Label Fallback To Teardown Commands Only**
  (merge `a16c5c1`). Round-3 review (security + architecture lenses) found
  task 3's fallback applied unconditionally to *every* `CMD`, including
  `start`/`enter` — silently re-granting the docker capability (network
  access to a documented container-escape-vector sidecar) even when a user
  explicitly removed it via `--profile`, violating the architecture's
  "explicit invocation always wins" invariant. Fixed via
  `should_force_proxy_label_fallback()`, scoping the fallback to
  `{stop, delete, clean, fix-ssh}` only, plus a diagnostic warning whenever
  the fallback actually fires.

- **Task 5 — Gate The Proxy-Label Fallback On Explicit-Invocation, Not CMD
  Alone** (merge `1e7e820`). Round-4 review found task 4's `CMD`-only gating
  was itself the wrong axis: a *bare* `start`/`enter` (no explicit flag) with
  a drifted profile would silently lose the capability again (not actually an
  explicit override), while an explicit `fix-ssh --profile <non-docker>`
  couldn't actually drop the capability (silently overridden). Fixed by
  widening the predicate to a `CMD` × `CONFIG_FLAGS_PROVIDED` matrix:
  `stop`/`delete`/`clean` stay unconditional; `fix-ssh`/`start`/`enter`/`up`
  apply the fallback only when `CONFIG_FLAGS_PROVIDED != "true"`.

  Phase 1 was gated by **five** phase-review rounds (correctness, efficiency,
  security, architecture-conformance) — each of the first four surfaced a
  real regression or scope gap that the next task fixed; round 5 confirmed
  the phase clean.

### Phase 2 — Documentation Updates (1 task, merged)

- **Task 1 — Update Architecture Docs** (merge `d835c5d`). Updated
  `docs/architecture.md`'s "Restore" and "Docker access: proxy, not socket or
  DinD" sections to describe the final, cumulative behavior across all five
  phase-1 tasks, and added a cross-reference in the "Matches" subsection
  presenting the label fallback as a worked example of the "explicit
  invocation always wins" invariant. Confirmed
  `docs/ai-sandbox-profiles-spec.md` needed no changes. Reviewed clean
  (correctness lens verified every doc claim against the actual source and
  unit-test matrix).

### Ad-hoc follow-ons (outside the plan's task list, merged onto the plan branch)

- Fixed a stale `src/index.sh` comment (near `AI_SANDBOX_CONFIG_B64`) that
  still described `restore_saved_config()` as scoped to "bare start/enter",
  flagged by phase 2's implementation agent as out of scope for its
  docs-only task.

## Key decisions

- The original bug report's hypothesis (`delete` needs `--remove-orphans` or
  full-project-scoped teardown) was investigated and **rejected** — `delete`
  already used the correct `docker compose down`; the defect was the
  compose-file *selection*, not the teardown command itself.
- `stop`/`delete`/`clean` were deliberately kept **unconditional** in the
  final label-fallback gating (task 5): these commands don't recompose
  anything a `--profile` flag could meaningfully redirect, so there's no
  legitimate "explicit override" story for them — they must always act on
  whatever composition actually exists.
- `fix-ssh`/`start`/`enter`/`up`, by contrast, **do** recompose the
  container, so they needed the `CONFIG_FLAGS_PROVIDED`-sensitive gating to
  honor genuine explicit overrides while still protecting bare
  restore/resume invocations from profile drift.
- Two cleanup-hygiene / efficiency findings (missing `--remove-orphans` on
  `start`/`enter`/`create`'s recreate; redundant same-container `docker
  inspect` calls across the fallback machinery) were deliberately **not**
  fixed in-plan — confirmed real but non-blocking, and deferred to
  `plan/followups.yaml` per the manager operating protocol's triage bar.

## Follow-up items

Carried forward in `plan/followups.yaml` (tag `fix-orphaned-sidecar-teardown`
unless noted):

- **`iLwl`** — missing `--remove-orphans` on `start`/`enter`/`create`'s
  `docker compose up -d` leaves the sidecar running as an orphan even after a
  correct capability-drop (cleanup-hygiene gap, not a correctness bug).
- **`j7jf`** — redundant same-container `docker inspect` calls across
  `restore_saved_config()`/`is_docker_proxy_label_true()` for
  `stop`/`delete`/`clean`/`fix-ssh`; plus two minor test-suite efficiency
  nits (a loop-invariant re-derivation, and two integration `Describe` blocks
  that could share one instance).
- **`zSn1`** — `docker_proxy_fix_ssh_explicit_override_spec.sh` (task 5)
  could reuse an existing instance/be mocked instead of its own live-Docker
  create/delete cycle — a deliberate, task-doc-permitted choice, not an
  oversight.
- **`ragj`** — three pre-existing, unrelated `.md` files not reachable from
  `README.md` (`next-steps.md`, `profiles/README.md`, a test-fixture
  `SKILL.md`), surfaced only because phase-review's link-chain check runs
  against the whole repo; confirmed pre-existing at this plan's baseline.
- **`1C2m`** — a pre-existing, unrelated latent bug in `do_create()`
  (`src/create.sh`): invoked as `do_create || exit $?`, which suppresses
  `errexit` for the whole function body under bash's documented `set -e`
  exception, so a real creation failure could be silently swallowed.
- **`DvGv`** — environmental note: the docker-capable integration suite
  shares a single, non-project-scoped, fixed sidecar container name across
  the whole suite and across any concurrently-running `ai-sandbox`
  worktree/branch — worth awareness for future parallel-dispatch runs.
- Several pre-existing, unrelated integration-suite failures (stale CLI
  grammar in `docker_proxy_spec.sh`/`clean_container_spec.sh`, a retired
  `status` command reference in `lifecycle_spec.sh`, a `qecho()`/`QUIET`
  stdout-leak bug, and a `.gitignore` gap for stray log files) were
  reconfirmed identical at each task's baseline throughout the plan — not
  newly introduced, already tracked (`AQag`/`ps6H`/`jWIn`/`Ia7w`/`fXCK`/
  `MVL1`/`n58c`/`68bH`).

## Final Task State

# TODO

## Purpose and scope

Tracking document for the active plan.

## Tasks

### Phase 01 — Fix Orphaned Sidecar Teardown

- [x] [001-restore-config-for-teardown-commands.md](./phase-01-fix-orphaned-sidecar-teardown/001-restore-config-for-teardown-commands.md) — tier `sonnet-high` · branch `phase-01-task-01-restore-config-teardown-comman` · commit `c96efe2` · merge `55e5469c24b1caa172538b150fdf9bd08d2b0bdc`
- [x] [002-fix-review-regressions.md](./phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md) — tier `sonnet-high` · branch `phase-01-task-02-fix-review-regressions` · commit `55b05fe` · merge `4f9708dfa7e7441f4dd3ab2ef6a26f954a5ae5ed`
- [x] [003-fix-capability-loss-on-profile-drop.md](./phase-01-fix-orphaned-sidecar-teardown/003-fix-capability-loss-on-profile-drop.md) — tier `sonnet-high` · branch `phase-01-task-03-fix-capability-loss-on-profile` · commit `cc12d8d` · merge `4fa1bc2912d87b242f5524579cb3e3e1eb8b92a9`
- [x] [004-scope-proxy-label-fallback.md](./phase-01-fix-orphaned-sidecar-teardown/004-scope-proxy-label-fallback.md) — tier `sonnet-high` · branch `phase-01-task-04-scope-proxy-label-fallback` · commit `716d157` · merge `a16c5c1ad79efb4f93f79e82a54c6b42f0ac8a70`
- [x] [005-gate-label-fallback-on-explicit-invocation.md](./phase-01-fix-orphaned-sidecar-teardown/005-gate-label-fallback-on-explicit-invocation.md) — tier `sonnet-high` · branch `phase-01-task-05-gate-label-fallback-on-explici` · commit `b580a52` · merge `1e7e820e0323c7fc6bfb17fc2998d9b59895c99f`

### Phase 02 — Documentation Updates

- [x] [001-update-architecture-docs.md](./phase-02-doc-updates/001-update-architecture-docs.md) — tier `sonnet-high` · branch `phase-02-task-01-update-architecture-docs` · commit `bdccd55` · merge `d835c5d90397dbb4148a5d64f9e2525626e150c1`
