# Phase 02, Task 01 — Extract `~/.claude` Mount and Add Clean Overlay Logic

## Context

This task restructures the Docker Compose file set and volume-override logic so that the `~/.claude` bind-mount is conditional (added only when NOT in clean mode), and the plugin directory mounts from the host are suppressed entirely in clean mode.

The pattern mirrors how `~/.config` is already handled: rather than having a single base compose that includes everything, the `~/.claude` mount lives in a separate overlay file (`docker-compose.mirror-claude.yaml`) that `index.sh` adds to `COMPOSE_FILES` only when appropriate.

**Dependencies:** Phase 01, Task 01 (`CLEAN_SLATE` / `AI_SANDBOX_CLEAN_SLATE` must be exported).

**Branch convention:** `phase-02-task-01-compose-restructuring`

## Files to Modify / Create

- `docker/docker-compose.yaml` (modify)
- `docker/docker-compose.mirror-claude.yaml` (create new)
- `src/index.sh` (modify — compose assembly section)
- `src/volume-override.sh` (modify — skip plugin loop in clean mode)

## Step-by-step Instructions

### 1. `docker/docker-compose.yaml` — Remove `~/.claude` mount and add label

**1a. Remove the `~/.claude` volume line**

In the `volumes:` section, remove:

```yaml
      - ${HOST_HOME}/.claude:${HOST_HOME}/.claude
```

Also remove or update the comment above it that explains the `~/.claude` shared state. The comment about `~/.config` handling can remain. After removal the `volumes:` list should start directly with the `playground` mount:

```yaml
    volumes:
      # Map host directories to same absolute paths in container.
      # ~/.claude is added by docker-compose.mirror-claude.yaml in mirror mode
      # (omitted in clean-slate mode so the container gets a fresh empty ~/.claude).
      # ~/.config handling is split into two overlay compose files:
      #   - docker-compose.isolate-config.yaml (default): read-only lower + overlayfs
      #   - docker-compose.shared-config.yaml  (--no-isolate-config): rw passthrough
      # Additional per-plugin mounts are generated dynamically into docker-compose.generated.yaml.
      - ${HOST_HOME}/playground:${HOST_HOME}/playground
      # SSH agent socket: host path is bind-mounted to a stable in-container path
      # (decouples container env from host path changes).
      - ${SSH_AUTH_SOCK}:/run/ai-sandbox/ssh-auth.sock
```

**1b. Add `ai.sandbox.clean-slate` label**

In the `labels:` section, after the existing `ai.sandbox.docker-proxy` label line and before the comment for `ai.sandbox.managed`, add:

```yaml
      ai.sandbox.clean-slate: "${AI_SANDBOX_CLEAN_SLATE:-false}"
```

The updated labels section should read (showing context around the insertion point):

```yaml
      ai.sandbox.docker-proxy: "${EFFECTIVE_PROXY:-false}"
      ai.sandbox.clean-slate: "${AI_SANDBOX_CLEAN_SLATE:-false}"
      # Multi-instance management labels. ai.sandbox.managed marks containers
```

### 2. `docker/docker-compose.mirror-claude.yaml` — New overlay file

Create this file following the exact same pattern as `docker-compose.shared-config.yaml`:

```yaml
# Applied in non-clean-slate mode (the default). Bind-mounts the host's
# ~/.claude into the container at the same absolute path so plugins and
# Claude Code state are shared between host and container.
# Omitted in clean-slate mode (--clean) so the container starts with a
# fresh, empty ~/.claude directory.
services:
  ai-sandbox:
    volumes:
      - ${HOST_HOME}/.claude:${HOST_HOME}/.claude
```

### 3. `src/index.sh` — Conditionally add `docker-compose.mirror-claude.yaml`

**3a. Locate the compose assembly section**

The existing compose assembly block is (starting after `generate_volume_override`):

```bash
COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml"
if profile_has_capability chromium; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.chromium.yaml"
fi

# Host-identity / config overlays only apply in mirror mode. static mode is
# self-contained: no ~/.config overlay is applied ...
if [ "${EFFECTIVE_MODE}" = "mirror" ]; then
  if [ "$NO_ISOLATE_CONFIG" = "true" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.shared-config.yaml"
  else
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.isolate-config.yaml"
  fi
fi
```

**3b. Add the `mirror-claude` overlay**

After the `COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml"` line and the chromium block, add the `mirror-claude` overlay — before the `~/.config` mode block:

