# Add Detail Alias And Config Display

## Purpose and scope

Add `detail` as a pure alias for the existing `status` per-instance command — both the bare `ai-sandbox detail` form and the `ai-sandbox <name> detail` form — and extend `status`/`detail` output to decode and display the persisted `ai.sandbox.config` label (introduced by Task 001) so users can see the reconstructable configuration at a glance.

Depends on Task 001 (`001-persist-and-restore-full-config-inputs.md`) — the `ai.sandbox.config` label must exist before it can be decoded/displayed. Sequenced after Task 002 (`002-reconcile-running-config-match.md`) as well: both Task 002 and this task touch `test/unit/ai_sandbox_spec.sh`, and running this task last avoids merge friction on that shared file. This is a sequencing consideration only — this task has no functional dependency on Task 002's content (the `running_config_matches` comparison logic).

This is a direct source edit to the launcher — no standard skill applies. Edit `src/` modules and run `make build` after edits (never edit `bin/ai-sandbox.sh`).

## Requirements

1. **`src/options.sh`**:
   - Add `"detail"` to `PER_INSTANCE_COMMANDS` (line 137 in the current source) and to `RESERVED_NAMES` (line 59), so `detail` is recognized as a per-instance command word both bare and after a sandbox name, and cannot collide with a sandbox instance name.
   - When the parsed command word is `detail`, normalize `CMD` to `"status"` immediately after it is assigned (both the bare-command-word branch and the `<name> detail` branch resolve to the same per-instance-command parsing path in the current source, so a single normalization point after Phase 2's `CMD` assignment — before Phase 3's flag parsing — covers both forms). This is a pure alias: no new `CMD` value propagates downstream, so every existing `[ "${CMD}" = "status" ]` check continues to work unmodified — notably the `QUIET` default at `src/options.sh` (line 296) and the dispatch branch at `src/index.sh` (line 319, `elif [ "${CMD}" == "status" ]; then`).
   - Update the `CMD` doc-comment at the top of `options.sh` (the `# CMD` line in the block comment, currently `#   CMD           — subcommand (e.g. "create", "list", "enter", "stop")`) to mention that `detail` is accepted as an alias for `status` and normalized to `CMD="status"` during parsing.
