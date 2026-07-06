# Plan Summary: Enter Mode Restore

## What was planned and why

This plan fixed a bug in `ai-sandbox` where a bare `<name> enter` or `start` invocation (without flags) failed to restore the container-identity `mode` and `clean-slate` settings that were recorded when the sandbox was originally created with `--mode static` and/or `--clean`.

The config-restore block in `src/index.sh:73-87` was restoring only the `--profile` list from the `ai.sandbox.profiles` docker label when no explicit flags were provided; it was not restoring `ai.sandbox.mode` or `ai.sandbox.clean-slate` into the `MODE_OVERRIDE` and `CLEAN_SLATE` variables. This caused two observed symptoms:

1. The host-process preflight (`check_host_plugin_conflicts`) ran even though the sandbox was created with `--mode static`, which should exempt it from this check.
2. `running_config_matches()` found a mismatch between the recorded docker labels and the wrongly-recomputed defaults, triggering a false-positive "stop and recreate" confirmation prompt even when the user changed nothing.

## What shipped

**Phase 1: Restore Fix**

Digest: _Extracted src/index.sh:73-87 restore block into restore_saved_config() in src/utils.sh; now also restores MODE_OVERRIDE (ai.sandbox.mode) and CLEAN_SLATE (ai.sandbox.clean-slate) labels, fixing both the false process-check-skip and the false-positive recreate prompt on bare enter/start. Added regression tests for restore_saved_config() and running_config_matches() (129/129 unit tests pass, lint clean)._

**Task 1.1: Restore Mode And Clean-Slate On Bare Enter**
- Task doc: `phase-01-restore-fix/001-restore-mode-and-clean-slate-on-bare-enter.md`
- Merge SHA: `cfa8de31ed33ff70bfadca1c3838a0277e6024b3`
- Status: Complete

The implementation extracted the existing profiles-restore block into a new `restore_saved_config()` function in `src/utils.sh`, extended it to also restore `MODE_OVERRIDE` from the `ai.sandbox.mode` label and `CLEAN_SLATE` from the `ai.sandbox.clean-slate` label (using the same `CONFIG_FLAGS_PROVIDED != true` gate), updated the call site in `src/index.sh`, and added comprehensive regression tests for both `restore_saved_config()` and `running_config_matches()` in `test/unit/ai_sandbox_spec.sh`.

## Key decisions

- **Extraction to `restore_saved_config()`**: The original profiles-restore block in `src/index.sh:73-87` was bare script below the `${__SOURCED__:+return}` guard and could not be unit-tested in place. Extracting it into a named, testable function in `src/utils.sh` followed the existing pattern used by other index.sh phases (e.g., `do_create`, `ensure_image`, `running_config_matches`). This extraction was necessary, not a scope expansion — it is the mechanism by which regression coverage became possible.

- **Consistent label lookup**: The solution uses `sandbox_container_name()` consistently for all label lookups, maintaining architectural alignment with container-naming conventions.

- **Explicit out-of-scope decision**: Marketplace/plugin configuration (`--add-marketplace`, `--enable-plugin`, `--enable-all`) was explicitly scoped out. These settings are not recorded as docker labels at create time and are silently dropped on later bare `enter`/`start` invocations. This is tracked separately as `plan/followups.yaml` item `AL7i` ("Marketplace/plugin config not persisted") and must not be folded into this plan.

## Follow-up items

From `plan/followups.yaml`:

- **AL7i: Marketplace/plugin config not persisted** (tag: `config-restore`, date: 2026-07-06)
  - `--add-marketplace`, `--enable-plugin`, and `--enable-all` are not recorded as docker labels at create time (only `ai.sandbox.profiles` is), so this config is silently dropped on a later bare `enter`/`start` invocation with no flags. The resulting container silently loses the requested marketplace/plugin setup. Discovered while diagnosing the mode/clean-slate restore bug — `src/index.sh:73-87` restore block and `docker-compose.yaml` labels would need extending to cover these fields. Explicitly out of scope for this plan.

- **S6Up: Task agent mid-response API disconnect** (tag: `restore-fix`, date: 2026-07-06)
  - The task agent hit a connection closure mid-response after committing its work but before returning its structured report. The manager verified the commit directly (`git show`, `make lint`, `make test.unit`) and confirmed it fully satisfies the task document's Requirements and Validation sections. No re-dispatch was necessary.

- **4DzF: Combine sequential docker inspect calls** (tag: `restore-fix`, date: 2026-07-06)
  - Phase-review efficiency finding (non-blocking suggestion): `restore_saved_config()` issues three sequential `docker inspect -f ...` calls where a single multi-field format string would do. Noted as consistent with the existing convention in `running_config_matches()` (six sequential calls, unchanged) — a pre-existing pattern being extended, not a new regression. Deferred rather than fixed immediately since a consistent fix would touch both functions.

## Final Task State

# TODO

## Purpose and scope

Tracking document for the active plan.

## Tasks

### Phase 01 — Restore Fix

- [x] [001-restore-mode-and-clean-slate-on-bare-enter.md](./phase-01-restore-fix/001-restore-mode-and-clean-slate-on-bare-enter.md) — tier `sonnet-med` · branch `phase-01-task-01-restore-mode-and-clean-slate-o` · commit `4fbee0523d8d3d9ca512d445698a635b12f4c6f2` · merge `cfa8de31ed33ff70bfadca1c3838a0277e6024b3`
