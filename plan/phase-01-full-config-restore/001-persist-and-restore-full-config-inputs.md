# Persist And Restore Full Config Inputs

## Purpose and scope

Persist the **complete** set of ai-sandbox config *inputs* to a Docker container label at create time, and restore all of them on a bare `enter`/`start` (no flags), so the container's original configuration is fully reconstructed. This closes followup **AL7i** (`--add-marketplace`/`--enable-plugin`/`--enable-all` silently dropped) and the parallel `--no-isolate-config` restore gap (persisted as a label today but never restored, which also causes a false-positive "stop and recreate" prompt).

This is a direct source edit to the launcher — no standard skill applies. Follow the concrete design in [config persistence design recommendation](../notes/config-persistence-design.md) (authoritative for shape/placement); do not re-derive it. Edit `src/` modules and run `make build` after edits (never edit `bin/ai-sandbox.sh`).

## Requirements

Implement the input-persistence half of the design note (§2.1, §2.2, §2.3 restore side):

1. **Assemble the config-input record in `src/index.sh`.** After the CLI-merge block (~line 133, where `PROFILE_JSON`, `PROFILES`, `MODE_OVERRIDE`, `NO_ISOLATE_CONFIG`, `CLEAN_SLATE`, `CLI_MARKETPLACES`, `CLI_PLUGINS`, `CLI_ENABLE_ALL` are all final) and before compose-file assembly, build a JSON object capturing all seven config-input dimensions:
   ```json
   {"version":1,"profiles":[...],"mode":"...","no_isolate_config":<bool>,"clean_slate":<bool>,"marketplaces":[...],"plugins":[...],"enable_all_plugins":<bool>}
   ```
   - `profiles` is the ordered `PROFILES` array; `mode` mirrors `MODE_OVERRIDE` (empty string when no `--mode` was given); `marketplaces`/`plugins` are the CLI-addition arrays `CLI_MARKETPLACES`/`CLI_PLUGINS` (the CLI deltas, **not** the profile-merged effective set — see design note §2.1); the three booleans mirror `NO_ISOLATE_CONFIG`, `CLEAN_SLATE`, `CLI_ENABLE_ALL`. Build the JSON with `jq` (use `--args`/`--argjson` or the array-from-lines pattern already used in the CLI-merge block at `src/index.sh:114-119`).
   - Base64-encode it single-line and export as `AI_SANDBOX_CONFIG_B64`, mirroring the established pattern in `src/credentials.sh:66` (`printf '%s' "${json}" | base64`), with `| tr -d '\n'` appended to guarantee a single-line value on macOS.
2. **Write the label in `docker/docker-compose.yaml`.** Add `ai.sandbox.config: "${AI_SANDBOX_CONFIG_B64:-}"` to the `labels:` block. Leave all existing labels unchanged (`ai.sandbox.profiles` etc. remain — `ai-sandbox list` and `running_config_matches` still depend on them).
3. **Extend `restore_saved_config` in `src/utils.sh`** to rehydrate all seven inputs, keeping the existing `CONFIG_FLAGS_PROVIDED != true` && `is_container_running_or_stopped` gate:
   - Read the `ai.sandbox.config` label; if non-empty, base64-decode and `jq` out each field into the corresponding global: `PROFILES` (from `.profiles`, as a bash array), `MODE_OVERRIDE` (`.mode`), `NO_ISOLATE_CONFIG` (`.no_isolate_config`), `CLEAN_SLATE` (`.clean_slate`), `CLI_MARKETPLACES` (`.marketplaces`, array), `CLI_PLUGINS` (`.plugins`, array), `CLI_ENABLE_ALL` (`.enable_all_plugins`). Only assign a global when the decoded value is present, matching the existing "only set when non-empty" guard style so empty values don't clobber defaults. **No fallback of any kind is implemented:** `restore_saved_config` reads only `ai.sandbox.config`. When the label is absent or empty (including on any container created before this change), the function does nothing further — the "only assign when present" guard already makes this a natural no-op, so no special-casing for the absent-label case is needed. This is an explicit product decision (no external users of this tool yet; a single label-based config regime is preferred over supporting two) — not a regression to guard against.
   - Update the function's leading comment and the `# shellcheck disable=SC2034` justification comment to reflect the added globals (`NO_ISOLATE_CONFIG`, `CLI_MARKETPLACES`, `CLI_PLUGINS`, `CLI_ENABLE_ALL`).
