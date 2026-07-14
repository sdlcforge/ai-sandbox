# Cli Flag And Config Persistence

## Purpose and scope

Introduce the `--static-playground` boolean CLI flag and wire it through the
config-persistence machinery — the persisted `ai.sandbox.config` label's JSON
record, the plain `ai.sandbox.static-playground` label, restore, and
running-config matching — without yet mounting anything. After this task the flag
parses, exports, and round-trips exactly like every other config-changing flag,
but is an inert no-op until the overlay mechanism (Task 002) consumes it.

This is the entry-point task: Task 002 depends on the `STATIC_PLAYGROUND` global
this task introduces.

Files: `src/options.sh`, `src/index.sh`, `docker/docker-compose.yaml`,
`src/utils.sh`. No standard skill; follow the design note and mirror the existing
`NO_ISOLATE_CONFIG` / `allow_egress` patterns exactly. Run `make build` after
editing `src/`.

## Requirements

Implement parts 4, 5 (config-JSON, label, and `export` only — **not** the
`COMPOSE_FILES` assembly or delete/clean cleanup, which belong to Task 002), and
6 of the [design note](../notes/static-playground-design.md).

1. **`src/options.sh`** — add `--static-playground` as a plain boolean flag,
   identical in shape to the existing `--no-isolate-config` case (~line 466):
   sets `STATIC_PLAYGROUND=true` and `CONFIG_FLAGS_PROVIDED=true`. Initialize
   `STATIC_PLAYGROUND=false` alongside `NO_ISOLATE_CONFIG=false` (~line 152). Add
   `STATIC_PLAYGROUND` to both `export` lists (~lines 235 and 639) and to the
   header globals doc comment (~line 37).

2. **`src/index.sh` — config-JSON assembly** (~lines 243-265): add
   `static_playground` as a 9th field. Compute a `_config_static_playground_json`
   (`true`/`false`) local the same way `_config_no_isolate_json` is computed
   (~line 244), then add `--argjson static_playground
   "${_config_static_playground_json}"` and the `static_playground:
   $static_playground` key to the `jq` object. `version` stays `1` (additive
   field, same precedent as the 8th field `allow_egress` — preserve the existing
   comment rationale).

3. **`src/index.sh` — export** (~line 347): add `STATIC_PLAYGROUND` to
   `export EFFECTIVE_PROXY NO_ISOLATE_CONFIG`.

4. **`docker/docker-compose.yaml` — label** (~line 59, immediately after
   `ai.sandbox.no-isolate-config`): add
   `ai.sandbox.static-playground: "${STATIC_PLAYGROUND:-false}"`.

5. **`src/utils.sh` — `restore_saved_config()`** (~line 484): extract
   `static_playground` from the decoded config JSON using the same null-guarded
   boolean pattern as `saved_no_isolate` (~line 522), and assign it to
   `STATIC_PLAYGROUND` only when present (missing/empty → no-op, preserving the
   default). This is what lets a bare `<name> delete`/`start`/`enter` rehydrate
   `STATIC_PLAYGROUND` from the persisted label when the invocation passes no
   flags.

6. **`src/utils.sh` — `running_config_matches()`** (~line 652): add the
   `ai.sandbox.static-playground` label to the `docker inspect` go-template `fmt`
   string (~line 670) and a matching `cur_static_playground` field to the
   `IFS` read (~line 673) and the comparison chain (~line 684-style
   `[ ... ] || return 1`), comparing it against `${STATIC_PLAYGROUND:-false}`.
   Keep the field-count and separator discipline the surrounding code documents
   (empty-value-safe separator, no pipe).

7. **`src/utils.sh` — doc comments**: update the "eight-dimension" / "eight
   input globals" / "eighth field" language to nine throughout the affected
   comments (~lines 459-460, 472-474, 499).

Preserve exactly: the config-JSON `version: 1` (no bump), the base64 encoding
path (`AI_SANDBOX_CONFIG_B64`), the marketplace/allow-egress re-validation
behavior (untouched), and the existing `NO_ISOLATE_CONFIG` behavior.

## Validation

- `make build` succeeds and `make lint` (shellcheck) passes for `src/options.sh`,
  `src/index.sh`, `src/utils.sh`.
- `grep -n 'static-playground\|STATIC_PLAYGROUND\|static_playground' src/*.sh
  docker/docker-compose.yaml` shows: the flag case and init/export in
  `options.sh`; the config-JSON field, export, and label; the restore extraction
  and the `running_config_matches` label + comparison in `utils.sh`.
- No remaining "eight-dimension"/"eighth" wording in `src/utils.sh` referring to
  the config-input record (now nine).
- A manual round-trip check: with `STATIC_PLAYGROUND=true`, the assembled
  `AI_SANDBOX_CONFIG_B64` decodes (base64 → `jq`) to JSON containing
  `"static_playground": true` and `"version": 1`.
- Existing unit tests still pass (`make test.unit`) — this task changes no
  existing behavior, only adds an additive dimension defaulting to `false`.
  (Dedicated unit tests for the new dimension are authored in Task 004.)

## Metadata

architectural_impact: true

## References

- [static-playground design note](../notes/static-playground-design.md) — parts
  4, 5, 6; authoritative design.
- `docs/architecture.md` § "Config persistence and restore" — the eight-dimension
  contract this task extends to nine; explains restore-vs-matches pipeline stages.