```bash
# ~/.claude mount: applied in all non-clean-slate invocations regardless of mode.
# In clean-slate mode the container gets a fresh empty ~/.claude directory.
if [ "${CLEAN_SLATE:-false}" != "true" ]; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.mirror-claude.yaml"
fi
```

The complete updated block should be:

```bash
COMPOSE_FILES="-f ${PROJECT_ROOT}/docker/docker-compose.yaml"
if profile_has_capability chromium; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.chromium.yaml"
fi

# ~/.claude mount: applied in all non-clean-slate invocations regardless of mode.
# In clean-slate mode the container gets a fresh empty ~/.claude directory.
if [ "${CLEAN_SLATE:-false}" != "true" ]; then
  COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.mirror-claude.yaml"
fi

# Host-identity / config overlays only apply in mirror mode. static mode is
# self-contained: no ~/.config overlay is applied (see decisions in task report
# for the V1 scope of static-mode mount suppression).
if [ "${EFFECTIVE_MODE}" = "mirror" ]; then
  if [ "$NO_ISOLATE_CONFIG" = "true" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.shared-config.yaml"
  else
    COMPOSE_FILES="${COMPOSE_FILES} -f ${PROJECT_ROOT}/docker/docker-compose.isolate-config.yaml"
  fi
fi
```

Note: Because `--clean` forces `EFFECTIVE_MODE=static` (set in Phase 01), the `if [ "${EFFECTIVE_MODE}" = "mirror" ]` block will already be skipped in clean mode. The explicit `CLEAN_SLATE` check for `mirror-claude` is nonetheless correct and explicit — it allows `--clean` to work correctly even if future code changes adjust mode forcing.

### 4. `src/volume-override.sh` — Skip plugin dir mounts in clean mode

In `generate_volume_override`, the plugin dir mount loop is:

```bash
    while IFS= read -r plugin; do
        [ -z "${plugin}" ] && continue
        name=".${plugin}"
        if [ -d "${HOME}/${name}" ]; then
            mounts+=("${HOME}/${name}:${HOME}/${name}")
        fi
    done < <(list_installed_plugins)
```

Wrap this loop with a clean-slate guard:

```bash
    # Skip host plugin directory mounts in clean-slate mode.
    if [ "${AI_SANDBOX_CLEAN_SLATE:-false}" != "true" ]; then
        while IFS= read -r plugin; do
            [ -z "${plugin}" ] && continue
            name=".${plugin}"
            if [ -d "${HOME}/${name}" ]; then
                mounts+=("${HOME}/${name}:${HOME}/${name}")
            fi
        done < <(list_installed_plugins)
    fi
```

The `file://` marketplace mount loop (later in the function) is intentionally NOT guarded — explicitly-requested marketplace paths must still be mounted even in clean mode. This is the correct behavior: `--clean` suppresses implicit host state, not explicitly-requested resources.

The `user_maps` file loop (reading `~/.config/ai-sandbox/volume-maps`) should also be preserved as-is for V1. That file is an explicit user configuration, not implicit host state. (If a future iteration wants to suppress it in clean mode, that can be addressed separately.)

## Validation

1. `make build` — must exit 0.
2. `make lint` — shellcheck must pass with no new issues.
3. Manual verification (informational, not automated in this phase):
   - In non-clean mode: `docker compose config` assembled from the compose files should include the `~/.claude` mount (from `mirror-claude.yaml`).
   - In clean mode (set `CLEAN_SLATE=true AI_SANDBOX_CLEAN_SLATE=true` and inspect generated compose): `~/.claude` should NOT appear in volumes.
4. Confirm `docker/docker-compose.mirror-claude.yaml` validates: `docker compose -f docker/docker-compose.yaml -f docker/docker-compose.mirror-claude.yaml config` should parse without error (requires `HOST_HOME`, `SSH_AUTH_SOCK`, and other env vars to be set, or use `--env-file` / `docker-compose.override`).

## Notes

- The `ai.sandbox.clean-slate` label is written to the base compose so it is always stamped on the container. `running_config_matches` (updated in Phase 01) reads this label to detect when switching between clean and non-clean would require a container recreate.
- The `~/.claude` volume comment in `docker-compose.yaml` should clearly state that the mount now lives in `docker-compose.mirror-claude.yaml` so future maintainers know where to find it.
- `is_build_stale` scans `docker/` for newer files; adding `docker-compose.mirror-claude.yaml` is automatically included in that scan — no changes to `is_build_stale` needed.
