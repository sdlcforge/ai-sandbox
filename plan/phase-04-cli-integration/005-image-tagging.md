# Image Tagging by Composition Hash — utils.sh

## Purpose and scope

Replace the legacy flag-derived variant-key image-tagging scheme in
`src/utils.sh` with the profile composition-hash scheme. The image tag becomes
`ai-sandbox:profile-<composition-hash>` where the hash comes from
`bin/profile-installer.js` (Task 002), and `is_build_stale` is extended to
consider profile YAML files and referenced `src` files in addition to the
`docker/` directory.

This task depends on Task 002 (provides `PROFILE_IMAGE_TAG` /
`PROFILE_COMPOSITION_HASH` and the list of resolved profile files + referenced
src files). It can proceed in parallel with Task 006 once Task 002 is done.
It edits `src/utils.sh` only; `make build` rolls up to `bin/ai-sandbox.sh`.

The canonical source of truth is
[`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md),
section "Image tagging by profile".

## Requirements

### Replace `variant_key` / `variant_image_tag`

- `variant_key` currently derives a key from `NO_CHROMIUM` / `NO_DOCKER`. Those
  flags are removed (Task 004). Replace its body so it echoes
  `profile-${PROFILE_COMPOSITION_HASH}` (the suffix), reading
  `PROFILE_COMPOSITION_HASH` from the caller scope (set by Task 004 after
  sourcing the installer output). If `PROFILE_COMPOSITION_HASH` is unset, fall
  back to a safe default (`profile-default`) so non-build commands that don't run
  the installer still resolve a tag.
- Do NOT recompute the hash in bash — consume the value Task 002 emits. Add a
  comment stating the hash is owned by `profile-installer.js`.
- `variant_image_tag` continues to print `ai-sandbox:<variant_key>`; with the
  new `variant_key` this yields `ai-sandbox:profile-<hash>`. Keep the function
  name so callers (`ensure_image`, `do_build`, `running_config_matches`,
  `is_build_stale`) need no rename.
- Alternatively, Task 004 may set `AI_SANDBOX_IMAGE_TAG` directly from
  `PROFILE_IMAGE_TAG`; if so, `variant_image_tag` should prefer
  `${AI_SANDBOX_IMAGE_TAG}` when set and only fall back to building from
  `PROFILE_COMPOSITION_HASH`. Pick ONE source of truth and document it; ensure
  Task 004 and this task agree (the resolved tag must be identical whether read
  from the exported var or recomputed from the hash).

### Extend `is_build_stale`

Add inputs beyond `docker/` mtime. The image is stale if ANY of these is newer
than the image's `docker image inspect .Created` timestamp:

1. Any file under `${PROJECT_ROOT}/docker` (existing behavior — keep).
2. Each resolved profile YAML file in the composition.
3. Each `src` file referenced by `skills`, `hooks`, `agents`, and
   `setup_script` in the merged profile.
4. The assembled Dockerfile produced by Task 003 (its inputs are the fragments,
   which live under `docker/`, so this is mostly covered by (1); still account
   for the assembled-file path if it lives outside `docker/`).

To get the list of profile files + referenced src files, consume data the
installer already provides: the file-copy path block (absolute src paths) and
either an added stdout field listing resolved profile-file paths OR have Task 004
export an array (e.g. `PROFILE_INPUT_FILES`) built from the installer output.
Coordinate with Task 004: agree on a single mechanism (recommended: Task 004
exports `PROFILE_INPUT_FILES` as a newline string; `is_build_stale` iterates it).
Document the chosen contract.

Keep the existing `mktemp` + `touch -d` ISO-8601 approach and the "treat failure
as stale" fallback. Preserve the `# shellcheck` conventions.

### `running_config_matches`

- It currently compares `cur_image` to `variant_image_tag` and checks
  `no-isolate-config` / `docker-proxy` labels. Update it to compare against the
  new tag and the new labels added in Task 004 (e.g. `ai.sandbox.profile-hash`,
  `ai.sandbox.mode`, `ai.sandbox.docker-proxy`). Keep return-code semantics
  (0 match / 1 differ / 2 no container). Coordinate label names with Task 004.

### shellcheck

- `src/utils.sh` must pass `make lint`. Add inline reasons for any new
  `# shellcheck disable` directives.

### Integration points

- **Task 002**: source of `PROFILE_COMPOSITION_HASH` / `PROFILE_IMAGE_TAG`.
- **Task 004**: sets the profile globals and labels these functions read; agree
  on `AI_SANDBOX_IMAGE_TAG` source-of-truth and `PROFILE_INPUT_FILES` contract.

## Validation

- `make build` succeeds; `make lint` passes.
- Unit test (Task 007 adds; or smoke here): with
  `PROFILE_COMPOSITION_HASH=a1b2c3d4`, `variant_key` echoes `profile-a1b2c3d4`
  and `variant_image_tag` echoes `ai-sandbox:profile-a1b2c3d4`.
- `grep -n 'NO_CHROMIUM\|NO_DOCKER' src/utils.sh` returns nothing (legacy flags
  gone).
- `is_build_stale` smoke: stub `docker image inspect` to return a fixed old
  timestamp and confirm a freshly-touched profile YAML marks the image stale
  (covered by a Task 007 unit test).

## Assumptions

- The hash is fully determined by `profile-installer.js`; bash only formats the
  tag string.
- `PROFILE_INPUT_FILES` (profile YAMLs + referenced src files) is supplied by
  Task 004 from the installer output rather than re-derived in `utils.sh`.

## References

- [`docs/ai-sandbox-profiles-spec.md`](../../docs/ai-sandbox-profiles-spec.md) —
  "Image tagging by profile".
- `src/utils.sh` — current `variant_key`, `variant_image_tag`,
  `is_build_stale`, `running_config_matches`.
