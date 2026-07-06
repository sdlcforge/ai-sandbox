# Reconcile Running-Config Match To Full Dimension Set

## Purpose and scope

Extend `running_config_matches` (`src/utils.sh`) to compare the **full** effective-config dimension set — adding marketplaces, plugins, and enable-all, which it currently ignores — so that an *explicit* invocation changing any of them (e.g. `enter --add-marketplace NEW` on a container created without it) is correctly detected as a config change and prompts a recreate, instead of silently never applying. This completes the restore/matches reconciliation from the design note (§2.3, §2.6): after Task 001 restore reads the canonical **input** record, this task makes matches cover the same effective dimensions on the **derived** side.

Direct launcher source edit — no standard skill applies. Follow [config persistence design recommendation](../notes/config-persistence-design.md) §2.3 and §2.6. Edit `src/` modules and run `make build` after edits.

## Requirements

Depends on Task 001 (the `ai.sandbox.config` label schema and the config-persistence change must already be in place). Both tasks edit `src/utils.sh` and `test/unit/ai_sandbox_spec.sh`, so this task runs **after** Task 001 (not parallel).

1. **Add three derived labels to `docker/docker-compose.yaml`** in the `labels:` block, written from the effective env vars already exported by `src/index.sh:182-188`:
   - `ai.sandbox.marketplaces: "${AI_SANDBOX_MARKETPLACES:-}"`
   - `ai.sandbox.plugins: "${AI_SANDBOX_PLUGINS:-}"`
   - `ai.sandbox.enable-all-plugins: "${AI_SANDBOX_ENABLE_ALL_PLUGINS:-false}"`
   These are the pipe-joined marketplace/plugin lists and the enable-all bool — the *effective* (profile ∪ CLI) values, matching what the container's `10-plugin-setup` init actually consumes. No new env-var plumbing is needed; these vars already exist in `index.sh`.
2. **Extend `running_config_matches` in `src/utils.sh`** to read the three new labels and compare them against the current invocation's `AI_SANDBOX_MARKETPLACES`/`AI_SANDBOX_PLUGINS`/`AI_SANDBOX_ENABLE_ALL_PLUGINS`, returning `1` (mismatch) on any difference, consistent with the existing comparison style (`[ "${cur_x:-default}" = "${X:-default}" ] || return 1`). Use `:-` defaults so containers lacking the labels (pre-existing / created before this change) compare equal to the empty/false default rather than false-positiving.
3. **Do not** change the input-restore path (Task 001 owns it) or the existing five comparisons (image, `profile-hash`, `mode`, `no-isolate-config`, `docker-proxy`, `clean-slate`) beyond adding the three new ones. Update the function's leading comment to note the added dimensions.
4. **Regression tests** in `test/unit/ai_sandbox_spec.sh`, following the existing `running_config_matches` test patterns: (a) a container whose marketplace/plugin/enable-all labels match the current effective values → returns 0; (b) each of the three dimensions differing in turn → returns 1; (c) a pre-existing container missing the three labels with the current invocation also empty/default → returns 0 (no false-positive recreate for legacy containers). Mock `docker inspect` per the existing tests.
5. Run `make build` and `make lint`; keep shellcheck clean.

## Validation

- `make build`, `make lint`, and `make test.unit` all pass, including the new `running_config_matches` cases.
- `grep -n 'ai.sandbox.marketplaces\|ai.sandbox.plugins\|ai.sandbox.enable-all-plugins' docker/docker-compose.yaml src/utils.sh` shows each of the three new labels written (compose) and read (utils).
- `grep -n 'AI_SANDBOX_MARKETPLACES\|AI_SANDBOX_PLUGINS\|AI_SANDBOX_ENABLE_ALL_PLUGINS' src/utils.sh` shows the three new comparisons inside `running_config_matches`.
- Reasoning check: a container created without any marketplace, entered with an explicit `--add-marketplace X`, now reports a config mismatch (recreate prompt); a legacy container missing the labels, entered bare, still reports a match (no false recreate).

## Metadata

architectural_impact: true

## References

- [config persistence design recommendation](../notes/config-persistence-design.md) — §2.3 (matches completeness), §2.6 (label inventory, redundancy rationale).
- `src/utils.sh:114-135` — the current `running_config_matches` to extend.
- `src/index.sh:182-188` — where `AI_SANDBOX_MARKETPLACES`/`AI_SANDBOX_PLUGINS`/`AI_SANDBOX_ENABLE_ALL_PLUGINS` are derived and exported.
- `docker/docker-compose.yaml:36-57` — the `labels:` block to extend.
- Task 001 (`001-persist-and-restore-full-config-inputs.md`) — prerequisite; defines the label schema and lands the persistence change first.

## Checkpoint hints

- After adding the three derived labels to `docker/docker-compose.yaml`.
- After extending `running_config_matches` with the three comparisons and updating its comment.
- After adding regression tests and `make build`/`make lint`/`make test.unit` pass.
