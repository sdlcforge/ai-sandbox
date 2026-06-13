# Task 002: Update Help Text and Status for Per-Instance Context

**Phase:** 4 — Command Renames and Cleanup
**Tier:** sonnet-med

## Purpose and scope

Rewrite `src/help.sh` to reflect the new two-tier CLI shape, and update `src/status.sh` so per-instance status queries use `SANDBOX_NAME` to address the correct container. These two files are functionally independent; they're grouped in one task because both are small and mechanical.

## Requirements

### `src/help.sh` — full rewrite

Replace the `print_help()` function body with text that reflects the new CLI:

```
ai-sandbox — run isolated, containerized AI dev environments.

Usage:
  ai-sandbox <command> [args...]         Global command
  ai-sandbox <name> [command] [args...]  Per-instance command (default: enter)
  ai-sandbox                             List all sandboxes

Global commands:
  create <name> [options]  Create and start a new sandbox instance. Options:
                             --profile <name>   Compose a named profile. Repeatable.
                             --mode <mode>      Override mode: mirror or static.
                             --no-isolate-config  Share host ~/.config (read-write).
                             --enter            Open a shell after creating.
  list                     List all managed sandbox instances.
  new-profile              Scaffold a profile YAML from local Claude assets.
                             Requires --name. Options: --name, --mode, --output, --plugins.
  kill-local-ai            Kill host claude/plugin processes that conflict with sandboxes.
  help, -h, --help         Show this message.

Per-instance commands (ai-sandbox <name> <command>):
  enter              Start the container (if needed) and open a shell. (default)
  start              Start in the background; do not attach.
  stop               Pause the container (preserves it and its labels).
  delete             Remove the container (docker compose down).
  attach, connect    Attach a shell to an already-running container.
  status             Show container state, built images, and runability.
  build              Build the image for the resolved profile composition.
  clean              Delete container and remove all ai-sandbox:* images.
  fix-ssh            Recreate the container with the current SSH_AUTH_SOCK mounted.
  user-exec <cmd>    Run <cmd> inside the container as the host user.
  root-exec <cmd>    Run <cmd> inside the container as root.
  <other>            Forwarded to docker compose (e.g. 'logs -f', 'exec').

Options (global):
  --force            Bypass host plugin-conflict pre-flight. Same as AI_SANDBOX_SKIP_PLUGIN_CHECK=1.
  -y, --yes          Skip confirmation prompts before stopping a container.
  -q, --quiet        Quieter output.

Options (status only):
  --json             Emit machine-readable JSON.
  --test-check       Silent pre-flight gate; exits 0 if startable, 1 otherwise.

Environment:
  AI_SANDBOX_SKIP_PLUGIN_CHECK=1       Same as --force.
```

Adjust formatting/wording as needed for readability, but cover all the commands in the new CLI shape.

### `src/status.sh` — per-instance container name

`status.sh` currently hardcodes `ai-sandbox` in:

1. `_status_container_state()` — `docker inspect -f ... ai-sandbox`
   → replace `ai-sandbox` with `"$(sandbox_container_name)"` (function from `utils.sh`)

2. `_status_gather_images()` — this queries images (`docker images ai-sandbox`), not the running container. The image query uses the image *name prefix* `ai-sandbox`, not the container name. Leave this as-is (images are still tagged `ai-sandbox:profile-<hash>`), but add a comment clarifying the distinction.

3. `_render_status_human()` and `_render_status_json()` — no container-name references; leave as-is.

4. `do_status()`:
   - Add `SANDBOX_NAME` to the human output: `echo "Sandbox: ${SANDBOX_NAME}"` as the first line before `"Container: ${state}"`. This makes it clear which instance's status is being shown.
   - The `_image_is_stale` check uses `PROJECT_ROOT` — ensure this is still set correctly in the multi-instance context. It's set in `index.sh` after parsing, so it should be fine.

**New `ai-sandbox <name> status` output format (human):**
```
Sandbox: mybox
Container: running

Images:
  ai-sandbox:profile-abc123
    built:    2026-06-10 14:32:15 +0000 UTC
    ...
```

## Assumptions

- `sandbox_container_name()` is defined in `utils.sh` (Phase 2 task 002).
- `SANDBOX_NAME` is exported and set before `do_status()` is called.
- The `ai-sandbox list` command is handled by `do_list()` in `src/list.sh` (Phase 3), not by `status.sh`.

## References

- `src/help.sh` — full rewrite
- `src/status.sh` — update `_status_container_state()` and `do_status()`
- `src/utils.sh` — `sandbox_container_name()` (Phase 2)

## Validation

```bash
make build
make lint

# Help output includes new commands:
bash -c '__SOURCED__=1 source bin/ai-sandbox.sh; print_help' | grep -E 'create|new-profile|delete|list'
# Expected: lines for each of these commands

# status.sh has no bare 'ai-sandbox' container-name references:
grep -n "inspect.*'ai-sandbox'" src/status.sh
# Expected: 0 matches (the docker images query for 'ai-sandbox' image prefix is OK)

# status output includes Sandbox: line:
grep 'Sandbox:' src/status.sh
# Expected: the echo line in do_status or _render_status_human
```
