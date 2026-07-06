# Enter Mode Restore

## Purpose and scope

Fix a bug in `ai-sandbox` where a bare `<name> enter` / `start` invocation (no
flags) fails to restore the container-identity `mode` and `clean-slate`
settings that were recorded when the sandbox was originally created with
`--mode static` and/or `--clean`. Today the config-restore block in
`src/index.sh:73-87` restores only the `--profile` list (from the
`ai.sandbox.profiles` docker label) when `CONFIG_FLAGS_PROVIDED` is `false`;
it does not restore `ai.sandbox.mode` or `ai.sandbox.clean-slate` into
`MODE_OVERRIDE` / `CLEAN_SLATE`. As a result, a bare re-entry recomputes
`EFFECTIVE_MODE` as `mirror` and `CLEAN_SLATE` as `false` regardless of how
the sandbox was actually created, producing two observed symptoms:

1. The host-`claude`-process preflight (`check_host_plugin_conflicts`) runs
   even though the sandbox was created with `--mode static`, which should
   exempt it (the preflight is gated on `EFFECTIVE_MODE = mirror`).
2. `running_config_matches()` (`src/utils.sh:85-102`) then finds a mismatch
   between the recorded `ai.sandbox.mode` / `ai.sandbox.clean-slate` docker
   labels and the (wrongly) recomputed defaults, triggering a false-positive
   "About to stop the running sandbox and recreate it with the requested
   options. Continue?" prompt even though the user changed nothing.

**In scope:**
- Extending the restore logic in `src/index.sh` to also restore `mode` and
  `clean-slate` from their docker labels, mirroring the existing
  profiles-restore pattern, when no explicit `--mode`/`--clean` flag is
  provided on the current invocation (`CONFIG_FLAGS_PROVIDED != true`).
- Extracting the restore logic into a named, testable function in
  `src/utils.sh` (the existing block is bare script below the
  `${__SOURCED__:+return}` guard in `src/index.sh`, so it cannot be
  unit-tested in place — every other index.sh phase that needs test coverage
  is already implemented this way, e.g. `do_create`, `ensure_image`,
  `running_config_matches`). This is the mechanism by which the required
  regression coverage becomes possible, not a scope expansion.
- Regression tests covering: a bare `enter` after `create --mode static`
  does not trigger the host-process preflight, and a bare `enter` after
  `create --clean --mode static` does not trigger the false-positive
  recreate-confirmation prompt.

**Out of scope (hard constraint):** marketplace/plugin configuration
(`--add-marketplace`, `--enable-plugin`, `--enable-all`) is not recorded as
docker labels at all today and is silently dropped on later bare
`enter`/`start` invocations. This is tracked separately as
`plan/followups.yaml` item `AL7i` ("Marketplace/plugin config not
persisted") and must **not** be folded into this plan.

## Current status

No active implementation has started. This is a single-phase bugfix plan.
Phase 1 (`restore-fix`) contains one task combining the fix and its
regression tests, consistent with this repository's existing convention of
landing small, self-contained bugfixes with their tests in a single change
(cf. the `validate_sandbox_name()` fix in commit `5722240`).

## Overview

### Phase 1 — Restore Fix

One task:

1. **Restore Mode And Clean-Slate On Bare Enter**
   (`phase-01-restore-fix/001-restore-mode-and-clean-slate-on-bare-enter.md`)
   — extract the existing profiles-restore block in `src/index.sh:73-87`
   into a new `restore_saved_config()` function in `src/utils.sh`, extend it
   to also restore `MODE_OVERRIDE` from the `ai.sandbox.mode` label and
   `CLEAN_SLATE` from the `ai.sandbox.clean-slate` label (same
   `CONFIG_FLAGS_PROVIDED != true` gate as the existing profiles restore),
   update the `src/index.sh` call site, and add regression tests in
   `test/unit/ai_sandbox_spec.sh` for `restore_saved_config()` and for
   `running_config_matches()` (which currently has no test coverage at all)
   reproducing the false-positive recreate-prompt scenario.

No parallelism opportunities — this is a single task touching a tightly
coupled fix + its tests.

No `doc-updates` phase is needed: this is an internal bugfix that restores
already-intended behavior (a re-entered sandbox should reflect the
configuration it was created with); it does not change any spec-defined
behavior in `docs/ai-sandbox-profiles-spec.md`, does not introduce a new
subsystem, and does not modify a public API or documented topology
connection in `docs/architecture.md`.
