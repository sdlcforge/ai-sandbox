# Task 001: Options and Dispatch

**Phase:** 1 — CLI Parsing and Dispatch
**Tier:** sonnet-high

## Purpose and scope

Rework `src/options.sh` and `src/index.sh` to implement the new two-tier CLI shape. This is the foundation every subsequent phase depends on. Nothing else can land until parsing and dispatch correctly distinguish global commands from per-instance commands.

The new shape:

```
# Global commands (first arg matches one of these exactly)
ai-sandbox create <name> [--profile <name>]... [--mode mirror|static] [--no-isolate-config] [--enter]
ai-sandbox list
ai-sandbox help
ai-sandbox kill-local-ai
ai-sandbox new-profile [flags]

# Per-instance commands (first arg is sandbox name, second is command)
ai-sandbox <name>              # shorthand: enter
ai-sandbox <name> enter
ai-sandbox <name> start
ai-sandbox <name> stop
ai-sandbox <name> delete
ai-sandbox <name> attach
ai-sandbox <name> connect
ai-sandbox <name> fix-ssh
ai-sandbox <name> build
ai-sandbox <name> user-exec <cmd>
ai-sandbox <name> root-exec <cmd>
ai-sandbox <name> status
ai-sandbox <name> clean
ai-sandbox <name> <other>     # passthrough to docker compose

# Bare invocation
ai-sandbox                     # → list
```

## Requirements

### `src/options.sh` — `parse_options()`

**Remove:**
- The old logic where the first non-flag arg becomes `CMD` directly
- The `CMD_EXPLICIT` / bare-invocation-auto-promote-to-connect logic (that now lives as a simpler "no args → list" rule in index.sh)
- `STATUS_JSON` and `STATUS_TEST_CHECK` from `parse_options()` — these become per-instance flags parsed after the sandbox name is resolved (they still need to exist, just moved to after sandbox-name resolution)

**Add:**
- `SANDBOX_NAME` global — empty string for global commands, populated with the instance name for per-instance commands
- `SANDBOX_PROFILES` global — comma-separated profile list for the `create` command's `--profile` args (used to stamp the `ai.sandbox.profiles` label); distinct from `PROFILES` array (which is still used for the current invocation's profile resolution)
- Parsing rule:
  1. Consume leading flags that apply before the command word (`--force`, `--yes`, `-y`, `--quiet`, `-q`, `--help`, `-h`)
  2. Peek at the first non-flag arg:
     - If it matches a global command (`create`, `list`, `help`, `kill-local-ai`, `new-profile`): set `CMD` to that word, continue parsing remaining args as command-specific flags/args
     - Otherwise: treat it as `SANDBOX_NAME`, consume the next non-flag arg as `CMD` (defaulting to `enter` if absent), parse remaining as `ARGS`
  3. For `create`: parse `--profile`, `--mode`, `--no-isolate-config`, `--enter` from remaining args
  4. For per-instance commands: parse `--profile`, `--mode`, `--no-isolate-config`, `--json`, `--test-check` from remaining args (these affect how the instance is operated)

**Export:** `SANDBOX_NAME`, `SANDBOX_PROFILES`, `CMD`, `ARGS`, `PROFILES`, `MODE_OVERRIDE`, `NO_ISOLATE_CONFIG`, `CONFIG_FLAGS_PROVIDED`, `AUTO_YES`, `ENTER_AFTER_CREATE`, `STATUS_JSON`, `STATUS_TEST_CHECK`, `QUIET`

**New globals:**
- `ENTER_AFTER_CREATE` — `true` if `--enter` was passed to `create`
- `SANDBOX_PROFILES` — comma-joined list of `--profile` values from a `create` invocation; used to stamp the `ai.sandbox.profiles` label

**Reserved names validation:** If `SANDBOX_NAME` would be set to one of the global command words, emit an error: `"Error: '<name>' is a reserved name and cannot be used as a sandbox name"` and exit 1.

**QUIET default:** Same logic as before — `status` is verbose, everything else defaults quiet.

### `src/index.sh` — dispatch phases

**Remove:**
- The "auto-promote bare invocation to connect" block (replaced by "no args → list")
- The hardcoded `create-profile` dispatch (replaced by `new-profile` in Phase 4; for now, keep create-profile as an alias during transition OR remove it outright — prefer removing since no backward compat is planned)

**Add / change:**

1. After `parse_options "$@"`:
   - If `CMD == "list"` or (`CMD == ""` and `SANDBOX_NAME == ""`): call `do_list` (Phase 3 implements this; stub as `echo "list not yet implemented"` in this task), then exit 0.
   - If `CMD == "help"`: call `print_help`, exit 0.
   - If `CMD == "kill-local-ai"`: call `kill_local_ai`, exit 0.
   - If `CMD == "new-profile"`: call `new_profile "${ARGS[@]}"`, exit 0. (Phase 4 renames the file; in this task wire to `create_profile` temporarily to keep the script functional, noting it will be updated in Phase 4.)
   - If `CMD == "create"`: route to create flow (Phase 3 implements; stub for now).
   - Otherwise: per-instance flow with `SANDBOX_NAME` set.

2. Per-instance flow: all compose invocations, `is_container_running`, `start_shell`, etc. must receive `SANDBOX_NAME` context. After Phase 2 lands, those functions will accept it. For this task, ensure `SANDBOX_NAME` is exported so Phase 2 can consume it.

