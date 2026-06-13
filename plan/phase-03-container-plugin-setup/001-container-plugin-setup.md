# Phase 03 Task 001 — Container Plugin Setup

**Tier:** `sonnet-high`
**Depends on:** Phase 01 Task 001 (profile schema and installer)
**Parallel-eligible with:** Phase 02 Task 001 (CLI flags)

---

## Purpose and scope

Implement the runtime plugin configuration that runs inside the container. This task covers three changes:

1. **`src/index.sh`** — extract `marketplaces`, `plugins`, and `enable_all_plugins` from `PROFILE_JSON` and export them as environment variables that the compose environment passes into the container.
2. **`src/volume-override.sh`** — auto-mount `file://` marketplace paths as read-only bind mounts in the per-run compose overlay.
3. **`docker/rootfs/etc/cont-init.d/10-plugin-setup`** — s6-overlay init script that reads those environment variables and idempotently registers marketplaces and enables plugins at container start.

Note: Phase 02 also modifies `src/index.sh` (CLI merge step). The task agent for Phase 03 should be aware that Phase 02 touches `src/index.sh` as well. If both tasks are running in parallel worktrees, the Phase 04 merge step will need to reconcile those changes. The Phase 03 agent should scope its `src/index.sh` edits to the env-var export block (after the CLI merge point from Phase 02) to minimize conflict surface.

---

## Requirements

### 1. `src/index.sh` — export env vars into compose

After `PROFILE_JSON` is finalized (after the CLI merge step from Phase 02, or independently extracting the raw installer output if Phase 02 has not yet merged), extract the three fields and export them as environment variables that Docker Compose will pass into the container.

```bash
# Extract plugin-marketplace vars from PROFILE_JSON
AI_SANDBOX_MARKETPLACES="$(printf '%s\n' "${PROFILE_JSON}" \
    | jq -r '(.marketplaces // []) | join(":")')"
AI_SANDBOX_PLUGINS="$(printf '%s\n' "${PROFILE_JSON}" \
    | jq -r '(.plugins // []) | join(":")')"
AI_SANDBOX_ENABLE_ALL_PLUGINS="$(printf '%s\n' "${PROFILE_JSON}" \
    | jq -r '.enable_all_plugins // false')"
export AI_SANDBOX_MARKETPLACES AI_SANDBOX_PLUGINS AI_SANDBOX_ENABLE_ALL_PLUGINS
```

Separator choice: colon (`:`) for joining, consistent with `PATH`-style env vars. The init script will split on `:`. Use newline (`\n`) as the separator if colons are likely to appear in paths — but `file://` paths are host paths where `:` would be unusual on Linux/macOS. If this is a concern, the task agent should choose a separator (e.g., `|`) and document it consistently in both `src/index.sh` and `10-plugin-setup`.

Ensure these variables are also listed in the `docker-compose.yaml` environment passthrough (or the generated compose overlay) so they reach the container. Check how existing env vars like `EFFECTIVE_MODE` are passed and follow the same pattern.

### 2. `src/volume-override.sh` — file:// bind mounts

`generate_volume_override()` in `src/volume-override.sh` writes a per-run compose YAML overlay to `GENERATED_COMPOSE`. Extend it to add bind mounts for each `file://` marketplace path.

Parse `AI_SANDBOX_MARKETPLACES` (split on the chosen separator). For each entry that starts with `file://`, strip the scheme to get the host path:

```bash
_host_path="${_marketplace#file://}"
```

Add the path as a read-only bind mount in the generated compose overlay:

```yaml
services:
  sandbox:
    volumes:
      - type: bind
        source: /host/path/to/plugin
        target: /host/path/to/plugin
        read_only: true
```

Using the same path inside the container as on the host (`source == target`) means `claude plugins marketplace add file:///host/path/to/plugin` resolves correctly inside the container without any path translation.

If `AI_SANDBOX_MARKETPLACES` is empty or contains no `file://` entries, no new volume entries are added (the function is a no-op for this feature).

Shellcheck considerations: array iteration over a colon-separated string uses `IFS`; ensure any `IFS` changes are scoped (use a subshell or restore `IFS` after).

### 3. `docker/rootfs/etc/cont-init.d/10-plugin-setup`

Create a new s6-overlay cont-init script. It runs after `01-setup-ssh` and `02-overlay-config` (numbering scheme: lower numbers run first). Number `10` provides room for future init scripts between `02` and `10`.

The script must be:
- **Executable** (`chmod +x` or created with execute permissions)
- **Idempotent**: check whether a marketplace or plugin is already registered before running the add/enable command
- **Non-fatal on failure**: plugin setup failure should warn but not block container startup (the container should still start even if a marketplace ref is unreachable)
- **Self-contained**: reads only from environment variables, writes only to `~/.claude`

