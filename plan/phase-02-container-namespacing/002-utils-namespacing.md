# Task 002: Utils and Volume Override Namespacing

**Phase:** 2 — Container Namespacing
**Tier:** sonnet-high

## Purpose and scope

Update `src/utils.sh` and `src/volume-override.sh` so every function that currently hardcodes the container name `ai-sandbox` reads `SANDBOX_NAME` from the environment instead. Also add `list_instances()` to `utils.sh` for use by Phase 3's `list` command.

This is independent of task 001 (compose file) — both can be reviewed in parallel once Phase 1 has landed.

## Requirements

### `src/utils.sh` — container-name references

Every `docker inspect ... ai-sandbox`, `docker rm -f ai-sandbox`, and `docker compose ... exec ... ai-sandbox` that targets the running container must be updated to use the namespaced name.

The effective container name is `"ai-sandbox-${SANDBOX_NAME}"`. Rather than repeating the interpolation everywhere, define a helper at the top of utils.sh (or inline, your preference — but be consistent):

```bash
# Returns the container name for the current SANDBOX_NAME.
function sandbox_container_name() {
    printf 'ai-sandbox-%s\n' "${SANDBOX_NAME}"
}
```

Then replace all occurrences of the literal string `ai-sandbox` that refer to the container (not the image prefix, not `ai-sandbox:*` image tags) with `"$(sandbox_container_name)"` or a local variable populated from it.

**Functions to update:**

1. `is_container_running()` — `docker inspect ... ai-sandbox` → `docker inspect ... "$(sandbox_container_name)"`

2. `running_config_matches()` — all five `docker inspect ... ai-sandbox` calls → use `sandbox_container_name`

3. `cleanup_stale_container()` — two references:
   - `docker inspect ... ai-sandbox` (state check) → `sandbox_container_name`
   - `docker rm -f ai-sandbox` (fallback rm) → `sandbox_container_name`

4. `_ssh_mount_is_fresh()` — `docker inspect ... ai-sandbox` → `sandbox_container_name`

5. `fix_ssh()` — the `up --force-recreate --no-deps ai-sandbox` call: the trailing `ai-sandbox` here is the *service name* (used by `docker compose up --no-deps <service>`), not the container name. The service name stays `ai-sandbox` in the compose file. Leave this as-is or add a comment clarifying it's the service name.

6. `start_shell()` — `docker compose ... exec -u ${HOST_USER} ai-sandbox bash ...` — the `ai-sandbox` here is also the service name. Leave as-is with a comment.

7. `warn_if_ssh_mount_stale()` — calls `_ssh_mount_is_fresh`; no direct container-name reference, but test that the stale-check message still references the right command (`ai-sandbox fix-ssh` → with multi-instance this should mention `ai-sandbox <name> fix-ssh`). Update the warning message to `"Run 'ai-sandbox ${SANDBOX_NAME} fix-ssh' to refresh the socket mount."`.

**Add `list_instances()`:**

```bash
# Emit tab-separated rows for each managed ai-sandbox container:
#   name<TAB>state<TAB>profiles
# Sorted by container name. Uses docker ps -a with label filter.
function list_instances() {
    docker ps -a \
        --filter "label=ai.sandbox.managed=true" \
        --format '{{.Label "ai.sandbox.instance"}}\t{{.State}}\t{{.Label "ai.sandbox.profiles"}}' \
        2>/dev/null \
    | sort
}
```

Note: `docker ps --format` with `.Label "..."` requires Docker Engine 23+. This is acceptable for a macOS-first tool relying on Docker Desktop. If the format string syntax causes issues, fall back to two calls: one for names and one for labels via `docker inspect`.

### `src/volume-override.sh` — per-instance cache path

`generate_volume_override()` currently writes to a path computed in `index.sh`:
```bash
GENERATED_COMPOSE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/docker-compose.generated.yaml"
```

This path is passed as `$1` to `generate_volume_override`. The `index.sh` change (from Phase 1) already updates this to:
```bash
GENERATED_COMPOSE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml"
```

