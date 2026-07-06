# Restore Mode And Clean-Slate On Bare Enter

## Purpose and scope

Fix the config-restore bug described in `plan/overview.md`: a bare
`<name> enter` / `start` invocation (no config-changing flags) does not
restore the `mode` (`--mode static`) or `clean-slate` (`--clean`) settings
recorded at `create` time, so it silently recomputes `EFFECTIVE_MODE` as
`mirror` and `CLEAN_SLATE` as `false`. This is a targeted bugfix in
`src/index.sh` and `src/utils.sh`, with regression tests in
`test/unit/ai_sandbox_spec.sh`. No standard skill covers this exact
refactor-plus-bugfix shape; follow the `## Procedure` below.

## Requirements

1. **Extract the existing restore block into a testable function.**
   `src/index.sh:73-87` currently contains bare script (not a function) that
   restores the `--profile` list from the `ai.sandbox.profiles` docker
   label when `CONFIG_FLAGS_PROVIDED != true` and a container exists. This
   code sits below the `${__SOURCED__:+return}` guard, so it cannot be
   unit-tested in its current form — unlike every other phase of
   `index.sh`, which delegates to a named function sourced from `src/*.sh`
   (e.g. `do_create`, `ensure_image`, `running_config_matches`) specifically
   so it can be exercised via `Include "$PWD/bin/ai-sandbox.sh"` +
   `When call <function>` in ShellSpec. Move the restore logic into a new
   function `restore_saved_config()` in `src/utils.sh` (a natural
   neighbor of `is_container_running_or_stopped()` and
   `running_config_matches()`, which it depends on / feeds respectively).

