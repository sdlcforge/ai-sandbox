# Phase 04 Task 001 — Tests and QA Gate

**Tier:** `sonnet-high`
**Depends on:** Phase 02 Task 001 (CLI flags), Phase 03 Task 001 (container plugin setup)
**Parallel-eligible with:** nothing (final verification gate)

---

## Purpose and scope

Write or update unit tests for all new behavior introduced in Phases 01–03, then run the full `make build && make lint && make test` gate. Fix any regressions found. The task is complete only when all three make targets pass cleanly.

This is a verification-and-hardening task — it does not add new features, only validates that the feature works correctly through automated testing.

---

## Requirements

### 1. Flag-parsing tests — `test/unit/ai_sandbox_spec.sh`

Ensure the following are covered (Phase 02 may have already written some of these; add any that are missing):

**`--add-marketplace` acceptance:**
- `--add-marketplace https://registry.example.com` — `CLI_MARKETPLACES` contains the value
- `--add-marketplace file:///home/user/plugin` — `CLI_MARKETPLACES` contains the value
- Multiple invocations accumulate: `--add-marketplace A --add-marketplace B` → `CLI_MARKETPLACES` contains both in order

**`--add-marketplace` rejection:**
- `--add-marketplace ftp://bad` — exits non-zero; stderr contains "must start with https:// or file://"
- `--add-marketplace` with no following argument — exits non-zero

**`--enable-plugin`:**
- `--enable-plugin foo` — `CLI_PLUGINS` contains `foo`
- `--enable-plugin foo --enable-plugin bar` — `CLI_PLUGINS` contains both
- `--enable-plugin` with no following argument — exits non-zero

**`--enable-all`:**
- `--enable-all` — `CLI_ENABLE_ALL=true`
- Absence of `--enable-all` — `CLI_ENABLE_ALL=false` (the default)

### 2. Compose overlay tests — `test/unit/ai_sandbox_spec.sh`

Test the `generate_volume_override` output when `file://` marketplaces are present. These tests use the `__SOURCED__=1` pattern to call the function directly.

- When `AI_SANDBOX_MARKETPLACES="file:///tmp/my-plugin"`, the generated compose YAML contains a bind mount with `source: /tmp/my-plugin`, `target: /tmp/my-plugin`, and `read_only: true`.
- When `AI_SANDBOX_MARKETPLACES="https://example.com"` (no `file://` entries), no new volume entries are added to the generated compose YAML.
- When `AI_SANDBOX_MARKETPLACES=""`, the function is a no-op for the volume section.
- Multiple `file://` entries produce multiple bind mounts.

### 3. Profile-installer JSON output tests

Ensure the following are covered (Phase 01 may have already written some of these; add any that are missing):

- A profile with `marketplaces: [https://example.com]` produces a `### PROFILE_JSON ###` block where `marketplaces` equals `["https://example.com"]`.
- A profile with `enable_all_plugins: true` produces `"enable_all_plugins": true` in the JSON block.
- Two profiles composed together union their `marketplaces` lists with no duplicates.
- `enable_all_plugins: true` on one profile and `false` (or absent) on the other produces `true` in the output.
- Both `marketplaces` and `enable_all_plugins` appear in the JSON block even when the profile uses default values (`[]` and `false` respectively).

### 4. Build, lint, and test gate

Run in this order and fix any failures before declaring the task complete:

```bash
make build     # must succeed — rolls src/ into bin/ai-sandbox.sh
make lint      # must pass — shellcheck across src/, docker/, test/
make test      # must pass — unit + integration (integration may be skipped by preflight)
```

If `make test.integration` is gated by the plugin-conflict preflight and cannot run in the CI/dev environment, that is acceptable — document it in the task report. The unit suite (`make test.unit`) must pass in full.

### 5. Regression check

After the gate passes, do a quick manual scan:

- Run `bin/ai-sandbox.sh --help` and confirm the three new flags appear in the output.
- Run `node bin/profile-installer.js` with a profile that has no `marketplaces` or `enable_all_plugins` fields and confirm it still runs cleanly (no regressions in the existing output blocks).
- Confirm `bin/ai-sandbox.sh status` still works (no regressions from `src/index.sh` changes).

---

## Checkpoint hints

This task touches multiple test files and runs the full QA gate. Recommended checkpoints:

1. **Before writing tests:** Run `make test.unit` against the current codebase (with Phases 01–03 merged) to establish a baseline. Any pre-existing failures should be documented and fixed as regressions before adding new tests.

2. **After writing flag-parsing tests:** Run `shellspec test/unit/ai_sandbox_spec.sh` in isolation. Fix failures before moving to the next group.

3. **After writing compose overlay tests:** Run the spec file again. These tests depend on `generate_volume_override` being callable via `__SOURCED__=1` — confirm the function is exported or reachable in the test harness.

4. **After the full gate passes:** Verify with `git diff --stat` that no unintended files were modified. The only files that should be changed in this task are test files and any bug-fixes found during QA (document those fixes in the task report).

---

## Validation

The task is complete when:

- [ ] Unit tests for `--add-marketplace`, `--enable-plugin`, and `--enable-all` flag parsing all pass.
- [ ] Unit tests for `generate_volume_override` with `file://` marketplace entries pass.
- [ ] Unit tests for `profile-installer.js` JSON output (new fields) pass.
- [ ] `make build` exits 0.
- [ ] `make lint` exits 0.
- [ ] `make test.unit` exits 0 (all unit examples pass).
- [ ] `make test` exits 0 or integration tests are skipped by the expected preflight gate (not by a new failure).
- [ ] `bin/ai-sandbox.sh --help` output includes `--add-marketplace`, `--enable-plugin`, and `--enable-all`.
- [ ] No regressions in existing functionality (status, create, enter, profile resolution).
