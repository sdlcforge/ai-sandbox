# Restore Config For Teardown Commands

## Purpose and scope

Fix the root cause of orphaned `docker-socket-proxy` sidecar
containers/networks (and related silent capability loss) left behind by
per-instance commands other than `start`/`enter` — `delete`, `clean`, `stop`,
`build`, and `fix-ssh` — when the instance was created with the `docker`
capability (`--profile docker` or a profile declaring
`capabilities: [docker]`). No standard Flow skill covers this bug-fix +
regression-test pattern directly; follow the `## Procedure` below.

**Do not** touch the previously-fixed, unrelated "ARGS unbound variable" bug
for `down` vs `delete` (a shell-nounset issue) — that is already resolved and
out of scope here.

## Requirements

### 1. Root cause (confirmed during planning; re-verify before changing code)

`restore_saved_config()` (`src/utils.sh:139-226`) rehydrates the persisted
profile/mode/marketplace/plugin/clean-slate config — including which
capabilities (e.g. `docker`) are active — from the container's
`ai.sandbox.config` Docker label, but only when its internal guard passes:
`CONFIG_FLAGS_PROVIDED != true` **and** a container (running or stopped)
already exists for `SANDBOX_NAME`. `src/index.sh:135-137` currently gates the
*call site* itself to:

```bash
if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]; then
    restore_saved_config
fi
```

