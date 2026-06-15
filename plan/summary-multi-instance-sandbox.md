# Plan Session Summary: multi-instance-sandbox

**Date:** 2026-06-12
**Plan slug:** `multi-instance-sandbox`
**Status:** Complete — all 8 tasks shipped across 5 phases.

---

## What Was Planned and Why

`ai-sandbox` originally assumed a single hardcoded container named `ai-sandbox` running at any time. All commands silently targeted that one container, which prevented a developer from running two sandboxes side by side (one per project, one per client, one for exploration alongside a long agent job).

This plan introduced **named sandbox instances**. Each instance is created with `ai-sandbox create <name>` and thereafter addressed as `ai-sandbox <name> <command>`. Multiple instances coexist because each gets its own Docker container (`ai-sandbox-<name>`) and Compose project (`-p ai-sandbox-<name>`). Images continue to be shared when two instances use the same profile composition — the existing `ai-sandbox:profile-<hash>` tagging scheme handles this without change.

Instance state is derived entirely from Docker container labels (`ai.sandbox.managed`, `ai.sandbox.instance`, `ai.sandbox.profiles`), so no XDG state files are needed. `ai-sandbox list` enumerates managed sandboxes via `docker ps -a --filter label=ai.sandbox.managed=true`.

---

## What Shipped

### Phase 1 — CLI Parsing and Dispatch

**Task 001: Options and Dispatch**
Branch: `phase-01-task-01-options-and-dispatch` | Task commit: `534bb28` | Merge: `442f78f`

Rewrote `src/options.sh` (`parse_options()`) and reworked `src/index.sh` for the two-tier CLI shape:
- First non-flag arg checked against global commands (`create`, `list`, `help`, `kill-local-ai`, `new-profile`); otherwise treated as `SANDBOX_NAME` with the next arg as `CMD` (defaulting to `enter`).
- Bare invocation (`ai-sandbox` with no args) routes to `CMD=list`.
- New globals exported: `SANDBOX_NAME`, `SANDBOX_PROFILES`, `ENTER_AFTER_CREATE`.
- `COMPOSE_PROJECT` variable introduced; all `docker compose` calls in `index.sh` pass `-p "${COMPOSE_PROJECT}"`.
- `GENERATED_COMPOSE` path scoped to `~/.cache/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml`.
- `make build` and `make lint` (shellcheck) both passed.

### Phase 2 — Container Namespacing

**Task 001: Docker Compose Parameterization and New Labels**
Branch: `phase-02-task-01-compose-and-labels` | Task commit: `8d6c261` | Merge: `e580ea3`

Updated `docker/docker-compose.yaml`:
- `container_name` parameterized to `ai-sandbox-${SANDBOX_NAME}`.
- Three new labels added: `ai.sandbox.managed: "true"`, `ai.sandbox.instance: "${SANDBOX_NAME}"`, `ai.sandbox.profiles: "${SANDBOX_PROFILES:-}"`.

**Task 002: Utils and Volume Override Namespacing**
Branch: `phase-02-task-02-utils-namespacing` | Task commit: `752fa49` | Merge: `1246d3d`

Updated `src/utils.sh`:
- Added `sandbox_container_name()` helper returning `ai-sandbox-${SANDBOX_NAME}`.
- Updated `is_container_running()`, `running_config_matches()`, `cleanup_stale_container()`, `_ssh_mount_is_fresh()` to use the helper.
- Added `list_instances()` using `docker ps -a --filter label=ai.sandbox.managed=true`.

### Phase 3 — Commands (create, list, stop/delete)

**Task 001: Implement create Command**
Branch: `phase-03-task-01-create-command` | Task commit: `3594383` | Merge: `748b24d`

New file `src/create.sh` with `do_create()`:
- Validates sandbox name (alphanumeric/hyphens/underscores, max 40 chars).
- Checks for name collision via `docker ps -a --filter "name=^ai-sandbox-${SANDBOX_NAME}$"`.
- Calls `ensure_image`, then `docker compose ... up -d`.

Added label-read step in `src/index.sh`: when `CMD=start/enter` and no config flags provided, reads `ai.sandbox.profiles` from the existing container and reconstructs `PROFILES`.

**Task 002: Implement list, stop Semantics, and delete Command**
Branch: `phase-03-task-02-list-stop-delete` | Task commit: `ed1837f` | Merge: `faae6fc`

New file `src/list.sh` with `do_list()` — prints a formatted table of managed sandboxes.

`stop` semantics changed to `docker compose stop` (container preserved). New `delete` command uses `docker compose down`. `cleanup_stale_container()` updated to preserve containers in `exited` state.

### Phase 4 — Command Renames and Cleanup

**Task 001: Rename create-profile to new-profile**
Branch: `phase-04-task-01-new-profile-rename` | Task commit: `5de3124` | Merge: `152130b`

`src/create-profile.sh` renamed to `src/new-profile.sh`; function renamed `create_profile()` → `new_profile()`. README updated.

**Task 002: Update Help Text and Status for Per-Instance Context**
Branch: `phase-04-task-02-help-and-status` | Task commit: `6168217` | Merge: `63e9e04`

`src/help.sh` fully rewritten for two-tier CLI. `src/status.sh` updated to use `sandbox_container_name()` and emit `Sandbox: ${SANDBOX_NAME}`.

### Phase 5 — Tests and QA Gate

**Task 001: Update Unit Tests and QA Gate**
Branch: `phase-05-task-01-update-unit-tests-and-qa-gate` | Task commit: `7a14b3b` | Merge: `4e169f8`

`test/unit/ai_sandbox_spec.sh` updated for two-tier CLI, `sandbox_container_name()`, `list_instances()`, `new_profile()`. Final gate: **73 examples, 0 failures** (`make build`, `make lint`, `make test.unit` all exit 0).

---

## Key Decisions

1. **Label-only state — no XDG state files.** Instance existence is determined entirely from `docker ps -a --filter label=ai.sandbox.managed=true`.

2. **Compose service name stays `ai-sandbox`; only `container_name` is parameterized.** `docker compose exec` targets the service key, so existing exec calls remain correct.

3. **Images are shared across instances.** The `ai-sandbox:profile-<hash>` tagging provides deduplication. `clean` removes all `ai-sandbox:*` images regardless of which instance is targeted.

4. **`stop` preserves the container; `delete` removes it.** `docker compose stop` keeps labels (including `ai.sandbox.profiles`) intact. `cleanup_stale_container` treats `exited` as a healthy state to preserve.

5. **Label-read on `start`/`enter`.** When no `--profile` flags are provided, `index.sh` reads `ai.sandbox.profiles` from the existing container label and reconstructs `PROFILES` before the profile-installer runs.

---

## Follow-Up Items

1. **Integration tests not automated.** Live Docker daemon tests for `create`, `list`, `stop`, `delete` were not added.

2. **Symmetric lockfile enforcement** for host/container concurrency is out of scope and was not addressed.

3. **`ai-sandbox list` when Docker daemon is down** prints "No sandboxes found." rather than a distinct error. A future improvement could distinguish the two states.
