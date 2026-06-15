# Plugin Marketplace — Plan Session Summary

**Plan:** `plugin-marketplace`
**Session date:** 2026-06-13 / 2026-06-14
**Status:** Phases 01–03 shipped; Phase 04 not executed

---

## What was planned and why

The goal was to add marketplace and plugin configuration support to `ai-sandbox` so that projects can launch sandbox containers with specific Claude Code plugins pre-configured — without requiring manual plugin setup inside the container each time.

The primary motivating use case was running test sandbox containers with `claude-mem` (already installed on host) and a local `flow` plugin sourced from a `file://` path on disk, both registered and enabled automatically at container init time.

The plan introduced three new CLI flags (`--add-marketplace`, `--enable-plugin`, `--enable-all`) and corresponding profile YAML fields (`marketplaces`, `enable_all_plugins`), wiring them through the full stack: profile schema and installer, CLI option parser, and a new s6-overlay container init script. The plan was structured in four phases with phases 02 and 03 able to run in parallel after the foundation (phase 01) was merged.

---

## What shipped

### Phase 01 — Profile Schema and Installer (merged `2bcb542`)

- `docs/ai-sandbox-profiles-spec.md`: documented `marketplaces` (list of strings, union composition) and `enable_all_plugins` (bool, OR composition) with cross-reference note on `plugins` and an updated composition table.
- `bin/profile-installer.js`: added both fields to `KNOWN_KEYS`; `marketplaces` added to `STRING_LIST_FIELDS` for union composition; `enable_all_plugins` handled with a dedicated boolean check and OR logic in `compose()`; both fields emitted in `renderJsonBlob()` output; validation rejects any marketplace ref not starting with `https://` or `file://`.
- `test/unit/profile_installer_spec.sh`: 10 new test cases added (suite grew from 72 to 82 examples, all passing).
- `test/fixtures/profiles/*.yaml`: 9 fixture profiles added to support the new cases.

### Phase 02 — CLI Flags (merged `a6773ac`)

- `src/options.sh`: three new flags (`--add-marketplace`, `--enable-plugin`, `--enable-all`) added to `parse_options()`; `--add-marketplace` validates the `https://` or `file://` prefix at parse time and exits with a clear error on failure; repeatable flags accumulate into `CLI_MARKETPLACES` and `CLI_PLUGINS` arrays; `CLI_ENABLE_ALL` is a boolean flag.
- `src/help.sh`: all three flags documented in the configuration flags section.
- `src/index.sh`: added `jq` post-processing step that merges CLI-supplied marketplace and plugin values into `PROFILE_JSON` (union for lists, OR for boolean) after the profile-installer output is eval'd.

### Phase 03 — Container Plugin Setup (merged `542d18b`)

- `src/index.sh`: extracts `marketplaces`, `plugins`, and `enable_all_plugins` from `PROFILE_JSON` and exports them as `AI_SANDBOX_MARKETPLACES`, `AI_SANDBOX_PLUGINS`, and `AI_SANDBOX_ENABLE_ALL_PLUGINS` into the compose environment.
- `src/volume-override.sh`: `generate_volume_override()` extended to parse `AI_SANDBOX_MARKETPLACES` and emit read-only bind mounts for each `file://` entry, using the same path inside the container as on the host so no path translation is needed.
- `docker/rootfs/etc/cont-init.d/10-plugin-setup`: new POSIX `/bin/sh` s6-overlay cont-init script; reads all three env vars; idempotently registers marketplaces and enables plugins (checks existing state before running each command); non-fatal on failure (warns via stderr but does not block container startup).

### Phase 04 — Tests and QA Gate

**Not executed.** The feature implementation was complete but the session ended before phase 04 ran. See Follow-up items below.

---

## Key decisions

- **Pipe-separated strings for env var handoff.** Marketplace refs and plugin names are joined with `|` (pipe) rather than `:` (colon) when passed as `AI_SANDBOX_MARKETPLACES` / `AI_SANDBOX_PLUGINS`, because marketplace URLs contain colons. This separator must be used consistently in both `src/index.sh` and `10-plugin-setup`.

- **`claude` CLI runs as the host user inside the container.** The `10-plugin-setup` init script runs as the host user so that `~/.claude` resolves to the bind-mounted directory with correct ownership, matching the existing `~/.claude` mount convention.

- **`file://` paths: same path inside and outside the container.** Auto-mounting `file://` marketplace paths at the same absolute path in the container (`source == target`) eliminates any need for path translation in the init script or in `claude plugins marketplace add` invocations.

- **Plugin commands run at container init time, not image build time.** Because `~/.claude` is mounted at runtime, any plugin state baked into the image would be overridden on mount. The s6 `cont-init.d/10-plugin-setup` script runs after the config overlay scripts and handles all marketplace/plugin setup at each container start.

- **`enable_all_plugins` excluded from `SCALAR_FIELDS`.** The field is boolean and requires OR composition across profiles, so it was given dedicated handling rather than being folded into the generic scalar field path.

- **Idempotency via `claude plugins` list output.** The init script checks `claude plugins marketplace list` and `claude plugins list` before running add/enable commands, making repeated container restarts safe even if `~/.claude` persists from a prior run.

---

## Follow-up items

- **Phase 04 — Tests and QA Gate (carry forward).** Unit tests for new behavior were not written. Pending areas:
  - Flag-parsing tests: `--add-marketplace` (acceptance, rejection, accumulation), `--enable-plugin`, `--enable-all` presence/absence.
  - `generate_volume_override()` tests: `file://` entries → read-only bind mounts; `https://`-only and empty cases → no new mounts; multiple `file://` entries → multiple mounts.
  - Profile-installer JSON output: `marketplaces` and `enable_all_plugins` present with correct defaults; union/OR composition across two-profile scenarios.
  - Full `make build && make lint && make test` gate.

- **`mid-task-commit.sh` worktree behavior.** During phase 01, the script operated on the main checkout rather than the task worktree. Investigate and fix or document.