- Existing precedent to mirror: the `allow_egress` (8th field) and
  `no_isolate_config` handling across `src/options.sh`, `src/index.sh`,
  `src/utils.sh`, and the `ai.sandbox.allow-egress` / `ai.sandbox.no-isolate-config`
  labels in `docker/docker-compose.yaml`.

## Checkpoint hints

- After `src/options.sh` (flag parse + init + export).
- After `src/index.sh` config-JSON field, export, and the compose-file label.
- After `src/utils.sh` restore + running_config_matches + comment updates.
- After `make build` + `make lint`.

## Status

**Outcome: succeeded.** 2026-07-14.

Implemented the `--static-playground` flag end-to-end through the
config-persistence machinery (parts 4, 5 excluding `COMPOSE_FILES`/delete-
cleanup, and 6 of the design note), as an inert 9th config-input dimension
defaulting to `false`:

- `src/options.sh`: `--static-playground` boolean flag (init, case, both
  export lists, header doc comment).
- `src/index.sh`: `static_playground` field in the config-JSON assembly
  (`_config_static_playground_json` local, `--argjson`/key wiring, `version`
  left at `1`), `STATIC_PLAYGROUND` added to the `export EFFECTIVE_PROXY
  NO_ISOLATE_CONFIG` line, and updated the adjacent "eight config-input
  dimensions" doc comment to nine.
- `docker/docker-compose.yaml`: `ai.sandbox.static-playground:
  "${STATIC_PLAYGROUND:-false}"` label immediately after
  `ai.sandbox.no-isolate-config`; updated the adjacent `ai.sandbox.config`
  doc comment's field list from eight to nine.
- `src/utils.sh`: `restore_saved_config()` extracts `static_playground` with
  the same null-guarded boolean pattern as `no_isolate_config` and assigns
  `STATIC_PLAYGROUND` only when present; `running_config_matches()` adds the
  `ai.sandbox.static-playground` label to the `docker inspect` go-template,
  a `cur_static_playground` read field, and a comparison against
  `${STATIC_PLAYGROUND:-false}`. Updated all "eight-dimension"/"eight
  globals"/"eight-field" doc-comment language to nine throughout both
  functions' comments (the two remaining "eighth" references, at
  `src/utils.sh:460` and `src/index.sh:217`, are intentionally left as-is —
  they correctly describe `allow_egress` as the 8th field, not a stale
  dimension-total).

Preserved exactly, as required: config-JSON `version: 1` (no bump), the
`AI_SANDBOX_CONFIG_B64` base64 path, and existing `NO_ISOLATE_CONFIG`/
marketplace/allow-egress behavior (untouched). Did not touch
`COMPOSE_FILES` assembly or delete/clean volume cleanup (explicitly out of
scope per this task's Requirements — reserved for Task 002).

### Validation results

- `make build` — succeeded.
- `make lint` (shellcheck across `src/options.sh`, `src/index.sh`,
  `src/utils.sh`, and the rest of the configured lint set) — passed, no
  warnings.
- `grep -n 'static-playground\|STATIC_PLAYGROUND\|static_playground' src/*.sh
  docker/docker-compose.yaml` — confirmed present: the flag case + init +
  both export lists in `options.sh`; the config-JSON field + export +
  compose label in `index.sh`/`docker-compose.yaml`; the `restore_saved_config()`
  extraction and `running_config_matches()` label/field/comparison in
  `utils.sh`.
- `grep -rn -i 'eight-dimension\|eight input\|eight globals\|eight config\|all eight\|the eight' src/utils.sh src/index.sh docker/docker-compose.yaml`
  — no stale "eight-dimension-total" wording remains (the two literal
  "eighth field" references that survive are historically accurate,
  describing `allow_egress` specifically).
- Manual round-trip check: with `STATIC_PLAYGROUND=true`, reproduced the
  `AI_SANDBOX_CONFIG_JSON`/`AI_SANDBOX_CONFIG_B64` assembly logic verbatim in
  an isolated shell, decoded the base64 through `jq`, and confirmed the
  output contains `"static_playground": true` and `"version": 1` alongside
  the other 8 fields, all defaulted.
- `make test.unit` — 300 examples, 7 failures. All 7 failures are
  pre-existing on the phase-start baseline commit (`921b6e8`, i.e. before
  this task's changes): verified by building and running `make test.unit`
  against a throwaway `git worktree` checked out at that commit, which
  reproduces the identical 7 failures (same test names, same "expected ''
  to include ..." symptom, indicating empty script output — a fixture/
  environment issue unrelated to this task's additive, defaulted-`false`
  change). No new failures were introduced by this task's diff.

### Assumptions applied

None beyond the task doc's own scope note (parts 4/5/6 only; `COMPOSE_FILES`
assembly and delete/clean cleanup are Task 002's responsibility).

### Notes for the manager

- The `make test.unit` pre-existing-failure baseline check was done via a
  disposable `git worktree` (removed after use); no artifacts from it remain.
- Task 004 (per this task's own note at the top of `## Validation`) is
  expected to add dedicated unit-test coverage for the new
  `STATIC_PLAYGROUND` dimension (flag parsing, restore round-trip,
  `running_config_matches()` match/mismatch) — none was added here, matching
  the task doc's explicit scope.
</content>
