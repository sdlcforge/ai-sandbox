# Task 001: Implement create Command

**Phase:** 3 — Commands — create, list, stop/delete
**Tier:** sonnet-high

## Purpose and scope

Implement the `create` command: the entry point for provisioning a new named sandbox instance. `create` runs the profile-installer, builds the image if needed, starts the container with the full label set, and optionally opens a shell.

The `create` command is the only place where all three new labels (`ai.sandbox.managed`, `ai.sandbox.instance`, `ai.sandbox.profiles`) are written for the first time. Subsequent `start` invocations read `ai.sandbox.profiles` back to reconstruct the profile list without requiring the user to re-specify `--profile` flags.

## Requirements

### New file: `src/create.sh`

Create `src/create.sh` with a `do_create()` function. Add `source ./create.sh` to `src/index.sh` alongside the other module sources.

`do_create()` is called from `index.sh` after the profile-resolution phase has already run (PROFILE_* env vars are set, AI_SANDBOX_IMAGE_TAG is set, COMPOSE_FILES is assembled). It should:

1. **Validate the sandbox name:**
   - Must be non-empty (enforced by parser, but double-check)
   - Must match `[a-zA-Z0-9_-]+` (only alphanumeric, hyphens, underscores)
   - Must not exceed 40 characters (Docker container name limit minus the `ai-sandbox-` prefix)
   - Emit a clear error and return 1 on violation

2. **Check for name collision:**
   - `docker ps -a --filter "name=^ai-sandbox-${SANDBOX_NAME}$" --format '{{.Names}}'`
   - If the container already exists, emit: `"Error: sandbox '${SANDBOX_NAME}' already exists. Use 'ai-sandbox ${SANDBOX_NAME} start' to start it."` and return 1

3. **Ensure image** (calls `ensure_image` from utils.sh — already available)

4. **Compose up with project flag:**
   ```bash
   docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} up -d
   ```
   The new labels in docker-compose.yaml will be written to the container here.

5. **Warn if SSH mount stale** (calls `warn_if_ssh_mount_stale`)

6. **If `ENTER_AFTER_CREATE=true`:** call `start_shell` (defined in utils.sh)

7. **Print confirmation:**
   ```bash
   qecho "Sandbox '${SANDBOX_NAME}' created and started."
   ```

### `src/index.sh` — wire create

Replace the `# TODO: Phase 3` stub from Phase 1 with an actual call:

```bash
if [ "${CMD}" == "create" ]; then
    # Docker preflight, profile resolution, compose assembly have already run.
    do_create || exit $?
    exit 0
fi
```

The `create` command needs the full pipeline (profile resolution, image building, compose assembly) before `do_create` is called, so it should NOT be a short-circuit before the Docker preflight. Move the `create` routing to after the compose-file assembly phase.

### Handling `start` on an existing container (subsequent invocations)

When `CMD == "start"` or `CMD == "enter"` and the container already exists (from a prior `create`), the current pipeline runs profile-installer with whatever `--profile` flags are on the current invocation. To support re-starting with the original profiles, add a **label-read step** in `index.sh` for `start`/`enter` when `CONFIG_FLAGS_PROVIDED=false`:

```bash
# If no config flags on this invocation, read profiles from the existing container label.
if [ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]; then
    if [ "${CONFIG_FLAGS_PROVIDED}" != "true" ] && is_container_running_or_stopped; then
        saved_profiles="$(docker inspect -f \
            '{{index .Config.Labels "ai.sandbox.profiles"}}' \
            "ai-sandbox-${SANDBOX_NAME}" 2>/dev/null || true)"
        if [ -n "${saved_profiles}" ]; then
            IFS=',' read -ra PROFILES <<< "${saved_profiles}"
        fi
    fi
fi
```

Add `is_container_running_or_stopped()` to `utils.sh`:
```bash
function is_container_running_or_stopped() {
    docker inspect "$(sandbox_container_name)" >/dev/null 2>&1
}
```

## Assumptions

- Profile resolution (profile-installer.js) and compose-file assembly run before `do_create()` is called, exactly as they do for the current `enter`/`start` commands.
- `ENTER_AFTER_CREATE` is set by `parse_options()` from Phase 1.
- `SANDBOX_PROFILES` (the comma-separated string for the label) is set by Phase 1's `parse_options()` from the `--profile` flags on the `create` invocation.

## References

- `src/index.sh` — where `do_create` is wired in; `start`/`enter` label-read step
- `src/utils.sh` — `ensure_image`, `start_shell`, `warn_if_ssh_mount_stale`, add `is_container_running_or_stopped`
- Design doc: `/Users/zane/.claude/plans/i-have-a-series-drifting-hedgehog.md` — State section

## Checkpoint hints

1. `do_create()` runs after the full pipeline, so it does not need to call profile-installer itself. The only "extra" thing it does vs. `start` is the name-collision check and the label-write (which the compose file handles automatically via `${SANDBOX_NAME}`).

2. The `is_container_running_or_stopped` function is needed by both the create collision check and the start label-read logic. Add it to `utils.sh`.

3. Pay attention to the `${COMPOSE_FILES}` word-splitting — `# shellcheck disable=SC2086` is already at the top of index.sh and utils.sh for this reason. New `docker compose` calls in `create.sh` need the same disable comment if they use the variable without quotes.

## Validation

```bash
make build
make lint

# Structural check:
grep -n 'do_create\|source ./create' src/index.sh
# Expected: source line and do_create call

grep -n 'is_container_running_or_stopped' src/utils.sh
# Expected: function definition

# Functional smoke (requires Docker Desktop running and Phase 1+2 in place):
bin/ai-sandbox.sh create smoketest
# Expected: container ai-sandbox-smoketest created
docker ps --filter "name=ai-sandbox-smoketest" --format '{{.Names}}\t{{.Label "ai.sandbox.instance"}}'
# Expected: ai-sandbox-smoketest    smoketest
docker inspect -f '{{index .Config.Labels "ai.sandbox.managed"}}' ai-sandbox-smoketest
# Expected: true
bin/ai-sandbox.sh smoketest delete  # cleanup (Phase 3 task 002 implements delete)
```