```sh
#!/bin/sh
# 10-plugin-setup: Register Claude Code marketplaces and enable plugins.
# Reads AI_SANDBOX_MARKETPLACES, AI_SANDBOX_PLUGINS, AI_SANDBOX_ENABLE_ALL_PLUGINS
# from the environment. Idempotent — skips already-registered entries.
# Non-fatal: warns on failure but does not block container startup.
set -u

# Nothing to do if no marketplaces or plugins are configured.
if [ -z "${AI_SANDBOX_MARKETPLACES:-}" ] && [ -z "${AI_SANDBOX_PLUGINS:-}" ]; then
    exit 0
fi

_LAST_MARKETPLACE=""

# Register marketplaces
if [ -n "${AI_SANDBOX_MARKETPLACES:-}" ]; then
    # Split on the chosen separator (colon or other)
    _OLD_IFS="${IFS}"
    IFS=":"
    for _marketplace in ${AI_SANDBOX_MARKETPLACES}; do
        IFS="${_OLD_IFS}"
        [ -z "${_marketplace}" ] && continue

        # Idempotency: check if already registered.
        # `claude plugins marketplace list` output format: one ref per line (verify
        # the actual format when implementing; adjust grep pattern accordingly).
        if claude plugins marketplace list 2>/dev/null | grep -qF "${_marketplace}"; then
            printf '[10-plugin-setup] marketplace already registered: %s\n' "${_marketplace}"
        else
            printf '[10-plugin-setup] registering marketplace: %s\n' "${_marketplace}"
            if ! claude plugins marketplace add "${_marketplace}"; then
                printf '[10-plugin-setup] WARNING: failed to register marketplace: %s\n' "${_marketplace}" >&2
            fi
        fi
        _LAST_MARKETPLACE="${_marketplace}"
        IFS=":"
    done
    IFS="${_OLD_IFS}"
fi

# Enable individual plugins
if [ -n "${AI_SANDBOX_PLUGINS:-}" ]; then
    _OLD_IFS="${IFS}"
    IFS=":"
    for _plugin in ${AI_SANDBOX_PLUGINS}; do
        IFS="${_OLD_IFS}"
        [ -z "${_plugin}" ] && continue

        # Idempotency: check if already enabled.
        if claude plugins list 2>/dev/null | grep -qF "${_plugin}"; then
            printf '[10-plugin-setup] plugin already enabled: %s\n' "${_plugin}"
        else
            printf '[10-plugin-setup] enabling plugin: %s\n' "${_plugin}"
            if ! claude plugins enable "${_plugin}"; then
                printf '[10-plugin-setup] WARNING: failed to enable plugin: %s\n' "${_plugin}" >&2
            fi
        fi
        IFS=":"
    done
    IFS="${_OLD_IFS}"
fi

# Enable all plugins from last marketplace if requested
if [ "${AI_SANDBOX_ENABLE_ALL_PLUGINS:-false}" = "true" ] && [ -n "${_LAST_MARKETPLACE}" ]; then
    printf '[10-plugin-setup] enabling all plugins from: %s\n' "${_LAST_MARKETPLACE}"
    if ! claude plugins enable --all; then
        printf '[10-plugin-setup] WARNING: failed to enable all plugins\n' >&2
    fi
fi
```

**Implementation notes for the task agent:**

- Verify the exact CLI form for `claude plugins marketplace list`, `claude plugins marketplace add`, `claude plugins list`, `claude plugins enable`, and `claude plugins enable --all` before implementing. These commands are the intended interface but the exact flags/subcommands may differ.
- If `claude plugins marketplace list` does not exist or produces different output, adapt the idempotency check accordingly (e.g., inspect `~/.claude/plugins/` or a manifest file).
- The script uses POSIX `/bin/sh`, not bash — avoid bash-isms. No arrays, no `[[`, no `$(( ))` if `/bin/sh` doesn't support it (though `$(( ))` is POSIX).
- The `set -u` at the top means every variable access uses `${VAR:-}` defaulting to avoid unbound variable errors.

### 4. Compose environment passthrough

Verify (or add) that `AI_SANDBOX_MARKETPLACES`, `AI_SANDBOX_PLUGINS`, and `AI_SANDBOX_ENABLE_ALL_PLUGINS` are listed in the compose environment passthrough. Look at how `EFFECTIVE_MODE`, `NO_ISOLATE_CONFIG`, or similar host-set vars are passed into the container in `docker/docker-compose.yaml` or the generated overlay, and follow the same pattern.

---

## Checkpoint hints

This task touches three files plus the compose config. Recommended checkpoints:

1. **After `src/index.sh` changes:** Run `make build` to roll up the changes. Then manually invoke `bin/ai-sandbox.sh create --add-marketplace https://example.com --dry-run` (if a dry-run mode exists) or inspect that `AI_SANDBOX_MARKETPLACES` is set in the shell after sourcing the script library (`__SOURCED__=1`).

2. **After `src/volume-override.sh` changes:** Run `make build` again. Inspect the generated compose file for a sandbox that has a `file://` marketplace configured — it should contain a bind mount entry with `read_only: true`.

3. **After creating `10-plugin-setup`:** Confirm it is executable (`ls -l docker/rootfs/etc/cont-init.d/10-plugin-setup`). Run `make lint` — shellcheck runs across `docker/` files. Fix any shellcheck findings. Manually trace through the idempotency logic with a hypothetical `AI_SANDBOX_MARKETPLACES=https://example.com:file:///tmp/plugin` value.

---

## Validation

The task is complete when:

- [ ] `src/index.sh` exports `AI_SANDBOX_MARKETPLACES`, `AI_SANDBOX_PLUGINS`, and `AI_SANDBOX_ENABLE_ALL_PLUGINS`.
- [ ] `docker/rootfs/etc/cont-init.d/10-plugin-setup` exists and is executable.
- [ ] The init script reads all three env vars and runs the appropriate `claude plugins` commands.
- [ ] The init script is idempotent (skips already-registered marketplaces and plugins).
- [ ] The init script is non-fatal (warns on failure; does not call `exit 1` or `s6-halt` on plugin errors).
- [ ] `file://` paths in `AI_SANDBOX_MARKETPLACES` are auto-mounted as read-only bind mounts in the compose overlay generated by `src/volume-override.sh`.
- [ ] `make build` succeeds.
- [ ] `make lint` passes (shellcheck clean across all modified files).