2. **`src/status.sh`**: extend `do_status` to decode the `ai.sandbox.config` label (base64 → JSON via `jq`, matching the read pattern Task 001 establishes in `restore_saved_config`) for the current sandbox's container. Use `docker inspect --format='{{index .Config.Labels "ai.sandbox.config"}}' "$(sandbox_container_name)"` (or equivalent) — `docker inspect` works on stopped containers too, so the config section should render regardless of container state, not just when running.
   - **Human output** (`_render_status_human`): print a new `Configuration:` section rendering the decoded JSON as YAML via `yq -y .` for readability. Confirm on the implementer's host which `yq` is on `PATH` before wiring this in: `yq -y .` is the Python (`kislyuk/yq`) wrapper's syntax for "read JSON on stdin, emit YAML" — it is NOT `mikefarah/yq`'s `yq eval` syntax, and the two tools are incompatible on the command line despite the shared binary name. If `yq` is not on `PATH` (or is the wrong variant), fall back gracefully to pretty-printed JSON via `jq .` with no error — mirror the project's existing pattern of graceful degradation when an optional tool is missing (see `src/xquartz.sh`'s handling of optional GUI/XQuartz support). Omit the `Configuration:` section entirely (not an error, no placeholder text) when the label is absent — expected for any container with no `ai.sandbox.config` label (no container, or a label-less/pre-existing container, since Task 001 implements no legacy-label fallback).
   - **JSON output** (`_render_status_json`, `--json`): decode the label (base64 → JSON via `jq`, no `yq` needed since the target format is already JSON) and include it directly as a `config` key in the emitted object; `null` when the label is absent.
3. **`README.md`**:
   - There is currently no dedicated `status` row in the `## CLI reference` table (the table lists `build`, `start`, `attach`/`connect`, `new-profile`, `fix-ssh`, and a passthrough catch-all). Add a `status` / `detail` row to that table documenting both the base command and the alias, e.g. `` `status` / `detail` `` — "Show container/image state, blocking-process conflicts, and (when present) the persisted configuration."
   - Add `yq` to the `## Prerequisites` section's "Optional" list, following the existing style of the `XQuartz`/`claude-mem` optional-dependency bullets — call out that it enables readable YAML rendering of `status`/`detail`'s configuration section and that its absence degrades gracefully to JSON. Note in the bullet that this must be the Python `kislyuk/yq` wrapper (not `mikefarah/yq`), matching the tool identification made in requirement 2.
4. **Regression tests** in `test/unit/ai_sandbox_spec.sh`:
   - (a) `detail` parses to `CMD=status`, both bare (`ai-sandbox detail`) and `<name> detail` (`ai-sandbox myname detail`) forms — consistent with the existing option-parsing test patterns for other per-instance commands.
   - (b) `status`/`detail` human output includes a `Configuration:` section with decoded content when the `ai.sandbox.config` label is present (mock `docker inspect` to return a base64-encoded JSON label value, as the existing `restore_saved_config`/`running_config_matches` tests already do for other labels).
   - (c) graceful omission of the `Configuration:` section when the label is absent (mock `docker inspect` returning empty for that label).
   - (d) `--json` output includes the `config` key with the decoded object (or `null` when the label is absent).
   - If feasible without excessive mocking complexity, add a case confirming the `jq .`-only fallback path is exercised when `yq` is unavailable (e.g. by shadowing `command -v yq`/`PATH` in the test) — optional if the existing test harness makes this awkward; do not block on it if so.
5. Run `make build` and `make lint`; keep shellcheck clean (inline reason comment on any new `disable`).

## Validation

- `make build` regenerates `bin/ai-sandbox.sh` with no manual edits to the rollup.
- `make lint` passes (shellcheck clean across `src/`, `docker/`, `test/`).
- `make test.unit` passes, including the new `detail`/config-display regression cases.
- `grep -n 'detail' src/options.sh` confirms `detail` appears in both `PER_INSTANCE_COMMANDS` and `RESERVED_NAMES`, and that the normalization to `CMD="status"` is present.
- `grep -n 'ai.sandbox.config' src/status.sh` confirms the label-decoding logic appears in both `_render_status_human` (or `do_status`, wherever the decode is centralized) and `_render_status_json`.
- `grep -n 'yq' src/status.sh README.md` confirms the `yq -y .` rendering path and its README documentation.
- README documents both the `detail` alias (CLI reference table) and `yq` as an optional prerequisite.
- Manual reasoning check: a stopped container with a persisted `ai.sandbox.config` label still shows the `Configuration:` section (confirms the stopped-container `docker inspect` path works, not just running).

## Metadata

<!-- architectural_impact omitted: this is a CLI/UX surface addition (an alias command word and a read-only display of an existing label) on top of the Task 001 label contract, not a new subsystem, boundary, cross-cutting layer, or significant new tracked state beyond what Task 001 already flagged as architecturally significant. -->

## References

- `src/options.sh` — `PER_INSTANCE_COMMANDS` (line 137) and `RESERVED_NAMES` (line 59) to extend; the `CMD` doc-comment block at the top of the file; the `QUIET` default check (line 296) that must keep working unmodified for `CMD="status"`.
- `src/status.sh` — `do_status`, `_render_status_human`, `_render_status_json` to extend.
- `src/index.sh` — the dispatch branch at line 319 (`elif [ "${CMD}" == "status" ]; then`) that must keep working unmodified for the aliased `CMD`.
- `docker/docker-compose.yaml` — the `labels:` block, source of `ai.sandbox.config` (introduced by Task 001).
- `plan/phase-01-full-config-restore/001-persist-and-restore-full-config-inputs.md` — defines the `ai.sandbox.config` label schema this task decodes and displays; do not re-derive the schema here, just consume it.
- `README.md` — the `## CLI reference` table and `## Prerequisites` section to update.
- `src/xquartz.sh` — the project's existing pattern for graceful degradation when an optional host tool (XQuartz) is absent; mirror this style for the `yq`-absent fallback.

## Checkpoint hints

- After the `detail` alias parses correctly and normalizes to `CMD=status` (`src/options.sh`).
- After `status`/`detail` render the `Configuration:`/`config` sections, both with and without `yq` present on `PATH`, and both for running and stopped containers (`src/status.sh`).
- After README and tests are updated and `make build`/`make lint`/`make test.unit` all pass.
