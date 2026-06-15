# Clean-Slate Mode (`--clean` flag) — Plan Overview

## Purpose and Scope

Add a `--clean` flag to `ai-sandbox create` that starts a container with no host state mirrored into it. The primary use case is ephemeral, reproducible AI dev sessions: no host `~/.claude` bind-mount, no `~/.config` overlay, and no host plugin directory mounts. Claude Code is still present (baked into the image); the `10-plugin-setup` cont-init still runs and can configure any explicitly-requested marketplaces and plugins via environment variables.

Example invocation:
```
ai-sandbox create my-instance --clean --add-marketplace file:///path/to/marketplace --enable-all
```

`--clean` implies static mode. Passing `--mode static` alongside `--clean` is redundant but allowed without error.

## In-Scope

- `--clean` CLI flag in `parse_options` (sets `CLEAN_SLATE=true`, `CONFIG_FLAGS_PROVIDED=true`)
- Exporting `AI_SANDBOX_CLEAN_SLATE` env var for downstream consumption
- Forcing `EFFECTIVE_MODE=static` when `CLEAN_SLATE=true` (in `index.sh`)
- Extracting `~/.claude` bind-mount out of the base `docker-compose.yaml` into a new `docker/docker-compose.mirror-claude.yaml` overlay
- Adding `ai.sandbox.clean-slate` label to `docker-compose.yaml` and reading it in `running_config_matches`
- Suppressing the `list_installed_plugins` loop in `generate_volume_override` when `AI_SANDBOX_CLEAN_SLATE=true`
- Help text update for `--clean`
- Unit tests for all new behavior
- Backfill of plugin-marketplace Phase 04 unit tests (not written in the prior session)
- `make build`, `make lint`, `make test.unit` QA gate

## Out-of-Scope (V1 Limitations)

- **`.claude.json` baked into the image:** The Dockerfile bakes the host's `~/.claude.json` into the image at build time. Clean-slate mode targets `~/.claude/` (plugins, settings subdirectory), not `.claude.json`. This is a documented V1 limitation.
- **Integration tests** for the actual container lifecycle with `--clean` (those require a running Docker daemon and are not part of the unit test suite).
- No changes to `10-plugin-setup` — it already reads env vars correctly and creates a fresh `~/.claude` when no bind-mount supplies one.

## Phases

### Phase 01 — CLI Flag and State Propagation

**Goal:** `--clean` is recognized by the CLI, sets the right state variables, forces static mode in `index.sh`, updates `running_config_matches` to check the new label, and appears in help text.

Files touched: `src/options.sh`, `src/index.sh`, `src/utils.sh`, `src/help.sh`

### Phase 02 — Compose Restructuring and Volume Suppression

**Goal:** The `~/.claude` bind-mount is extracted into its own overlay file (parallel to how `~/.config` is handled), the base compose gets an `ai.sandbox.clean-slate` label, and `generate_volume_override` skips plugin dir mounts when `AI_SANDBOX_CLEAN_SLATE=true`.

Files touched: `docker/docker-compose.yaml`, `docker/docker-compose.mirror-claude.yaml` (new), `src/index.sh`, `src/volume-override.sh`

### Phase 03 — Tests and QA Gate

**Goal:** Unit tests cover all new `--clean` behavior, all new compose/volume logic, and backfill the missing plugin-marketplace Phase 04 tests. `make build`, `make lint`, `make test.unit` all pass.

Files touched: `test/unit/ai_sandbox_spec.sh`

**Note on plugin-marketplace Phase 04 backfill:** The plugin-marketplace plan included a Phase 04 (tests) that was not executed in the prior session. Those tests are incorporated here rather than left as technical debt.

## Critical Path

Phase 01 → Phase 02 → Phase 03 (strictly sequential; each phase depends on the previous).