4. **Do not change** the `CONFIG_FLAGS_PROVIDED` gate semantics (explicit flags this run always win), `profile-installer.js`, or the effective-config derivation in `index.sh` — restoring the inputs is sufficient; the existing pipeline re-derives everything else.
5. **Regression tests** in `test/unit/ai_sandbox_spec.sh`, following the patterns added by the `enter-mode-restore` plan for `restore_saved_config`: cover (a) full round-trip restore of all seven dimensions from a mocked `ai.sandbox.config` label; (b) the `no-isolate-config` case specifically (created with it → restored true); (c) marketplaces/plugins/enable-all restore; (d) no-op when the label is absent/empty — confirm `restore_saved_config` exits cleanly and leaves defaults untouched (a lighter assertion than a fallback-restore test, since no fallback exists); (e) the gate — no restore when `CONFIG_FLAGS_PROVIDED=true`. Mock `docker inspect` as the existing tests do.
6. Run `make build` and `make lint`; keep shellcheck clean (any new `disable` carries an inline reason per repo convention).

## Validation

- `make build` regenerates `bin/ai-sandbox.sh` with no manual edits to the rollup.
- `make lint` passes (shellcheck clean across `src/`, `docker/`, `test/`).
- `make test.unit` passes, including the new `restore_saved_config` regression cases.
- Grep confirms the new label is written and read: `grep -n 'ai.sandbox.config' docker/docker-compose.yaml src/utils.sh` shows the write (compose) and read (utils) sites; `grep -n 'AI_SANDBOX_CONFIG_B64' src/index.sh docker/docker-compose.yaml` shows the assembly + interpolation.
- Confirm the seven input globals are all assigned in `restore_saved_config`: `grep -n 'CLI_MARKETPLACES\|CLI_PLUGINS\|CLI_ENABLE_ALL\|NO_ISOLATE_CONFIG\|MODE_OVERRIDE\|CLEAN_SLATE\|PROFILES' src/utils.sh` within the function body.
- Confirm the base64 assembly strips newlines (`tr -d '\n'` present) so the label value is single-line.
- Manual reasoning check (or integration test if the harness is available): a container created with `--no-isolate-config` and `--add-marketplace` reproduces both on a bare `enter` without a recreate prompt.

## Metadata

architectural_impact: true

## References

- [config persistence design recommendation](../notes/config-persistence-design.md) — authoritative design; §2.1 (shape), §2.2 (write timing), §2.3 (restore side), §2.5 (base64 encoding rationale), §2.6 (label inventory).
- `src/index.sh:107-188` — the CLI-merge block and effective-value derivation where `AI_SANDBOX_CONFIG_B64` is assembled and the input globals are final.
- `src/utils.sh:81-112` — the current `restore_saved_config` to extend.
- `src/credentials.sh:60-67` — the established base64 env-var pattern to mirror.
- `docker/docker-compose.yaml:36-57` — the `labels:` block to extend.
- `plan/plan-summary-enter-mode-restore.md` and the existing `restore_saved_config` tests in `test/unit/ai_sandbox_spec.sh` — the regression-test patterns to follow.

## Checkpoint hints

- After assembling `AI_SANDBOX_CONFIG_B64` in `src/index.sh` and adding the compose label (write side complete).
- After extending `restore_saved_config` with the JSON read (read side complete); no legacy fallback is implemented.
- After adding regression tests and `make build`/`make lint`/`make test.unit` pass.