By the time this line runs, `CMD` can only be one of the values reachable
past the global/noun short-circuits and the profile-kind short-circuit (see
`src/index.sh`'s phase comments) — i.e. `create`, or one of
`PER_INSTANCE_COMMANDS` (`src/options.sh:170`): `start enter attach fix-ssh
build user-exec root-exec detail stop delete clean up`, or an arbitrary word
forwarded to the docker-compose passthrough (`src/index.sh:446`).

Every one of those `CMD` values *except* `create` operates on an
already-created instance and should have its compose-file assembly reflect
that instance's actual persisted composition, not just whatever `--profile`
flags (usually none) were passed to this particular invocation.
`restore_saved_config()`'s own internal guard already makes it safe to call
unconditionally for every one of them: it no-ops when the user passed
explicit config flags this run (`CONFIG_FLAGS_PROVIDED == true`, which always
wins) and no-ops when no container exists yet. `create` is the one CMD that
should be excluded — it is deliberately provisioning fresh state and already
rejects name collisions in `do_create()` (`src/create.sh:32-39`) before a
restored value would ever be consulted; calling `restore_saved_config()` ahead
of that check would be a harmless but pointless `docker inspect`.

### 2. Fix

Broaden the trigger in `src/index.sh` so `restore_saved_config()` runs for
every `CMD` except `create`. Extract the "should this CMD attempt a restore"
decision into a small, named, unit-testable predicate function in
`src/utils.sh` (e.g. `should_restore_config()`), following the project's
existing pattern of small boolean helpers (`profile_has_capability()`,
`is_container_running()`, etc.) — **this is necessary, not optional**: the
current call site lives after the `${__SOURCED__:+return}` guard
(`src/index.sh:20`), so it is invisible to `test/unit/` specs that `Include
"$PWD/bin/ai-sandbox.sh"` with `__SOURCED__=1`; only a real function call can
be unit-tested. `src/index.sh`'s call site should reduce to a single
conditional invoking the predicate, e.g.:

```bash
if should_restore_config "${CMD}"; then
    restore_saved_config
fi
```

Choose whatever function/parameter shape is idiomatic for the file, but the
mapping must be: every `CMD` value reachable at that point in the pipeline
returns true from the predicate, **except** `create`, which returns false.

### 3. Related fix discovered during the audit: missing `-p` flag

Add `-p "${COMPOSE_PROJECT}"` to the two `docker compose` invocations that
currently omit it:

- `do_build()` — `src/utils.sh:402`: `docker compose ${COMPOSE_FILES} build --ssh "default=${SSH_AUTH_SOCK}"`
- `fix_ssh()` — `src/utils.sh:503`: `docker compose ${COMPOSE_FILES} up -d --force-recreate --no-deps ai-sandbox`

Every other `docker compose` call site in the codebase (`src/index.sh`,
`src/create.sh`, `start_shell()` in `src/utils.sh`) already passes
`-p "${COMPOSE_PROJECT}"`. Without it, `build`/`fix-ssh` resolve against
Compose's default project-name derivation instead of the named instance's
actual project scope — the same class of bug the existing `start_shell()`
regression test (`test/unit/ai_sandbox_spec.sh:181-193`) already caught and
fixed for `exec`. Keep the existing `# shellcheck disable=SC2086` word-split
comment already present at the top of `src/utils.sh` (do not duplicate it).

### 4. Regression tests — integration (live Docker; tag `integration`)

Extend `test/integration/docker_proxy_spec.sh` (or add a new
`test/integration/docker_proxy_teardown_spec.sh` if that reads more cleanly)
with scenarios that reproduce the bug **without re-passing `--profile
docker`** on the follow-up command — this is the crux of the defect,
since the existing suite's `stop_with_proxy` helper (line 13-16 of
`docker_proxy_spec.sh`) currently masks the bug for `stop` by re-specifying
`--profile docker` on every call. Cover, using a dedicated named instance
(not the shared default one, to avoid cross-spec collisions — follow
`clean_container_spec.sh`'s `credtest` naming pattern):

1. **`delete` orphans nothing.** Start a docker-capable instance, then run
   `ai-sandbox <name> delete` with **no** `--profile` flag. Assert the
   `ai-sandbox-docker-proxy`-equivalent sidecar container for that instance's
   compose project no longer exists (`docker ps -a --filter
   "label=com.docker.compose.project=ai-sandbox-<name>"` returns nothing, or
   an equivalent name/label filter — use whichever the sidecar's
   `container_name: ai-sandbox-docker-proxy` in
   `docker/docker-compose.proxy.yaml` actually resolves to per-project; verify
   this empirically rather than assuming) and the project's `docker-proxy`
   network is gone (`docker network ls --filter
   "label=com.docker.compose.project=ai-sandbox-<name>"` or a name-based
   filter).
2. **`clean` orphans nothing.** Same assertions as (1) for `ai-sandbox <name>
   clean` with no `--profile` flag.
3. **`stop` actually stops the sidecar.** Start a docker-capable instance,
   run `ai-sandbox <name> stop` with no `--profile` flag, and assert the
   sidecar container's state is `exited`/stopped, not `running`.
4. **`fix-ssh` preserves Docker capability.** Start a docker-capable instance,
   run `ai-sandbox <name> fix-ssh` with no `--profile` flag, then assert
   Docker access still works post-recreate (e.g. `ai-sandbox <name> user-exec
   zsh -c 'echo $DOCKER_HOST'` still resolves to
   `tcp://docker-socket-proxy:2375`, or `docker --version` still succeeds
   inside the container) rather than silently losing it.

Clean up every container/network/image created by these new tests in an
`AfterAll`/`After` hook, mirroring the existing specs' `stop_with_proxy`-style
cleanup pattern (including a `docker rm -f`/`docker network rm` fallback in
case the assertion under test fails and leaves something behind).

Note for context (do not necessarily change unless it naturally falls out of
the fix): `docker_proxy_spec.sh`'s existing `stop_with_proxy` helper re-passes
`--profile docker` on `stop` specifically because of this bug — once the fix
lands, a bare `stop` should work correctly too. Simplifying that helper to
drop the now-unnecessary flag is optional evidence the fix works, not a hard
requirement.

### 5. Regression tests — unit (`test/unit/ai_sandbox_spec.sh`)

1. New `Describe` block for the extracted predicate (e.g.
   `should_restore_config()`) enumerating representative `CMD` values:
   `start`, `enter`, `stop`, `delete`, `clean`, `build`, `fix-ssh`,
   `user-exec`, `root-exec`, `attach`, `detail`, `up` → all true; `create` →
   false.
2. `do_build()` regression test mirroring the existing `ensure_image()`
   tests' `docker()` mocking style (lines ~116-165) and the `start_shell()`
   regression test (lines 181-193): mock `docker()` to capture its argv and
   assert `-p "${COMPOSE_PROJECT}"` appears before `${COMPOSE_FILES}` in the
   `compose ... build` invocation.
3. `fix_ssh()` regression test, same pattern: mock `ssh_preflight()` (or its
   dependencies) as needed and assert `-p "${COMPOSE_PROJECT}"` appears in the
   `compose ... up -d --force-recreate --no-deps ai-sandbox` invocation.

## Validation

- `make build` after any `src/` edits (rolls `src/` into `bin/ai-sandbox.sh`;
  never edit `bin/ai-sandbox.sh` directly).
- `make lint` — shellcheck across `src/`, `docker/`, `test/` stays clean; any
  new `# shellcheck disable=...` includes an inline reason comment.
- `make test.unit` passes, including the new `should_restore_config()` /
  `do_build()` / `fix_ssh()` unit tests.
- `make test.integration` passes, including the new delete/clean/stop/fix-ssh
  teardown regression tests. This target runs `./bin/ai-sandbox.sh status
  --test-check` first (per `AGENTS.md`/`CLAUDE.md`); clear any host-side
  `claude`/plugin-worker conflicts first via `ai-sandbox kill-local-ai` or set
  `AI_SANDBOX_SKIP_PLUGIN_CHECK=1`.
- Confirm each new integration test actually reproduces the bug against the
  pre-fix code (e.g. via a local `git stash`/branch-diff A/B check during
  development, not necessarily committed) before relying on it as a
  regression guard — a test that passes both before and after the fix isn't
  proving anything.
- Manually confirm (or via the test assertions themselves) that no leftover
  `ai-sandbox-docker-proxy`-equivalent container or `docker-proxy`-named
  network remains after each new teardown test case, using `docker ps -a` /
  `docker network ls` scoped to the test instance's compose project.
- Grep-verify `ARGS` handling in any touched code is untouched / still
  correctly guarded (`"${ARGS[@]+"${ARGS[@]}"}"`) — do not reintroduce or
  conflate with the previously-fixed nounset bug.

## Metadata

architectural_impact: true

## Assumptions

- A live, reachable Docker daemon is available in the environment running
  `make test.integration` (per project convention; gated by `status
  --test-check`).
- The exact Docker label/name used to identify the sidecar container and its
  network per compose-project may need empirical verification (e.g. via
  `docker compose config` or a manual `--profile docker start` +
  `docker ps -a`/`docker network ls` inspection) rather than assumed from the
  static YAML alone, since Compose may prefix/scope names by project.
- No existing test currently captures this bug — `docker_proxy_spec.sh`'s
  `stop_with_proxy` helper re-passes `--profile docker` specifically because
  of it, which is why the defect has gone unnoticed until now.

## References

- `docs/architecture.md` — "Docker access: proxy, not socket or DinD" and
  "Config persistence and restore" sections (root-cause context; will be
  updated in Phase 2, not this task).
- `docs/ai-sandbox-profiles-spec.md` — `docker` capability entry (`## docker`
  under "Capabilities reference").
- `docker/docker-compose.proxy.yaml` — authoritative definition of the
  `docker-socket-proxy` service, the `ai-sandbox` service's network/env
  overrides, and the `docker-proxy` network.
- `src/index.sh` — lines 130-137 (restore call site), 268-275 (`EFFECTIVE_PROXY`),
  312-352 (`COMPOSE_FILES` assembly), 423-444 (`stop`/`delete`/`clean`
  dispatch).
- `src/utils.sh` — `restore_saved_config()` (139-226), `do_build()`
  (400-403), `fix_ssh()` (495-505), `profile_has_capability()` (110-119).
- `src/options.sh` — `PER_INSTANCE_COMMANDS` definition (line 170) for the
  authoritative CMD set reachable at the restore call site.
- `test/integration/docker_proxy_spec.sh` — existing proxy integration
  coverage and the `stop_with_proxy` helper that currently masks this bug.
- `test/integration/clean_container_spec.sh` — pattern for a dedicated named
  test instance with `BeforeAll`/`AfterAll` setup/teardown.
- `test/unit/ai_sandbox_spec.sh` — `start_shell()` regression test
  (181-193) as the pattern to mirror for the `-p` flag fix; `restore_saved_config()`
  tests (224+) and `ensure_image()`/`docker()`-mocking tests (116-165) as
  patterns for mocking `docker()`.

## Checkpoint hints

- After landing the `src/index.sh` restore-gate broadening and the extracted
  predicate in `src/utils.sh`.
- After adding the `-p` flag fix to `do_build()`/`fix_ssh()`.
- After the new unit tests pass.
- After the new integration tests pass and orphan-cleanup is confirmed.
