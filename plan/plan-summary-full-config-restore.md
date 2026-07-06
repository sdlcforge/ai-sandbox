# Plan Summary: Full Config Restore

## What was planned and why

Today, `ai-sandbox` only survives a bare `enter`/`start` (no flags) for three config
dimensions: `profiles`, `mode`, and `clean-slate`. Four other config-input dimensions
were silently dropped on reconstruction:

- `--no-isolate-config` — persisted as a label but never restored, which both drops the
  setting and triggers a false-positive "stop and recreate" prompt (the same bug shape
  the prior `enter-mode-restore` plan had just fixed for `mode`/`clean-slate`).
- `--add-marketplace`, `--enable-plugin`, `--enable-all` — never persisted at all
  (tracked as followup **AL7i**); a reconstructed container silently loses its requested
  marketplace/plugin setup.

The root cause: `restore_saved_config` and `running_config_matches` (both in
`src/utils.sh`) each covered an incomplete and inconsistent subset of config dimensions.

This plan's goal was to make the **entire** container configuration reconstructable
from Docker-side artifacts on a bare `enter`/`start`, closing AL7i and the wider bug
class it belongs to. The design basis was `plan/notes/config-persistence-design.md`:
persist all seven config *inputs* as a single base64-encoded JSON Docker label
(`ai.sandbox.config`); have restore decode that one label and rehydrate every input,
letting the existing pipeline re-derive the rest; extend `running_config_matches` to
compare the full derived-config set. No external state file; no legacy-label fallback
(containers missing the label simply keep today's un-configured default behavior).

Explicitly out of scope: the unrelated followups `sSU2` (fix-name-flags-parsing) and
`HSjz` (flow-tooling); `plan/followups.yaml` itself was not to be modified by task work.

## What shipped

### Phase 01 — Full Config Restore

- **Task 001 — Persist And Restore Full Config Inputs.** Assembled all seven
  config-input dimensions into JSON in `src/index.sh`, base64-encoded single-line
  (mirroring `src/credentials.sh`), exported as `AI_SANDBOX_CONFIG_B64`, and wired into
  the new `ai.sandbox.config` label in `docker/docker-compose.yaml`. Extended
  `restore_saved_config` (`src/utils.sh`) to decode that label and rehydrate all seven
  input globals (`PROFILES`, `MODE_OVERRIDE`, `NO_ISOLATE_CONFIG`, `CLEAN_SLATE`,
  `CLI_MARKETPLACES`, `CLI_PLUGINS`, `CLI_ENABLE_ALL`) under the unchanged
  `CONFIG_FLAGS_PROVIDED != true` gate — no legacy-label fallback. Closes AL7i and the
  `no-isolate-config` restore gap and eliminates the false-positive recreate prompt.
  `running_config_matches` and `profile-installer.js` were intentionally left untouched
  (covered by Task 002). `make build`/`make lint`/`make test.unit` all passed (131
  examples, 0 failures).
  Merged as `e4bade38cb2c7ad29105f125f9bed669fc8ded09` (branch commit `e7db5ed`).

- **Ad-hoc phase-review fix (between Phase 01 and Phase 02).** Not a plan task, but
  surfaced by the Phase 01 phase-review gate and landed as part of this session's work:
  hardened two non-hermetic `yq` tests, added marketplace-scheme validation to
  `restore_saved_config`, and extended `docs/architecture.md`'s `--docker` risk callout
  to cover the newly-durable config-restore path. Commit `6281e47`
  ("fix(security-review): harden yq tests, validate restored marketplace scheme,
  document label-persistence risk"), merged as `42a235e`.

- **Task 002 — Reconcile Running-Config Match To Full Dimension Set.** Added three
  derived labels (`ai.sandbox.marketplaces`, `ai.sandbox.plugins`,
  `ai.sandbox.enable-all-plugins`, computed from the effective `AI_SANDBOX_*` env vars)
  to `docker/docker-compose.yaml`, and extended `running_config_matches` in
  `src/utils.sh` to compare them against the current invocation's effective values —
  using `:-` defaults so pre-existing/legacy containers don't false-positive. The five
  existing comparisons and the Task 001 restore path were untouched. Added 5 regression
  tests; `make build`/`make lint`/`make test.unit` passed (136 examples, 0 failures).
  Design note §2.3/§2.6 followed with no deviations.
  Merged as `17005b6fa45ec0fb40cfe79c703f0a59fe01534c` (branch commit `beb233a`).

- **Task 003 — Add Detail Alias And Config Display.** Added `detail` as a pure alias
  for the `status` per-instance command in `src/options.sh` (`PER_INSTANCE_COMMANDS`,
  `RESERVED_NAMES`, single normalization point to `CMD="status"` covering both bare and
  `<name> detail` forms) — no downstream `CMD==status` checks needed changes. Extended
  `src/status.sh` to decode and display the `ai.sandbox.config` label: a
  `Configuration:` section via `yq -y .` in human output, falling back to `jq .` when
  `yq` is unavailable/non-functional, and a `config` key (null when absent) in `--json`
  output. Fixed a genuine exit-code-leak bug the new code introduced, caught by the new
  absent-label regression test. Updated `README.md` (CLI reference table, `yq` noted as
  an optional prerequisite). `make build`/`make lint`/`make test.unit` passed (145
  examples, 0 failures).
  Merged as `55cc455c3bf8fb50aca238a3fb9a0a5b144db90d` (branch commit `50f8541`).

- **Task 004 — Add Managed Image Label.** Mirrored the container-side
  `ai.sandbox.managed="true"` label onto images: added it to the static
  `docker/Dockerfile` and emitted it unconditionally from
  `docker/scripts/assemble-dockerfile.sh` for profile-assembled builds (alongside the
  existing conditional `ai.sandbox.profile-hash` emission). Enables
  `docker images --filter label=ai.sandbox.managed=true` filtering, matching existing
  container-level filtering; images were previously identifiable only by the
  `ai-sandbox:` name prefix. All validation passed; no existing tests broken.
  Merged as `b2f224870b7c788670f6a92754bb815543d89f17` (branch commit `c29b7db`).

### Phase 02 — Documentation Updates

- **Task 001 — Update Architecture Docs.** Added a "Config persistence and restore"
  subsection to `docs/architecture.md`'s Key design decisions, documenting the
  `ai.sandbox.config` label, the input-vs-derived model, `restore_saved_config`'s
  no-fallback behavior, the new marketplace-scheme validation, and
  `running_config_matches`'s nine-dimension comparison. Updated the Docker-access
  section's forward-reference and the Status-as-interface section to cover the `detail`
  alias and Configuration display. Confirmed `docs/ai-sandbox-profiles-spec.md` needed
  no change. Docs-only; no code touched.
  Merged as `36ed5e16e06db60f151d6f44535ee2e5cca55fe7` (branch commit `d6b8412`).

## Key decisions

- **No legacy-label fallback.** Explicit product decision: a container missing the new
  `ai.sandbox.config` label restores nothing extra rather than attempting to
  reconstruct config from older/partial label sets. Pre-existing/label-less containers
  are explicitly out of scope and keep today's un-configured default behavior.
- **Persist CLI deltas, not the profile-merged set.** The persisted config record
  captures the seven raw config *inputs* from the invocation (profiles, mode,
  no-isolate-config, clean-slate, CLI marketplaces/plugins/enable-all) rather than the
  fully profile-merged effective configuration — restore rehydrates inputs and lets the
  existing pipeline re-derive the rest, keeping `profile-installer.js` the single source
  of truth for profile resolution.
- **Single base64-encoded JSON label as the persistence mechanism.** All seven inputs
  are assembled into one JSON object, base64-encoded single-line (mirroring the
  existing `src/credentials.sh` convention), and written to one label
  (`ai.sandbox.config`), avoiding an external state file and keeping the container
  self-describing.
- **"Minimal fix + document risk" over adding a confirmation prompt.** The Phase 01
  phase-review security lens flagged that config restore makes marketplace/plugin
  config durable and auto-reapplying on bare `enter`/`start` — chaining with the
  already-accepted `--docker` proxy-escape risk to potentially widen the effective
  attack surface across restores. Rather than adding a new confirmation-prompt feature
  (which would have expanded scope), the user chose the minimal fix: harden the
  non-hermetic `yq` tests, add marketplace-scheme validation to `restore_saved_config`
  (rejecting malformed/unexpected schemes on restore), and document the risk explicitly
  in `docs/architecture.md`'s existing `--docker` risk callout. This shipped as the
  ad-hoc commit `6281e47` / merge `42a235e` described above.
- **Task ordering within Phase 01 driven by merge-friction avoidance, not functional
  dependency.** Task 003 depends functionally only on Task 001's label, but was
  sequenced after Task 002 purely to avoid `test/unit/ai_sandbox_spec.sh` merge
  friction. Task 004 is functionally independent (pure `docker/`-area label additions)
  but was ordered last since it was added during plan review.

## Follow-up items

Three non-blocking phase-review findings recorded as followups tagged
`full-config-restore` (present in `/Users/zane/playground/ai-sandbox/plan/followups.yaml`;
not yet reflected in this worktree's copy at the time of writing):

- **`85Na` — Duplicate jq array conversion in `src/index.sh`.** The new
  config-persistence block (~lines 146-160) recomputes the same
  `jq -R . | jq -s .` array-JSON conversion for `CLI_MARKETPLACES`/`CLI_PLUGINS` that
  the pre-existing CLI-merge block (~lines 112-132) already computed into
  `_cli_marketplaces_json`/`_cli_plugins_json`. Should hoist/reuse instead of
  recomputing; low materiality (invocation-scoped, not looped) — bundle with other
  `src/index.sh` cleanup.
- **`o0pc` — Consolidate per-label `docker inspect` calls.** `running_config_matches()`
  now issues 9 sequential single-field `docker inspect` calls (was 6, +3 from this
  plan's marketplaces/plugins/enable-all reconciliation) where a single multi-field
  `--format` template would do. Explicitly a deliberate style-consistency choice per the
  phase's design note, not a regression — extends the pre-existing followup `4DzF`
  (restore-fix); bundle both `restore_saved_config` and `running_config_matches`
  consolidation together.
- **`qVbA` — No size bound on config label decode.** `restore_saved_config` and
  `status.sh`'s config decode impose no size bound on the decoded `ai.sandbox.config`
  label before base64-decoding/`jq`-parsing it. Label is only writable at
  container-create time by the host process, so practical risk is low; optional
  defense-in-depth would bound the decoded payload size before piping into `jq`.

Pre-existing followups still open (not created by this session, unaffected by this
plan's scope):

- **`sSU2` — Flags-before-command-word mis-parse** (`fix-name-flags-parsing`):
  `parse_options()` mis-routes when a config flag precedes the per-instance command
  word (e.g. `ai-sandbox myname --profile x start`), silently absorbing `start` into
  the passthrough `ARGS` array instead of recognizing it as `CMD`. Needs its own scoped
  fix. Explicitly out of scope for this plan.
- **`4DzF` — Combine sequential `docker inspect` calls** (`restore-fix`): the
  original observation that `restore_saved_config()` issues multiple sequential
  single-field `docker inspect` calls where one multi-field format string would do;
  now extended by `o0pc` above to also cover `running_config_matches()`'s larger call
  count.
- **`HSjz` — `plan_register`/`plan_deregister` no-op vs `.flow/`** (`flow-tooling`):
  Flow-tooling gap where `.flow/` being gitignored causes `plan_register`/
  `plan_deregister`'s git-commit step to silently no-op. Explicitly out of scope for
  this plan; `plan/followups.yaml` was not modified by task work per the plan's
  overview.
- **`S6Up` — Task agent mid-response API disconnect** (`restore-fix`): informational
  record from a prior plan (`enter-mode-restore`) noting a task agent's connection
  dropped after committing but before reporting; manager verified the commit directly.
  No action needed.

## Final Task State

# TODO

## Purpose and scope

Tracking document for the active plan.

## Tasks

### Phase 01 — Full Config Restore

- [x] [001-persist-and-restore-full-config-inputs.md](./phase-01-full-config-restore/001-persist-and-restore-full-config-inputs.md) — tier `sonnet-high` · branch `phase-01-task-01-persist-and-restore-full-confi` · commit `e7db5ed` · merge `e4bade38cb2c7ad29105f125f9bed669fc8ded09`
- [x] [002-reconcile-running-config-match.md](./phase-01-full-config-restore/002-reconcile-running-config-match.md) — tier `sonnet-high` · branch `phase-01-task-02-reconcile-running-config-match` · commit `beb233a` · merge `17005b6fa45ec0fb40cfe79c703f0a59fe01534c`
- [x] [003-add-detail-alias-and-config-display.md](./phase-01-full-config-restore/003-add-detail-alias-and-config-display.md) — tier `sonnet-high` · branch `phase-01-task-03-add-detail-alias-and-config-di` · commit `50f8541` · merge `55cc455c3bf8fb50aca238a3fb9a0a5b144db90d`
- [x] [004-add-managed-image-label.md](./phase-01-full-config-restore/004-add-managed-image-label.md) — tier `haiku-med` · branch `phase-01-task-04-add-managed-image-label` · commit `c29b7db` · merge `b2f224870b7c788670f6a92754bb815543d89f17`

### Phase 02 — Documentation Updates

- [x] [001-update-architecture-docs.md](./phase-02-doc-updates/001-update-architecture-docs.md) — tier `sonnet-high` · branch `phase-02-task-01-update-architecture-docs` · commit `d6b8412` · merge `36ed5e16e06db60f151d6f44535ee2e5cca55fe7`
