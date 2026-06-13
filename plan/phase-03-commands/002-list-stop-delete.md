# Task 002: Implement list, stop Semantics, and delete Command

**Phase:** 3 — Commands — create, list, stop/delete
**Tier:** sonnet-med

## Purpose and scope

Implement the `list` command (enumerate managed sandboxes), change `stop` semantics from "remove container" to "pause container", add the `delete` command (the new "remove container"), and update `clean` accordingly.

This task can proceed in parallel with task 001 (create command), though both are wired into `index.sh`. If they're dispatched to the same agent, combine them; if dispatched to separate agents in the same worktree, coordinate on `index.sh` changes carefully.

## Requirements

### `list` command — `src/list.sh` (new file)

Create `src/list.sh` with `do_list()`. Add `source ./list.sh` to `src/index.sh`.

```bash
function do_list() {
    local rows
    rows="$(list_instances)"  # from utils.sh (Phase 2)

    if [ -z "${rows}" ]; then
        echo "No sandboxes found."
        return 0
    fi

    # Header
    printf '%-20s  %-10s  %s\n' "NAME" "STATE" "PROFILES"
    # Rows
    while IFS=$'\t' read -r name state profiles; do
        [ -z "${name}" ] && continue
        printf '%-20s  %-10s  %s\n' "${name}" "${state}" "${profiles:-<none>}"
    done <<< "${rows}"
}
```

Wire in `index.sh`:
```bash
if [ "${CMD}" == "list" ]; then
    do_list
    exit 0
fi
```

This must be placed as a short-circuit before the Docker preflight — `list` should work even if Docker Desktop is not running (it uses `docker ps`, which fails gracefully when the daemon is down; `do_list` should catch the failure and print "Docker is not running" or just "No sandboxes found.").

### `stop` — change semantics

**Current behavior:** `stop` calls `docker compose down` which removes the container.

**New behavior:** `stop` calls `docker compose stop` which pauses the container, preserving it and its labels.

In `src/index.sh`, find the dispatch for `stop`:
```bash
# Before (current index.sh, combined with clean):
elif [ "${CMD}" == "stop" ] || [ "${CMD}" == "clean" ]; then
    if is_container_running; then
        confirm_stop_running "stop the running sandbox" || exit 1
    fi
    docker compose ${COMPOSE_FILES} down
    # ...clean branch...
```

Split this block:
```bash
elif [ "${CMD}" == "stop" ]; then
    if is_container_running; then
        confirm_stop_running "stop the running sandbox" || exit 1
    fi
    docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} stop
    qecho "Sandbox '${SANDBOX_NAME}' stopped (container preserved)."

elif [ "${CMD}" == "delete" ]; then
    if is_container_running; then
        confirm_stop_running "stop and delete the running sandbox" || exit 1
    fi
    docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} down
    qecho "Sandbox '${SANDBOX_NAME}' deleted."

elif [ "${CMD}" == "clean" ]; then
    if is_container_running; then
        confirm_stop_running "stop and delete the running sandbox" || exit 1
    fi
    docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} down
    # Remove the container by its explicit name in case compose down left it:
    docker rm -f "$(sandbox_container_name)" 2>/dev/null || true
    # Remove all ai-sandbox:* variant images.
    IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' \
        | awk -F: '$1 == "ai-sandbox" {print}' || true)
    if [ -n "${IMAGES}" ]; then
        # shellcheck disable=SC2086 # intentional word-splitting across tags
        docker image rm -f ${IMAGES} >/dev/null 2>&1 || true
        if [ $QUIET -ne 0 ]; then
            echo "deleted images:"
            printf '  %s\n' ${IMAGES}
        fi
    fi
```

Note: The `clean` command currently removes *all* `ai-sandbox:*` images — this is appropriate because images are shared across instances (by composition hash). If you want per-instance image cleanup, you'd need to track which hash an instance used; that's out of scope for this plan. Keep the all-images behavior with a comment.

### Wire `list` and `delete` in `index.sh`

The `list` short-circuit (before Docker preflight) and `delete` dispatch (in the per-instance block) need to be added. Also update the bare-invocation handler to call `do_list` when no SANDBOX_NAME and no CMD is set (set in Phase 1 to route `CMD=list`; this should already be covered, but verify).

### Update `start`/`enter` to handle stopped (not missing) containers

With `stop` now preserving the container, `cleanup_stale_container()` (currently called before `docker compose up -d`) should treat `"stopped"` state differently: a stopped container that matches the current config should be resumed with `docker compose start` rather than torn down and recreated. Or: just let `docker compose up -d` handle it — compose will restart a stopped container without recreating it if the config matches.

The simpler approach: let `docker compose up -d` handle stopped → running transitions. Only remove the container via `cleanup_stale_container` if it's in an error state (`exited`, `dead`, `created` without running). Update `cleanup_stale_container` in `utils.sh`:

```bash
function cleanup_stale_container() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$(sandbox_container_name)" 2>/dev/null) || return 0
    case "$state" in
        running|stopped|paused) return 0 ;;  # healthy states — compose up handles them
        *)
            qecho "Cleaning up stale container (state: ${state})..."
            docker compose -p "ai-sandbox-${SANDBOX_NAME}" ${COMPOSE_FILES} down 2>/dev/null \
                || docker rm -f "$(sandbox_container_name)" 2>/dev/null || true
            ;;
    esac
}
```

Note: Docker uses `"exited"` for a stopped container that ran and stopped. The `docker compose stop` state shows as `"exited"` in `docker inspect`, not `"stopped"`. So the case should be `running|exited|paused` to preserve stopped containers. Verify this against `docker inspect -f '{{.State.Status}}'` output for a compose-stopped container.

## Assumptions

- `list_instances()` in `utils.sh` (Phase 2 task 002) is available.
- `sandbox_container_name()` in `utils.sh` (Phase 2 task 002) is available.
- Phase 1 has set `CMD=list` for bare invocations and `ai-sandbox list`.

## References

- `src/index.sh` — stop/clean dispatch block, list/delete wiring
- `src/utils.sh` — `cleanup_stale_container` update
- Docker docs: `docker compose stop` vs `docker compose down`

## Validation

```bash
make build
make lint

# list with no sandboxes:
bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; SANDBOX_NAME="" do_list 2>/dev/null || echo "no docker"'

# Grep confirms stop uses 'compose stop', not 'compose down':
grep -A5 '"stop"' src/index.sh | grep 'compose stop'
# Expected: matches 'docker compose ... stop' (not 'down')

# Grep confirms delete uses 'compose down':
grep -A5 '"delete"' src/index.sh | grep 'compose down'
# Expected: matches

# cleanup_stale_container preserves exited containers:
grep 'exited\|paused\|running' src/utils.sh | grep 'return 0'
# Expected: the case branch returning 0 for these states
```