2. **Extend the restored fields.** Inside `restore_saved_config()`, in
   addition to the existing `ai.sandbox.profiles` → `PROFILES` restore,
   also restore:
   - `ai.sandbox.mode` docker label → `MODE_OVERRIDE` (values are always
     `mirror` or `static`, written by `docker/docker-compose.yaml:46`
     from `${EFFECTIVE_MODE:-mirror}`).
   - `ai.sandbox.clean-slate` docker label → `CLEAN_SLATE` (values are
     `true`/`false`, written by `docker/docker-compose.yaml:49` from
     `${AI_SANDBOX_CLEAN_SLATE:-false}`).

   Use the same `sandbox_container_name()` helper (not a literal
   `"ai-sandbox-${SANDBOX_NAME}"` string) for all three `docker inspect`
   calls in the function — this satisfies the existing convention
   documented directly above `sandbox_container_name()` in `src/utils.sh`
   ("All docker inspect / docker rm -f calls that target the running
   container must use this helper rather than the literal string
   'ai-sandbox'"), which the pre-existing profiles-restore block did not
   follow. Only inspect once per label (three `docker inspect -f` calls
   total, one per label, mirroring the existing style), guarding each
   restore with `[ -n "<value>" ]` the same way the existing profiles
   restore does, so a legacy/labelless container (or a mocked test double
   that returns nothing) leaves the corresponding global unchanged rather
   than being set to an empty string.

3. **Keep the same gating.** The function should apply the exact same two
   preconditions the existing block uses before restoring anything:
   `CONFIG_FLAGS_PROVIDED != "true"` and `is_container_running_or_stopped`.
   When either does not hold, the function must leave `PROFILES`,
   `MODE_OVERRIDE`, and `CLEAN_SLATE` untouched (i.e. return early with no
   side effects) — this is what preserves the current, correct behavior
   for `--mode`/`--clean`/`--profile`/etc. explicitly passed on the current
   invocation (`CONFIG_FLAGS_PROVIDED` becomes `true` for any of those; see
   `src/options.sh`).

4. **Update the `src/index.sh` call site.** Replace the inline block at
   lines 73-87 with a call to `restore_saved_config` guarded only by
   `[ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]` (the
   `CONFIG_FLAGS_PROVIDED` / running-container gating now lives inside the
   function per requirement 3). Do not change anything else in
   `src/index.sh` — the downstream `EFFECTIVE_MODE` computation
   (`src/index.sh:142-159`, the `CLEAN_SLATE` → static / `MODE_OVERRIDE` →
   value / `PROFILE_MODE` → default fallback chain) and the plugin-conflict
   preflight gate (`src/index.sh:156-159`, gated on
   `EFFECTIVE_MODE = mirror`) are already correct; they only need the
   fixed inputs from `restore_saved_config()` to produce the right result.
   Do not touch `docker/docker-compose.yaml` — the `ai.sandbox.mode` and
   `ai.sandbox.clean-slate` labels are already written at create time
   (lines 46 and 49); this task only changes what reads them back.

5. **Rebuild the rollup.** Run `make build` after editing `src/` so
   `bin/ai-sandbox.sh` (which the ShellSpec tests `Include`) reflects the
   change.

6. **Add regression tests to `test/unit/ai_sandbox_spec.sh`:**
   - A new `Describe 'restore_saved_config()'` block (place it near the
     existing `Describe 'sandbox_container_name()'` /
     `Describe 'cleanup_stale_container()'` blocks, which share the same
     `docker inspect` mocking style) covering:
     - Restores `PROFILES`, `MODE_OVERRIDE`, and `CLEAN_SLATE` together
       when `CONFIG_FLAGS_PROVIDED=false` and the container exists —
       mock `docker()` to return `base,docker` / `static` / `true` for the
       three labels (dispatch on the `-f` format-string argument content,
       matching the existing `is_build_stale()` / `_ssh_mount_is_fresh()`
       tests' pattern of branching on `"$*"`), and assert
       `PROFILES[*]` = `'base docker'`, `MODE_OVERRIDE` = `static`,
       `CLEAN_SLATE` = `true`.
     - This is the direct regression case for the bug's root cause: a
       sandbox created via `create --mode static` records
       `ai.sandbox.mode=static`; after this fix, a bare `enter`
       restores `MODE_OVERRIDE=static`. Per the unchanged
       `EFFECTIVE_MODE` computation at `src/index.sh:142-159`
       (`elif [ -n "${MODE_OVERRIDE}" ]; then EFFECTIVE_MODE="${MODE_OVERRIDE}"`),
       this guarantees `EFFECTIVE_MODE=static`, which is what makes the
       `src/index.sh:156-159` preflight gate (`... && EFFECTIVE_MODE = mirror`)
       evaluate false and skip `check_host_plugin_conflicts` — the first
       symptom in the bug report. Add an inline comment on the test noting
       this connection so the regression intent is legible without
       re-deriving it.
     - Does **not** restore anything when `CONFIG_FLAGS_PROVIDED=true` —
       pre-set `PROFILES`, `MODE_OVERRIDE`, `CLEAN_SLATE` to sentinel
       values, call with a `docker()` mock that would return different
       labels if invoked, and assert the sentinels are unchanged (and,
       ideally, that `docker` was never called — a `called=true` flag set
       inside the mock is the existing pattern used elsewhere in this
       spec file, e.g. `cleanup_stale_container()`'s tests).
     - Does not restore anything when no container exists (`docker
       inspect` fails / `is_container_running_or_stopped` returns
       failure) — sentinels unchanged.
     - Leaves `MODE_OVERRIDE` / `CLEAN_SLATE` unchanged (not set to an
       empty string) when the corresponding label is empty/absent, while
       still restoring `PROFILES` if that label is present — covers a
       legacy container created before these labels existed.
   - A new `Describe 'running_config_matches()'` block (this function
     currently has no test coverage at all). Cover at minimum:
     - Returns `2` when no container is running (mirrors the
       `is_container_running` failure path already used in this file's
       `_ssh_mount_is_fresh()` tests).
     - Returns success (`0`) when every compared field — image tag,
       profile-hash, mode, no-isolate-config, docker-proxy, clean-slate —
       matches between the mocked `docker inspect` labels and the
       caller-scope variables (`AI_SANDBOX_IMAGE_TAG`,
       `PROFILE_COMPOSITION_HASH`, `EFFECTIVE_MODE`, `NO_ISOLATE_CONFIG`,
       `EFFECTIVE_PROXY`, `AI_SANDBOX_CLEAN_SLATE`). Set up this case as
       the second symptom's regression: labels recorded at create time
       were `ai.sandbox.mode=static` and `ai.sandbox.clean-slate=true`
       (i.e. the sandbox was created with `--clean --mode static`); set
       `EFFECTIVE_MODE=static` and `AI_SANDBOX_CLEAN_SLATE=true` in caller
       scope (the values `restore_saved_config()` + the unchanged
       `EFFECTIVE_MODE` computation now produce after this fix) — assert
       `running_config_matches` returns `0`, i.e. no recreate-confirmation
       prompt.
     - Returns failure (`1`) when the `mode` label disagrees with
       `EFFECTIVE_MODE` (e.g. label `static`, `EFFECTIVE_MODE=mirror` —
       the pre-fix bug's actual recomputed value) — this characterizes
       *why* the restore fix in this task matters: it documents the exact
       mismatch that produced the false-positive prompt before the fix,
       without asserting anything about `restore_saved_config()` itself
       (`running_config_matches()` is unchanged by this task; only its
       inputs are fixed upstream).

## Validation

- `make build` succeeds (rolls `src/` into `bin/ai-sandbox.sh`).
- `make lint` passes (shellcheck across `src/`, including the new
  `restore_saved_config()` function; add an inline reason comment if any
  disable is needed).
- `shellspec test/unit/ai_sandbox_spec.sh` passes, including the new
  `restore_saved_config()` and `running_config_matches()` describe blocks.
- `make test.unit` passes in full (no regressions in other spec files).
- Manual trace-through (no live Docker required, just re-reading the
  edited code): confirm that for `CMD=enter`, `CONFIG_FLAGS_PROVIDED=false`,
  a running/stopped container with labels `ai.sandbox.mode=static` and
  `ai.sandbox.clean-slate=false`, `restore_saved_config()` sets
  `MODE_OVERRIDE=static`; then confirm by inspection that
  `src/index.sh:142-159`'s unchanged `EFFECTIVE_MODE` computation yields
  `static` from that input, and that `src/index.sh:156-159`'s unchanged
  preflight gate is therefore skipped.
- `grep -n 'ai-sandbox-\${SANDBOX_NAME}' src/utils.sh` inside the new
  function should return nothing — confirms `sandbox_container_name()` is
  used for all three label lookups instead of the literal string.
- Confirm `src/index.sh:73-87`'s old inline block is gone and the call
  site is now just the `restore_saved_config` call guarded by
  `[ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]`.
- Confirm `docker/docker-compose.yaml` is unmodified (labels already
  existed; this task only changes the reader side).
- Confirm `plan/followups.yaml` item `AL7i` (marketplace/plugin config
  persistence) is untouched — this task must not add any restore logic
  for `--add-marketplace` / `--enable-plugin` / `--enable-all` or their
  (currently nonexistent) docker labels; that is explicitly out of scope
  and tracked separately.

## Assumptions

- The two symptoms in the bug report (host-process preflight running
  when it shouldn't; false-positive recreate-confirmation prompt) are
  both fully explained by `MODE_OVERRIDE`/`CLEAN_SLATE` not being restored
  — no other code path contributes to either symptom. This was confirmed
  by reading `src/index.sh:142-159` (`EFFECTIVE_MODE` computation),
  `src/index.sh:153-159` (preflight gate), and `src/utils.sh:85-102`
  (`running_config_matches`), none of which need to change themselves;
  they only need correct inputs.
- `restore_saved_config()` is the right home for this logic (in
  `src/utils.sh`, alongside `is_container_running_or_stopped()` and
  `running_config_matches()`) rather than, say, `src/options.sh` — this
  logic runs after option parsing and depends on Docker state
  (`docker inspect`), not on argv, so it belongs with the other
  Docker-state helpers in `utils.sh`, not with the pure-argv parsing in
  `options.sh`.
- `test/unit/plugin_preflight_spec.sh` does not need changes for this
  task — it covers host-process/plugin-conflict detection and volume-map
  generation, a different concern from the mode/clean-slate restore
  fixed here. All new regression tests fit naturally in
  `test/unit/ai_sandbox_spec.sh`, which already tests other `utils.sh`
  Docker-state helpers (`ensure_image()`, `is_build_stale()`,
  `_ssh_mount_is_fresh()`, `cleanup_stale_container()`) with the same
  `docker()` mocking idiom this task's new tests will use.
- No `test/integration/` coverage is required for this fix. The
  restore-then-compute chain is fully exercised by unit tests against the
  extracted `restore_saved_config()` and the existing
  `running_config_matches()` function; a live-Docker integration test
  would exercise the same logic at higher cost for no additional
  assurance.

## Status

- **Outcome:** succeeded
- **Date:** 2026-07-06
- **Implementation:** Extracted the inline restore block at the former
  `src/index.sh:73-87` into `restore_saved_config()` in `src/utils.sh`
  (placed just before `running_config_matches()`, after
  `profile_has_capability()`). The function keeps the same
  `CONFIG_FLAGS_PROVIDED != "true"` + `is_container_running_or_stopped`
  gating (returns early with no side effects otherwise), and now restores
  all three fields — `PROFILES` (`ai.sandbox.profiles`), `MODE_OVERRIDE`
  (`ai.sandbox.mode`), and `CLEAN_SLATE` (`ai.sandbox.clean-slate`) — each
  guarded by `[ -n "<value>" ]` and each looked up via
  `sandbox_container_name()` (no literal `ai-sandbox-${SANDBOX_NAME}`
  string inside the function). `src/index.sh`'s call site now reads simply
  `restore_saved_config` under the unchanged
  `[ "${CMD}" == "start" ] || [ "${CMD}" == "enter" ]` guard; nothing else
  in `src/index.sh` changed. `make build` was re-run to refresh
  `bin/ai-sandbox.sh`.
- **Tests added:** `test/unit/ai_sandbox_spec.sh` gained a
  `Describe 'restore_saved_config()'` block (4 examples: restores all three
  fields together; no-op when `CONFIG_FLAGS_PROVIDED=true`, asserting
  `docker` is never invoked; no-op when no container exists; leaves
  `MODE_OVERRIDE`/`CLEAN_SLATE` unchanged for a legacy container whose
  labels are absent while still restoring `PROFILES`) and a
  `Describe 'running_config_matches()'` block (3 examples: returns `2` with
  no running container; returns `0` when every compared field matches,
  covering the `--clean --mode static` regression scenario; returns `1`
  when the `mode` label disagrees with `EFFECTIVE_MODE`, characterizing the
  pre-fix false-positive recreate prompt).
- **Validation summary:** `make build` succeeded; `make lint` passed clean
  (added one function-scoped `# shellcheck disable=SC2034` with an inline
  reason comment on `restore_saved_config()`, since the three assigned
  globals are consumed downstream in `src/index.sh` rather than within
  `utils.sh` itself); `shellspec test/unit/ai_sandbox_spec.sh` passed (104
  examples, 0 failures); `make test.unit` passed in full (129 examples, 0
  failures); the manual trace-through and both `grep`/inspection checks in
  `## Validation` were confirmed by re-reading the edited code.
- **Affected files (repo-relative, in task worktree
  `phase-01-task-01-restore-mode-and-clean-slate-o`):** `src/index.sh`,
  `src/utils.sh`, `test/unit/ai_sandbox_spec.sh`, `bin/ai-sandbox.sh`
  (rollup output, regenerated by `make build`).
- **Assumptions relied on:** all three `## Assumptions` in this task doc
  were relied on as written — no changes needed to
  `test/unit/plugin_preflight_spec.sh`, no `test/integration/` coverage
  added, and the two bug-report symptoms were confirmed fully explained by
  `MODE_OVERRIDE`/`CLEAN_SLATE` not being restored (`running_config_matches()`
  and the `EFFECTIVE_MODE` computation were not modified).
- `plan/followups.yaml` item `AL7i` (marketplace/plugin persistence) was
  not touched, per this task's explicit out-of-scope note.

## References

- `src/index.sh:73-87` — the existing profiles-restore block to extract
  and extend.
- `src/index.sh:142-159` — `EFFECTIVE_MODE` computation (unchanged by
  this task; documents why restoring `MODE_OVERRIDE`/`CLEAN_SLATE` fixes
  both symptoms).
- `src/index.sh:153-159` — the plugin-conflict preflight gate (unchanged;
  consumes `EFFECTIVE_MODE`).
- `src/utils.sh:59-61` — `is_container_running_or_stopped()`, the existing
  gating helper reused unchanged.
- `src/utils.sh:85-102` — `running_config_matches()`, the function whose
  false-positive mismatch is the second symptom; gets new test coverage
  but no code changes.
- `docker/docker-compose.yaml:36-57` — the `labels:` block recording
  `ai.sandbox.mode`, `ai.sandbox.clean-slate`, and `ai.sandbox.profiles`
  at create/(re)start time; read-only reference, no changes needed.
- `test/unit/ai_sandbox_spec.sh` — existing `docker()`-mocking test
  patterns to follow (`is_build_stale()`, `_ssh_mount_is_fresh()`,
  `cleanup_stale_container()` describe blocks are the closest analogues).
- `plan/followups.yaml` item `AL7i` — the explicitly out-of-scope
  marketplace/plugin persistence gap; do not address it here.
- Commit `5722240` (`Validate sandbox name format before docker compose`)
  — this repo's precedent for landing a small `options.sh`/`utils.sh`
  bugfix together with its regression tests in a single change.
