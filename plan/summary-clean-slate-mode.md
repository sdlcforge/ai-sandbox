# Session Summary — Clean-Slate Mode

## What was planned and why

The goal was to add a `--clean` flag to `ai-sandbox create` that starts a container with no host state mirrored into it. The primary use case is ephemeral, reproducible AI dev sessions: no host `~/.claude` bind-mount, no `~/.config` overlay, and no host plugin directory mounts. Claude Code remains present (baked into the image); the `10-plugin-setup` cont-init still runs and can configure explicitly-requested marketplaces and plugins via environment variables.

`--clean` implies static mode. Passing `--mode static` alongside `--clean` is redundant but allowed without error.

The plan was structured as three sequential phases: CLI flag and state propagation, compose restructuring and volume suppression, and tests plus a QA gate. Phase 03 also backfilled plugin-marketplace Phase 04 unit tests that were not written in the prior session.

## What shipped

### Phase 01 — CLI Flag and State Propagation

Branch: `phase-01-task-01-clean-flag-and-propagation` | Commit: `6c900c5` | Merge: `e1b7062`

- `src/options.sh`: initialized `CLEAN_SLATE=false` in defaults; added `--clean` case setting `CLEAN_SLATE=true` and `CONFIG_FLAGS_PROVIDED=true`; added `CLEAN_SLATE` to the export statement.
- `src/index.sh`: updated mode resolution to force `EFFECTIVE_MODE=static` when `CLEAN_SLATE=true`, before checking `MODE_OVERRIDE` or profile mode; exported `AI_SANDBOX_CLEAN_SLATE` immediately after.
- `src/utils.sh`: added `cur_clean` variable and a sixth label comparison for `ai.sandbox.clean-slate` in `running_config_matches`.
- `src/help.sh`: added `--clean` entry in the `create` subcommand options list.

### Phase 02 — Compose Restructuring and Volume Suppression

Branch: `phase-02-task-01-compose-restructuring` | Commit: `5fa27b8` | Merge: `d2eb226`

- `docker/docker-compose.yaml`: removed the `${HOST_HOME}/.claude:${HOST_HOME}/.claude` volume line; added `ai.sandbox.clean-slate: "${AI_SANDBOX_CLEAN_SLATE:-false}"` label.
- `docker/docker-compose.mirror-claude.yaml` (new): overlay file that re-introduces the `~/.claude` bind-mount; applied by `index.sh` in all non-clean-slate invocations regardless of mode.
- `src/index.sh`: added conditional block after the chromium overlay to append `mirror-claude.yaml` when `CLEAN_SLATE != true`.
- `src/volume-override.sh`: wrapped the plugin dir mount loop in `if [ "${AI_SANDBOX_CLEAN_SLATE:-false}" != "true" ]`; the `file://` marketplace mount loop and `user_maps` loop are intentionally left unguarded.
- `bin/ai-sandbox.sh`: regenerated rollup.

Validation: `make build` passed; `make lint` passed; `make test.unit` — 90 examples, 0 failures.

### Phase 03 — Tests and QA Gate

Branch: `phase-03-task-01-tests-and-qa-gate` | Commit: `32a6c7c` | Merge: `0ab205e`

- `test/unit/ai_sandbox_spec.sh`: 13 new `It` blocks added.
  - Inside the existing `parse_options()` Describe: 4 `--clean` flag cases; 2 plugin-marketplace backfill cases (`--enable-plugin` no-arg error, `CLI_ENABLE_ALL` defaults to false).
  - New Describe block `generate_volume_override() clean-slate mode`: 4 cases covering plugin dir suppression, `file://` marketplace mount preservation in clean mode, default (non-clean) behavior, and empty-volumes output.
  - New Describe block `generate_volume_override() file:// marketplace mounts`: 3 cases covering single `file://` mount, `https://` non-mount, and multiple pipe-separated entries.

Final QA gate: `make build` passed; `make lint` passed; `make test.unit` — 103 examples, 0 failures.

## Key decisions

- `--clean` forces `EFFECTIVE_MODE=static` unconditionally, evaluated before `MODE_OVERRIDE` or profile mode. If a user passes both `--clean` and `--mode mirror`, `--clean` wins silently. No error-on-conflict logic in V1.
- The `~/.claude` bind-mount was extracted into `docker/docker-compose.mirror-claude.yaml` rather than conditionally suppressed inline, mirroring the existing pattern for `~/.config` overlays. The explicit `CLEAN_SLATE` guard in `index.sh` is used rather than relying solely on mode forcing, so the behavior is correct even if future code changes alter mode resolution.
- `--clean` suppresses only implicit host state (plugin dir mounts, `~/.claude` bind-mount, `~/.config` overlays). Explicitly-requested resources — `file://` marketplace mounts, `user_maps` volume-map entries — are preserved in V1. This distinction is intentional.
- The `ai.sandbox.clean-slate` label is stamped on the container via the base `docker-compose.yaml` so `running_config_matches` can detect when switching between clean and non-clean requires a recreate.
- Plugin marketplace refs continue to be passed as pipe-separated strings (`AI_SANDBOX_MARKETPLACES`, `AI_SANDBOX_PLUGINS`) because marketplace URLs contain colons, making colon-separation ambiguous.
- The `10-plugin-setup` cont-init was not modified; it already reads env vars correctly and creates a fresh `~/.claude` when no bind-mount supplies one.

## Follow-up items

- **V1 limitation — `.claude.json` baked into image:** The Dockerfile bakes the host's `~/.claude.json` into the image at build time. Clean-slate mode targets `~/.claude/` (plugins, settings subdirectory), not `.claude.json`. This is a documented limitation; no fix is in scope.
- **Integration tests for `--clean` container lifecycle:** Not written. Requires a running Docker daemon and is out of scope for the unit test suite. Carry forward into a future QA plan.
- **`docker compose config` parse verification for `docker-compose.mirror-claude.yaml`:** Validation check 4 from Phase 02 was deferred — no live Docker daemon was available in the task agent context. Low risk (file mirrors `docker-compose.shared-config.yaml`). Verify manually or via integration test.
- **`user_maps` suppression in clean mode:** The `~/.config/ai-sandbox/volume-maps` file is explicit user configuration and was intentionally left unguarded in V1. A future iteration could suppress it in clean mode if desired.
- **`mid-task-commit.sh` operates on main checkout:** Carried forward from the plugin-marketplace session. Mid-task checkpoints were committed manually as a workaround. Investigate and fix or document.
- **`ai-sandbox list` when Docker daemon is down:** Prints "No sandboxes found." A future improvement could distinguish daemon-not-running from no managed containers. (Carried from multi-instance-sandbox plan.)
