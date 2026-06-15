# Phase 01, Task 01 — `--clean` Flag, State Propagation, and Help Text

## Context

This task adds the `--clean` flag to the CLI layer and propagates its effect through the bash source modules. Downstream phases (compose restructuring, volume suppression) consume the `CLEAN_SLATE` / `AI_SANDBOX_CLEAN_SLATE` state set here.

**Dependencies:** None (first task in the plan).

**Branch convention:** `phase-01-task-01-clean-flag-and-propagation`

## Files to Modify

- `src/options.sh`
- `src/index.sh`
- `src/utils.sh`
- `src/help.sh`

## Step-by-step Instructions

### 1. `src/options.sh` — Initialize and parse `--clean`

**1a. Add `CLEAN_SLATE` to the header comment block**

In the block comment at the top of `parse_options` that lists all globals set by the function, add:

```
#   CLEAN_SLATE   — "true" if --clean was passed (no host ~/.claude or plugin mounts)
```

**1b. Initialize `CLEAN_SLATE` in the defaults section**

In the defaults block at the top of `parse_options` (after `CLI_ENABLE_ALL=false`), add:

```bash
CLEAN_SLATE=false
```

**1c. Add `--clean` case in Phase 3 flag parsing**

In the `case "${rarg}" in` block (Phase 3 of `parse_options`), add a `--clean` case. Insert it after `--enable-all` and before `--enter`:

```bash
            --clean)
                CLEAN_SLATE=true
                CONFIG_FLAGS_PROVIDED=true
                ;;
```

**1d. Add `CLEAN_SLATE` to the final export statement**

At the end of `parse_options`, in the `export` statement, add `CLEAN_SLATE` to the list:

```bash
    export SANDBOX_NAME SANDBOX_PROFILES CMD ARGS PROFILES MODE_OVERRIDE \
           NO_ISOLATE_CONFIG CONFIG_FLAGS_PROVIDED AUTO_YES ENTER_AFTER_CREATE \
           STATUS_JSON STATUS_TEST_CHECK QUIET \
           CLI_MARKETPLACES CLI_PLUGINS CLI_ENABLE_ALL CLEAN_SLATE
```

Also add `CLEAN_SLATE` to the early-return export in the `--help` short-circuit block (the `export` statement in the `if [ "${CMD}" = "help" ]` branch) for consistency.

### 2. `src/index.sh` — Export `AI_SANDBOX_CLEAN_SLATE` and force static mode

**2a. Force `EFFECTIVE_MODE=static` when `--clean`**

The existing mode resolution block is:

```bash
# MODE_OVERRIDE wins; else the profile's mode; else mirror (legacy default).
if [ -n "${MODE_OVERRIDE}" ]; then
  EFFECTIVE_MODE="${MODE_OVERRIDE}"
else
  EFFECTIVE_MODE="${PROFILE_MODE:-mirror}"
fi
export EFFECTIVE_MODE
```

Replace it with:

```bash
# MODE_OVERRIDE wins; else the profile's mode; else mirror (legacy default).
# --clean always forces static mode regardless of MODE_OVERRIDE or profile mode.
if [ "${CLEAN_SLATE:-false}" = "true" ]; then
  EFFECTIVE_MODE=static
elif [ -n "${MODE_OVERRIDE}" ]; then
  EFFECTIVE_MODE="${MODE_OVERRIDE}"
else
  EFFECTIVE_MODE="${PROFILE_MODE:-mirror}"
fi
export EFFECTIVE_MODE
```

**2b. Export `AI_SANDBOX_CLEAN_SLATE`**

Immediately after `export EFFECTIVE_MODE`, add:

```bash
# Export clean-slate flag for downstream consumers (volume-override.sh, labels).
AI_SANDBOX_CLEAN_SLATE="${CLEAN_SLATE:-false}"
export AI_SANDBOX_CLEAN_SLATE
```

### 3. `src/utils.sh` — Update `running_config_matches`

The function currently checks five labels: image, profile-hash, mode, no-isolate-config, and docker-proxy. Add a sixth check for `ai.sandbox.clean-slate`.

**3a. Add `cur_clean` local variable**

In `running_config_matches`, after the `cur_proxy` line, add:

```bash
    cur_clean=$(docker inspect -f '{{index .Config.Labels "ai.sandbox.clean-slate"}}' "${ctr_name}" 2>/dev/null || true)
```

**3b. Add the comparison**

After the `cur_proxy` comparison line, add:

```bash
    [ "${cur_clean:-false}" = "${AI_SANDBOX_CLEAN_SLATE:-false}" ] || return 1
```

### 4. `src/help.sh` — Add `--clean` to help text

In `print_help`, the `create` subcommand options list currently ends with `--enable-all`. Add `--clean` after it:

```
                             --clean            Start with no host ~/.claude bind-mount, no
                                                ~/.config overlay, and no plugin dir mounts.
                                                Implies static mode. Container gets a fresh
                                                empty ~/.claude; Claude Code is still installed.
```

Maintain the existing indentation pattern (30-column option column, wrapped description text aligned to the same column).

## Validation

1. Run `make build` — must exit 0.
2. Run `make lint` (shellcheck) — must exit 0 with no new warnings or disabled checks without inline reason comments.
3. Verify help output: `bin/ai-sandbox.sh --help | grep -- '--clean'` — must print the new flag description.
4. Smoke-test the flag parses correctly (can be done in the unit test phase, but a quick manual check is: `bash -c 'source bin/ai-sandbox.sh; parse_options create mybox --clean; echo CLEAN_SLATE=$CLEAN_SLATE EFFECTIVE_... wait — this must be done via the ShellSpec `Include` pattern, see Phase 03').

## Notes

- `CLEAN_SLATE` follows the same convention as `NO_ISOLATE_CONFIG` (boolean string, defaults to `false`).
- `AI_SANDBOX_CLEAN_SLATE` is the env var name used in docker-compose labels and `volume-override.sh` (set by index.sh; Phase 02 consumes it).
- The `--clean` flag is only meaningful for `create`; like `--enter`, it is silently accepted for other subcommands (the Phase 3 parser does not gate on CMD).
- Do NOT add error-on-conflict logic between `--clean` and `--mode mirror` in V1. If a user passes both, `--clean` wins and static mode is forced. A warning could be added in a later iteration.
