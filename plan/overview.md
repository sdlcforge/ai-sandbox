# Plugin Marketplace Support — Implementation Plan Overview

## Purpose and scope

Add marketplace and plugin configuration support to `ai-sandbox`. Three new CLI flags (`--add-marketplace`, `--enable-plugin`, `--enable-all`) and corresponding profile YAML fields (`marketplaces`, `enable_all_plugins`) let projects launch sandbox containers with specific Claude Code plugins pre-configured — including local/private plugins from disk via `file://` URIs.

The primary use case is spinning up test sandbox containers with `claude-mem` (already on host) and a local `flow` plugin from `file:///path/on/disk` pre-configured, without requiring manual plugin setup inside the container each time.

## Current status

> **Note:** This document does NOT track the current state of implementation. Refer to plan/TODO.md for live task status.

## Overview

### Background

`ai-sandbox` wraps `docker compose` to run Claude Code in an isolated Ubuntu container. It mounts `~/.claude` from the host at runtime, so plugin state written inside the container persists on the host and vice versa. The existing profile YAML system supports a `plugins: [string]` field (plugin names to enable) but has no way to specify marketplace sources or register new marketplaces.

### What is being built

Three new CLI flags:

- `--add-marketplace <ref>` (repeatable) — `ref` must start with `https://` or `file://`; registers the marketplace via `claude plugins marketplace add <ref>` at container init time
- `--enable-plugin <name>` (repeatable) — enables a named plugin from any registered marketplace
- `--enable-all` — enables all plugins from the last marketplace added

Corresponding profile YAML fields:

- `marketplaces: [string]` — list of marketplace refs (composed via union across profiles)
- `enable_all_plugins: bool` — enables all plugins from the last marketplace (OR-composed: true if any profile or CLI flag sets it)
- `plugins: [string]` — existing field; continues to hold individual plugin names to enable

### Architecture decisions

**Plugin commands run at container init time**, not image build time. Since `~/.claude` is mounted at runtime, any plugin state baked into the image would be overridden. An s6-overlay `cont-init.d` script (`10-plugin-setup`) runs after SSH and config overlay setup and handles marketplace registration and plugin enablement.

**`~/.claude` is shared with the host.** Marketplace `add` and plugin `enable` commands write to `~/.claude`. This is accepted behavior — the user is explicitly choosing plugins. The init script must be **idempotent**: it checks whether a marketplace or plugin is already registered before running the command.

**`file://` path handling.** When `--add-marketplace file:///some/path` is specified, that host path must be auto-mounted into the container at the same absolute path. `src/volume-override.sh` generates this bind mount as part of the per-run compose overlay, so `claude plugins marketplace add file:///some/path` resolves correctly inside the container. Mounts are read-only.

**Environment variable handoff.** `profile-installer.js` emits `marketplaces` and `enable_all_plugins` in the `### PROFILE_JSON ###` output block. `src/index.sh` reads that JSON, merges any CLI-level overrides, and exports `AI_SANDBOX_MARKETPLACES`, `AI_SANDBOX_PLUGINS`, and `AI_SANDBOX_ENABLE_ALL_PLUGINS` into the compose environment, where the s6 init script reads them.

### Phase sequence

```
Phase 01 — Schema and Installer (Foundation)
    Task 001 — profile-schema-and-installer

Phase 02 — CLI Flags (Interface)             [parallel-eligible with Phase 03]
    Task 001 — cli-flags

Phase 03 — Container Plugin Setup (Core Logic)  [parallel-eligible with Phase 02]
    Task 001 — container-plugin-setup

Phase 04 — Tests and QA Gate (Verification)
    Task 001 — tests-and-qa
```

**Critical path:** Phase 01 → Phase 03 → Phase 04. Phases 02 and 03 can run concurrently once Phase 01 is merged.

### Dependency table

| Task | Depends on | Parallel-eligible with |
|------|------------|------------------------|
| Phase 01 Task 001 | — | nothing initially |
| Phase 02 Task 001 | Phase 01 Task 001 | Phase 03 Task 001 |
| Phase 03 Task 001 | Phase 01 Task 001 | Phase 02 Task 001 |
| Phase 04 Task 001 | Phase 02 Task 001, Phase 03 Task 001 | — |

### Files touched

| File | Phases |
|------|--------|
| `docs/ai-sandbox-profiles-spec.md` | 01 |
| `bin/profile-installer.js` | 01 |
| `test/unit/profile_installer_spec.js` (or `.sh`) | 01, 04 |
| `src/options.sh` | 02 |
| `src/help.sh` | 02 |
| `src/index.sh` | 02, 03 |
| `src/volume-override.sh` | 03 |
| `docker/rootfs/etc/cont-init.d/10-plugin-setup` | 03 |
| `test/unit/ai_sandbox_spec.sh` | 04 |

### Constraints

- Edit `src/` modules only; `make build` rolls them into `bin/ai-sandbox.sh` (never hand-edit the rollup). Preserve the `${__SOURCED__:+return}` guard.
- `shellcheck` (`make lint`) must pass on all `src/`, `docker/`, `test/` files; any `# shellcheck disable` needs an inline reason.
- `js-yaml` is already a dependency — no new Node deps needed.
- `make lint` + `make test` must pass at the plan's end.
