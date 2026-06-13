# Overview: Multi-Instance Sandbox Refactor

## Purpose and scope

`ai-sandbox` currently assumes a single, hardcoded container named `ai-sandbox` running at any time. All commands — `enter`, `stop`, `status`, `user-exec`, etc. — silently target that one container. This works for solo use but breaks the moment a developer wants two sandboxes side by side: one per project, one per client, one for exploration while another runs a long agent job.

This refactor introduces **named sandbox instances**. Each instance is created with `ai-sandbox create <name>` and is thereafter addressed as `ai-sandbox <name> <command>`. Multiple instances coexist on one host because each gets its own Docker container (`ai-sandbox-<name>`) and Compose project (`-p ai-sandbox-<name>`). Images are still shared when two instances happen to use the same profile composition — the `ai-sandbox:profile-<hash>` tagging scheme from the profiles feature already provides this.

State is derived entirely from Docker container labels (`ai.sandbox.managed`, `ai.sandbox.instance`, `ai.sandbox.profiles`), requiring no XDG state files to track which sandboxes exist. `ai-sandbox list` enumerates them via `docker ps -a --filter label=ai.sandbox.managed=true`.

**In scope:**
- New CLI parsing and dispatch for `create <name>` and `<name> <command>` forms
- Container and Compose project namespacing (`ai-sandbox-<name>`)
- New Docker labels and their use in `list`, `start`, and `status`
- New `create` and `list` commands; `stop` becomes pause-not-remove, new `delete` command
- Rename `create-profile` → `new-profile` (file, dispatch, help text)
- Updated `status` with per-instance context
- Updated help text and unit tests

**Out of scope:**
- Integration tests against a live Docker daemon
- Symmetric lockfile enforcement for host/container concurrency
- Any backward-compatibility shim for the old bare-invocation pattern

## Current status

**Note:** This document does NOT track the current state of implementation. Refer to `plan/TODO.md` for live task status.

The codebase as of this plan's authorship (June 2026, after the profiles feature landed) has:

- A single hardcoded container name `ai-sandbox` in `utils.sh`, `status.sh`, and `index.sh`
- `parse_options()` in `options.sh` that treats the first non-flag arg as `CMD` directly, with no concept of a sandbox name
- `docker-compose.yaml` with `container_name: ai-sandbox` and no `ai.sandbox.managed` label
- `src/create-profile.sh` implementing the `create-profile` subcommand
- 61 passing unit tests under `test/unit/ai_sandbox_spec.sh`

## Overview

The work is organized into five sequential phases. Each phase produces a shippable slice that can be merged independently; later phases build on earlier ones.

### Phase 1: CLI Parsing and Dispatch

**Tasks:** 1 (options-and-dispatch)
**Tier:** sonnet-high
**Files touched:** `src/options.sh`, `src/index.sh`

Rework `parse_options()` for the new two-tier CLI shape:
- First arg checked against global commands (`create`, `list`, `help`, `kill-local-ai`, `new-profile`)
- Otherwise first arg is treated as `SANDBOX_NAME`, second arg as `CMD`
- Export `SANDBOX_NAME` and `SANDBOX_PROFILES` globals consumed by the rest of the pipeline
- Bare `ai-sandbox` with no args → `list`
- Remove the old "bare invocation auto-promotes to connect" logic

This is the critical-path foundation; nothing else can land until the new parse shape is in place.

### Phase 2: Container Namespacing

**Tasks:** 2 (compose-and-labels, utils-namespacing)
**Tier:** sonnet-high
**Files touched:** `docker/docker-compose.yaml`, `src/utils.sh`, `src/volume-override.sh`

Make container identity instance-aware:
- `docker-compose.yaml`: parameterize `container_name` to `ai-sandbox-${SANDBOX_NAME}`, add the three new labels
- `utils.sh`: all functions that hardcode `ai-sandbox` (is_container_running, running_config_matches, cleanup_stale_container, _ssh_mount_is_fresh, fix_ssh, start_shell) updated to use `SANDBOX_NAME`; add `list_instances()`
- `volume-override.sh`: scope the generated compose cache path to a per-instance subdirectory

Split into two tasks because the compose-file change and the bash function changes are independent units of work that a reviewer should be able to evaluate separately.

### Phase 3: Commands — create, list, stop/delete

**Tasks:** 2 (create-command, list-stop-delete)
**Tier:** sonnet-high / sonnet-med
**Files touched:** `src/index.sh`, new `src/create.sh`, new `src/list.sh`

Implement the new lifecycle commands:
- `create <name> [--profile ...]... [--mode ...] [--no-isolate-config] [--enter]`: creates the container with labels, optionally opens a shell
- `list`: enumerate managed sandboxes via Docker labels, display state and profile
- `stop` semantics: change from `docker compose down` to `docker compose stop` (pause, keep container and labels)
- `delete`: new command that does what `stop` used to do — `docker compose down` (remove container)
- `clean`: update to remove container then images (was `stop` + rm + image rm)

Split: create is the most complex (new entrypoint, label writing), list/stop/delete is more mechanical.

### Phase 4: Command Renames and Cleanup

**Tasks:** 2 (new-profile-rename, help-and-status)
**Tier:** sonnet-med
**Files touched:** `src/create-profile.sh` → `src/new-profile.sh`, `src/index.sh`, `src/help.sh`, `src/status.sh`, `README.md`

- Rename `src/create-profile.sh` to `src/new-profile.sh`; update the internal function name to `new_profile()`; update dispatch in `index.sh`
- Rewrite `src/help.sh` for the new CLI shape (global commands vs. per-instance commands)
- Update `src/status.sh`: `_status_container_state()` and all label-reading helpers need the instance container name; `do_status()` gains SANDBOX_NAME context

These are coupled by the `index.sh` source list and dispatch strings but conceptually distinct, so split to keep review surface small.

### Phase 5: Tests and QA Gate

**Tasks:** 1 (tests-and-qa)
**Tier:** sonnet-high
**Files touched:** `test/unit/ai_sandbox_spec.sh`

Update and extend the unit test suite:
- Update `parse_options()` tests for the new two-tier CLI (global commands, sandbox-name detection, SANDBOX_NAME export)
- Update container-name-sensitive tests (is_container_running, _ssh_mount_is_fresh, cleanup_stale_container) to pass SANDBOX_NAME
- Add tests for `list_instances()` output
- Add tests for the `create_profile` → `new_profile` rename
- QA gate: `make build && make lint && make test.unit` must all pass

### Critical path

```
Phase 1 (CLI parsing) → Phase 2 (namespacing) → Phase 3 (commands) → Phase 4 (renames) → Phase 5 (tests)
```

All phases are sequential. Phase 2's two tasks are parallel-eligible with each other (compose vs. utils). Phase 4's two tasks are parallel-eligible with each other (new-profile-rename vs. help-and-status).