`generate_volume_override()` itself does not hardcode the path — it writes to `$1`. So the only change here is **confirming** that Phase 1's `index.sh` update is correct and that `mkdir -p "$(dirname "${GENERATED_COMPOSE}")"` will create the subdirectory. No code change to `volume-override.sh` is needed if Phase 1 correctly scoped the path; verify this and document in a code comment if so.

If Phase 1's `index.sh` does not yet scope the path, add the scoping here (the two tasks are parallel-eligible but the path must be scoped before Phase 3 `create` can work correctly).

## Assumptions

- `SANDBOX_NAME` is always set and non-empty in the environment when any of these utils functions run (enforced by Phase 1 dispatch).
- Docker service names in compose files remain `ai-sandbox` (not renamed). Only the container name changes.
- `docker ps --format '{{.Label "..."}}` syntax works on Docker Engine 23+ (Docker Desktop on macOS satisfies this).

## References

- `src/utils.sh` — primary file to modify (~303 lines)
- `src/volume-override.sh` — verify/update the cache path
- `src/index.sh` — check GENERATED_COMPOSE path (set in Phase 1)

## Checkpoint hints

1. Use `grep -n 'ai-sandbox' src/utils.sh` first to find every occurrence. Not all of them need changing — `ai-sandbox:*` image name references and comments are fine as-is. Change only the ones that target a running container by its `container_name`.

2. The `start_shell` and `fix_ssh` service-name references are the most common source of confusion. Add inline comments: `# 'ai-sandbox' here is the compose service name, not the container name`.

3. After editing, run `make build && make lint` before considering the task done. Shellcheck will catch any quoting or variable-use errors.

## Validation

```bash
make build
make lint

# Confirm no bare 'ai-sandbox' container-name references remain in utils.sh
# (service-name uses are OK — they'll have a comment):
grep -n "docker inspect.*ai-sandbox[^-]" src/utils.sh
# Expected: 0 matches

grep -n "docker rm.*ai-sandbox[^-]" src/utils.sh
# Expected: 0 matches

# Confirm list_instances is defined:
grep -n 'list_instances' src/utils.sh
# Expected: function definition line

# Unit test: parse_options and sandbox_container_name smoke check
bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; SANDBOX_NAME=mybox; echo "$(sandbox_container_name)"'
# Expected: ai-sandbox-mybox
```

## Status

**Outcome:** succeeded
**Date:** 2026-06-12
**Branch:** phase-02-task-02-utils-namespacing
**Worktree:** `/Users/zane/playground/ai-sandbox/worktree/phase-02-task-02-utils-namespacing`

**Validation summary:**

- `make build` — passed
- `make lint` — passed (shellcheck clean)
- `grep -n "docker inspect.*ai-sandbox[^-]" src/utils.sh` — 0 matches (passed)
- `grep -n "docker rm.*ai-sandbox[^-]" src/utils.sh` — 0 matches (passed)
- `grep -n 'list_instances' src/utils.sh` — function definition at line 307 (passed)
- `bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; SANDBOX_NAME=mybox; echo "$(sandbox_container_name)"'` — output `ai-sandbox-mybox` (passed)

**Files changed:**
- `src/utils.sh` — added `sandbox_container_name()` helper; updated `is_container_running`, `running_config_matches`, `cleanup_stale_container`, `_ssh_mount_is_fresh` to use helper; added service-name comments to `start_shell` and `fix_ssh`; updated `warn_if_ssh_mount_stale` message; added `list_instances()`
- `src/volume-override.sh` — added explanatory comment confirming no code change needed; Phase 1 `index.sh` already scopes `GENERATED_COMPOSE` per-instance

**Assumptions applied:**
- `SANDBOX_NAME` always set and non-empty at call time (Phase 1 enforcement)
- Docker service names remain `ai-sandbox` (only container names change)
- `docker ps --format '{{.Label "..."}}` syntax works on Docker Engine 23+ (Docker Desktop satisfies this)