3. Export `SANDBOX_NAME` early so it's available to all sourced modules.

4. The `GENERATED_COMPOSE` path changes to `${XDG_CACHE_HOME:-$HOME/.cache}/ai-sandbox/${SANDBOX_NAME}/docker-compose.generated.yaml` (Phase 2 / volume-override will finalize this, but `index.sh` sets the path).

5. All `docker compose` calls in index.sh must include `-p "ai-sandbox-${SANDBOX_NAME}"` (the project flag). Add a `COMPOSE_PROJECT` variable set to `"ai-sandbox-${SANDBOX_NAME}"` and pass it as `-p "${COMPOSE_PROJECT}"` to every `docker compose` call in the file.

6. The `user-exec` and `root-exec` dispatch lines currently reference the service name `ai-sandbox` literally — update to `"ai-sandbox-${SANDBOX_NAME}"` (the container name, not the service name; check whether compose exec uses service or container names — it uses the service name from the compose file, which stays `ai-sandbox` in the service key; only `container_name` changes).

## Assumptions

- The service name key inside `docker-compose.yaml` remains `ai-sandbox` (the compose service name). Only the `container_name:` value changes to `ai-sandbox-${SANDBOX_NAME}`. Compose exec targets the service name, not the container name, so existing `exec -u ${HOST_USER} ai-sandbox` calls are correct after Phase 2 updates `container_name`.
- `new-profile` command dispatch can temporarily call `create_profile` (the existing function name) to avoid a cross-phase dependency; Phase 4 will rename the function.
- `create` command body is stubbed in this task (just a `# TODO: Phase 3` placeholder) so index.sh is syntactically correct and routes correctly.
- `list` command body is likewise stubbed.

## References

- `src/options.sh` — current `parse_options()` to replace
- `src/index.sh` — current phase-based dispatch to rework
- Design doc: `/Users/zane/.claude/plans/i-have-a-series-drifting-hedgehog.md`

## Checkpoint hints

This task touches two files with significant inter-dependency:

1. **`src/options.sh`**: Write the new `parse_options()` from scratch rather than patching the old one — the logic change is comprehensive enough that an in-place edit would be harder to review. New function must export all the globals listed above.

2. **`src/index.sh`**: Work top-to-bottom through the existing phase comments. The key structural change is inserting the global-command short-circuits before the Docker preflight, and adding `SANDBOX_NAME` to the per-instance flow. The compose-project flag (`-p "${COMPOSE_PROJECT}"`) must be added to every `docker compose` call — search for `docker compose ${COMPOSE_FILES}` and update all occurrences.

3. **Verify the rollup builds:** After editing, run `make build` to ensure `bin/ai-sandbox.sh` is generated. The existing unit tests will fail on parse_options tests (expected — Phase 5 updates them), but the build must succeed and shellcheck must pass.

## Status

**Outcome:** succeeded
**Date:** 2026-06-12
**Commit:** 534bb28 (branch `phase-01-task-01-options-and-dispatch`)

**Validation summary:**
- `make build` — passed (rollup generates `bin/ai-sandbox.sh` without errors)
- `make lint` (shellcheck) — passed, no issues
- All four manual smoke tests — passed (see Validation section)

**Affected source files (repo-relative):**
- `src/options.sh`
- `src/index.sh`

**Assumptions applied:**
- `new-profile` dispatch temporarily wires to `create_profile` (Phase 4 renames)
- `create` and `list` command bodies are stubbed with echo placeholders
- Compose exec targets the service name `ai-sandbox`, not the container name, so existing exec calls remain correct after Phase 2 updates `container_name`

**Decisions made:**
- `delete` command added to index.sh dispatch alongside `stop` and `clean` (design doc names it; task doc didn't explicitly call it out in dispatch, but it's in the CLI shape spec)
- Deferred (leading) flag scan collects unknown flags as positionals and re-processes them in the command-specific phase, avoiding loss of flags like `--force` that appear after the command word
- `QUIET` is not reset at the top of `parse_options()` — consistent with original behavior; `utils.sh` sets the default and `parse_options` only overrides when QUIET is unset (which doesn't happen in normal sourced usage)

## Validation

```bash
make build
make lint   # shellcheck must pass

# Manual smoke (does not require Docker):
bash -c 'source bin/ai-sandbox.sh; __SOURCED__=1 source bin/ai-sandbox.sh; parse_options create foo --profile base --enter; echo "CMD=$CMD SANDBOX_NAME=$SANDBOX_NAME PROFILES=${PROFILES[*]} ENTER_AFTER_CREATE=$ENTER_AFTER_CREATE"'
# Expected: CMD=create SANDBOX_NAME=foo PROFILES=base ENTER_AFTER_CREATE=true

bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; parse_options mybox stop; echo "CMD=$CMD SANDBOX_NAME=$SANDBOX_NAME"'
# Expected: CMD=stop SANDBOX_NAME=mybox

bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; parse_options list; echo "CMD=$CMD SANDBOX_NAME=$SANDBOX_NAME"'
# Expected: CMD=list SANDBOX_NAME=

bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; parse_options; echo "CMD=$CMD SANDBOX_NAME=$SANDBOX_NAME"'
# Expected: CMD=list SANDBOX_NAME=   (bare invocation → list)
```
