# Full Config Restore

## Purpose and scope

Make the **entire** ai-sandbox container configuration reconstructable from Docker-side artifacts on a bare `enter`/`start` (no flags), closing followup **AL7i** and the wider bug class it belongs to.

Today only `profiles`, `mode`, and `clean-slate` survive a bare `enter`/`start`. Four config-input dimensions are silently dropped:

- `--no-isolate-config` — persisted as a label but **never restored**, which both drops the setting and triggers a false-positive "stop and recreate" prompt (same shape as the `mode`/`clean-slate` bug the `enter-mode-restore` plan just fixed).
- `--add-marketplace`, `--enable-plugin`, `--enable-all` — **never persisted at all** (followup AL7i); the reconstructed container loses its requested marketplace/plugin setup.

The root cause is that `restore_saved_config` and `running_config_matches` (both in `src/utils.sh`) cover an **incomplete and inconsistent** set of config dimensions. The fix persists the complete config-input set and makes both functions cover every dimension.

**Design basis:** the concrete persistence design is specified in [config persistence design recommendation](./notes/config-persistence-design.md) and is the authority for the shape/placement decisions below. In brief: persist all seven config *inputs* as a single base64-encoded JSON Docker label `ai.sandbox.config`; restore reads that one label to rehydrate every input and lets the existing pipeline re-derive the rest; matches is extended to compare the full derived-config set. No external state file is introduced. No legacy-label fallback is implemented — see "What must not change" below.

**What must change:** persist the full config-input record at create time; restore all inputs on bare `enter`/`start`; reconcile `running_config_matches` to the complete effective-config dimension set. **What must not change:** the plain `ai.sandbox.profiles` label (`ai-sandbox list` depends on it); the `CONFIG_FLAGS_PROVIDED != true` restore gate (explicit flags always win); `profile-installer.js` as the single source of truth for profile resolution.

**Success criteria:** a sandbox created with any combination of `--profile`/`--mode`/`--no-isolate-config`/`--add-marketplace`/`--enable-plugin`/`--enable-all`/`--clean` reproduces that exact effective configuration on a subsequent bare `enter`/`start`, with no false-positive recreate prompt; pre-existing/label-less containers (missing `ai.sandbox.config`) are out of scope — no fallback restore is attempted for them, and they simply keep today's un-configured default behavior; `make lint` and `make test.unit` pass.

Explicitly out of scope: the unrelated followups `sSU2` (fix-name-flags-parsing) and `HSjz` (flow-tooling); `plan/followups.yaml` is not modified.

## Current status

Single-session plan. Phase 01 (Full Config Restore) begins first; its four tasks are sequential (Task 002 depends on the label schema and shares `src/utils.sh`/the test file with Task 001; Task 003 depends on the `ai.sandbox.config` label Task 001 introduces and is sequenced after Task 002 to avoid `test/unit/ai_sandbox_spec.sh` merge friction; Task 004 is independent in content — pure `docker/` label additions — but is sequenced last since it was added after the others during plan review). Phase 02 (Documentation Updates) runs after Phase 01 lands. Pre-condition: dependencies are not installed in the plan worktree, but implementation happens on task branches where `make build`/`make lint`/`make test.unit` are available. No blocking pre-conditions.

## Overview

### Phase 01 — Full Config Restore

Implements the persistence/restore contract from the design note. Four tasks (not parallel-eligible): Task 002 shares `src/utils.sh`/the test file with Task 001 and depends on the label schema Task 001 defines; Task 003 depends on the `ai.sandbox.config` label Task 001 introduces and is sequenced after Task 002 purely to avoid `test/unit/ai_sandbox_spec.sh` merge friction (no functional dependency on Task 002's content); Task 004 is functionally independent (touches only `docker/Dockerfile` and `docker/scripts/assemble-dockerfile.sh`) but is ordered last as a small addendum:

- **001 — Persist And Restore Full Config Inputs.** Assemble the seven-dimension config-input JSON in `src/index.sh`, base64-encode it (single-line, mirroring `src/credentials.sh`), and write it to the new `ai.sandbox.config` label in `docker/docker-compose.yaml`. Extend `restore_saved_config` (`src/utils.sh`) to decode that label and rehydrate all seven input globals (`PROFILES`, `MODE_OVERRIDE`, `NO_ISOLATE_CONFIG`, `CLEAN_SLATE`, `CLI_MARKETPLACES`, `CLI_PLUGINS`, `CLI_ENABLE_ALL`) under the existing `CONFIG_FLAGS_PROVIDED != true` gate. No legacy-label fallback is implemented — a container missing `ai.sandbox.config` simply restores nothing extra. Add regression tests. This closes AL7i and the `no-isolate-config` restore gap and eliminates the false-positive recreate prompt.

- **002 — Reconcile Running-Config Match To Full Dimension Set.** Add plain derived labels `ai.sandbox.marketplaces`, `ai.sandbox.plugins`, `ai.sandbox.enable-all-plugins` (from the effective `AI_SANDBOX_*` env vars) to `docker/docker-compose.yaml`, and extend `running_config_matches` (`src/utils.sh`) to compare them against the current invocation's effective values, so an explicit invocation that changes marketplaces/plugins is correctly detected as a config change. Add regression tests. Completes the restore/matches reconciliation (design note §2.3).

- **003 — Add Detail Alias And Config Display.** Add `detail` as a pure alias for the `status` per-instance command (`src/options.sh`: `PER_INSTANCE_COMMANDS`, `RESERVED_NAMES`, normalized to `CMD="status"` during parsing), and extend `status`/`detail` (`src/status.sh`) to decode and display the persisted `ai.sandbox.config` label — as YAML via `yq -y .` in human output (falling back to `jq .` when `yq` is unavailable), and as a `config` JSON key in `--json` output. Update `README.md` (CLI reference table, `yq` as an optional prerequisite) and add regression tests. Depends on Task 001's label; sequenced after Task 002 to avoid shared-test-file merge friction.

- **004 — Add Managed Image Label.** Mirror the container side's `ai.sandbox.managed="true"` label onto images: add it to the static full `docker/Dockerfile` and, for profile-assembled builds, emit it unconditionally from `docker/scripts/assemble-dockerfile.sh` (alongside the existing conditional `ai.sandbox.profile-hash` emission). Lets images be filtered by label (`docker images --filter label=ai.sandbox.managed=true`) the same way containers already are — images were previously identifiable only by the `ai-sandbox:` name prefix. Raised during plan review; unrelated to config persistence but grouped here as a small `docker/`-area addendum.

### Phase 02 — Documentation Updates

- **001 — Update Architecture Docs.** Document the new container-side config-persistence/restore contract (the `ai.sandbox.config` label, the reconciled `restore_saved_config`/`running_config_matches` dimension set, and the input-vs-derived model) in `docs/architecture.md`; check `docs/ai-sandbox-profiles-spec.md` for any needed cross-reference. Registered because Phase 01 adds significant tracked container state (a new persisted-config contract).
