# Build Profiles Module

## Purpose and scope

Split/rename `src/new-profile.sh` into a `src/profiles.sh` module implementing
`profiles ls` and `profiles create <name> [options]`, add the `instance_exists`/
`profile_exists` helpers, and wire the `profiles` noun word into `src/options.sh`'s
dispatch grammar (parallel to `instances`, landed in `phase-01-dispatch-foundation`). This
task depends on `phase-01-dispatch-foundation`'s two tasks having landed (the noun-parsing
skeleton and reserved-word derivation it builds on). No standard skill applies — this is
novel CRUD/dispatch work specific to this codebase. Per the resolved
[profiles-delete-ambiguity](../notes/profiles-delete-ambiguity.md), profile deletion is
**not** implemented here as a `profiles` noun-level verb — it is completed in
`002-complete-name-resolution-and-verb-gating.md` via the shared per-name dispatch path.

## Requirements

1. **Rename/restructure `src/new-profile.sh` → `src/profiles.sh`.** Preserve
   `new_profile()`'s existing auto-discovery logic (skills/hooks/agents scan under
   `~/.claude`/`./.claude`, the `js-yaml`-via-`node -e` YAML emission strategy, the
   `local: true` detection) unchanged in substance. Rename the function to
   `profiles_create()` (or similar) and change its name-input mechanism from the `--name`
   flag to a **positional** `<name>` argument (matching `instances create <name>`
   symmetry) — `--mode`/`--output`/`--plugins` flags are unchanged. Update `src/index.sh`'s
   `source ./new-profile.sh` to `source ./profiles.sh` (coordinate with task `002`, which
   also touches `src/index.sh` — see that task's Requirements for the split of `src/index.sh`
   changes between these two tasks; this task owns only the `source` line and the
   `profiles ls`/`profiles create` short-circuit dispatch, see item 4).
2. **`profiles ls`.** Implement a function (e.g. `do_profiles_list()`) that lists profile
   names discovered across the three storage locations from
   `docs/ai-sandbox-profiles-spec.md`'s "Profile storage and discovery" section:
   `./profiles/*.yaml` (project-local), `$XDG_CONFIG_HOME/ai-sandbox/profiles/*.yaml`
   (user-global, `$XDG_CONFIG_HOME` defaulting to `~/.config`), and bundled profiles shipped
   in the install tree (see the "Standard profiles (bundled)" table in that spec: `base`,
   `docker`, `chromium`, `mirror`, `static` — locate their actual bundled path in the repo,
   e.g. under a `profiles/` directory relative to `PROJECT_ROOT`; grep the repo to confirm
   the exact bundled-profiles directory before hardcoding a path). De-duplicate by discovery
   priority (project-local wins over user-global wins over bundled, per the spec's search
   order) so a name shadowed at a higher-priority location is listed once, from that
   location. Render output in a table format consistent with `do_list()`'s instance-listing
   convention in `src/list.sh` (columns: NAME, SOURCE — project-local/user-global/bundled —
   and MODE if cheap to read from the YAML's top-level `mode` key without a full
   composition/merge pass; do not invoke `profile-installer.js` for this — a fast, direct
   YAML skim is sufficient and keeps `profiles ls` from requiring Node/js-yaml on every
   call... unless reusing the existing `node -e`/js-yaml pattern from `new_profile()` is
   simpler and the performance cost is negligible for a listing command; use judgment,
   document the choice in a code comment).
3. **`profiles create <name> [options]`.** Wraps the renamed `profiles_create()` from item
   1, taking `<name>` positionally instead of via `--name`. Before writing the file, check
   for a name collision (see item 5) — reject if `<name>` collides with an existing
   instance, an existing profile (any of the three locations), or a reserved word.
4. **`instances`/`profiles` noun-word dispatch.** In `src/options.sh`, extend the noun-word
   recognition added in `phase-01-dispatch-foundation` to also parse `profiles`:
   - `ai-sandbox profiles ls` → route to a `CMD` value dispatched to `do_profiles_list()`
     (e.g. `CMD=profiles-ls`, or reuse a `NOUN`/`CMD` pair — match whatever pattern
     `phase-01-dispatch-foundation`'s task `001` established for `instances`, for
     consistency).
   - `ai-sandbox profiles create <name> [options]` → route to `CMD` dispatched to
     `profiles_create()`, with the same `validate_sandbox_name`/collision-check treatment
     as `instances create` (reusing `check_reserved_name` from the derived reserved-word
     set — `profiles` and `instances` are already members per `phase-01-dispatch-foundation`
     task `001`'s item 1).
   Remove `new-profile` from `src/options.sh`'s recognized global-command words entirely
   (dropped, not aliased, per this plan's no-backward-compatibility stance) and remove its
   short-circuit block in `src/index.sh` (coordinate with task `002`).
5. **`instance_exists <name>` / `profile_exists <name>` helpers.** Add
   `instance_exists()` to `src/utils.sh`, factored out of `src/create.sh`'s `do_create()`
   inlined `docker ps -a --filter "name=^ai-sandbox-<name>$"` collision check (same query,
   now reusable). Add `profile_exists()` to `src/profiles.sh`, consulting the same
   three-location discovery order as item 2's `profiles ls` (return success if any location
   has `<name>.yaml`). Wire both into the `instances create`/`profiles create` collision
   checks (item 3, and `src/create.sh`'s existing check — refactor it to call the new
   `instance_exists()` helper instead of the inline `docker ps -a` query, functionally
   identical). A create-collision check must reject `<name>` colliding with **any** of: an
   existing instance, an existing profile, or a reserved word — regardless of which noun
   (`instances create` or `profiles create`) is being used (a name can't be both an instance
   and a profile).

## Validation

- `shellcheck src/profiles.sh src/options.sh src/utils.sh src/create.sh` passes with no new
  warnings.
- `make build` succeeds.
- `grep -rn 'new-profile\|new_profile' src/` — confirm no remaining references to the old
  command word or function name outside of historical comments explicitly marked as such;
  `src/new-profile.sh` no longer exists (`git status`/`ls src/` confirms the rename).
- Manual smoke checks: `ai-sandbox profiles create test-profile` writes
  `./profiles/test-profile.yaml` (mirroring today's `new-profile --name test-profile`
  output shape); `ai-sandbox profiles ls` lists it; `ai-sandbox profiles create
  test-profile` a second time is rejected as a name collision; `ai-sandbox profiles create
  <existing-instance-name>` is rejected as a name collision; `ai-sandbox instances create
  <existing-profile-name>` is rejected as a name collision (cross-kind collision).
- `ai-sandbox profiles delete <name>` is **not** implemented as a parse path in this task
  (confirm: it either falls through to a clear "unrecognized" error, or is simply not
  reachable — do not add a `profiles delete` noun-level branch; deletion is `002`'s
  per-name-verb responsibility).

## Metadata

architectural_impact: true

## Status

- **Outcome:** succeeded
- **Date:** 2026-07-08
- **Summary:** `src/new-profile.sh` renamed to `src/profiles.sh` (`git mv`); `new_profile()`
  renamed to `profiles_create()`, taking `<name>` positionally (was `--name`) — auto-discovery
  logic (skills/hooks/agents scan, `node -e`/js-yaml emission, `local: true` detection) left
  unchanged in substance. Added `profile_exists()` (three-location discovery: `./profiles/`,
  `$XDG_CONFIG_HOME/ai-sandbox/profiles/`, and the bundled `<project-root>/profiles/` dir —
  confirmed via `bin/profile-installer.js`'s own `findProfile()`, which resolves the bundled
  dir the same way) and `do_profiles_list()` (NAME/SOURCE/MODE table, deduplicated by
  discovery priority; MODE is read via a cheap grep-based YAML skim rather than invoking
  `profile-installer.js`/node, documented in a code comment). Added `instance_exists()` to
  `src/utils.sh`, factored out of `src/create.sh`'s inlined `docker ps -a` collision check;
  `do_create()` now calls it and additionally rejects a name colliding with an existing
  profile (cross-kind collision, item 5). `src/options.sh` gained a `profiles` noun branch
  (parallel to `instances`) recognizing `ls`/`create <name>` only — `CMD` values are
  namespaced (`profiles-ls`/`profiles-create`) since bare `ls`/`create` are already
  contractually tied to `do_list()`/`do_create()`. `src/index.sh`: `source ./new-profile.sh`
  → `source ./profiles.sh`; the old `new-profile` short-circuit replaced with
  `profiles-ls`/`profiles-create` short-circuits (both run before the Docker pre-flight, like
  `ls`/`help`/`kill-local-ai`); `profiles-create`'s short-circuit reconstructs a `--mode`
  flag from `MODE_OVERRIDE` for `profiles_create()`, since `src/options.sh`'s shared Phase 3
  flag parser intercepts `--mode` into `MODE_OVERRIDE` before `ARGS` is built (`--output`/
  `--plugins` are untouched by that parser and pass through in `ARGS` unmodified). `GLOBAL_COMMANDS`
  no longer includes `new-profile` (dropped, not aliased); `src/help.sh`'s stale `new-profile`
  line removed (the rest of `src/help.sh`'s grammar is already known-stale pending the
  `docs-and-help` phase, out of this task's scope). Two portability fixes applied to new code:
  `do_profiles_list()`'s sort uses a `while read` loop instead of `mapfile`/`readarray` (bash
  4+-only), and `profile_exists()`/`instance_exists()`/`profiles_create()` use `${1:-}` instead
  of bare `$1` — both because this script's `#!/bin/bash` shebang resolves to macOS's bundled
  bash 3.2 when run as an installed executable, under `set -euo pipefail`.
- **Validation:** `shellcheck src/profiles.sh src/options.sh src/utils.sh src/create.sh` (the
  exact command in this task's `## Validation`) — passed, no warnings. `make lint` (full
  project, all files including `src/index.sh`/`src/help.sh`) — passed, no new warnings.
  `make build` — passed. `grep -rn 'new-profile\|new_profile' src/` — only historical/
  explanatory comments remain (the rename note atop `src/profiles.sh`, one comment in
  `src/options.sh`); `src/new-profile.sh` no longer exists (`git status` shows the rename).
  Manual smoke checks — all confirmed against the built `bin/ai-sandbox.sh`, invoked directly
  (both via the default shebang resolution and explicitly under `/bin/bash`, i.e. macOS
  system bash 3.2, to catch the portability issues above) in a scratch project directory with
  an isolated `XDG_CONFIG_HOME`: `profiles create test-profile` wrote
  `./profiles/test-profile.yaml`; `profiles ls` listed it (`project-local`, `mode: mirror`)
  alongside the five bundled profiles (`base`/`chromium`/`docker`/`mirror`/`static`) with a
  user-global shadow of the same name correctly suppressed by discovery priority;
  `profiles create test-profile` a second time was rejected as a collision;
  `profiles create flow-rook` (an existing real instance name) was rejected as a collision;
  `instances create test-profile` (cross-kind) was rejected by `do_create()`'s new
  `profile_exists()` check, before any image build or `docker compose up`; `profiles create
  ls`/`profiles create instances` were rejected as reserved names; `profiles delete <name>`
  produced a clear "not a recognized command" error rather than being reachable. No stray
  containers or images were left behind by the cross-kind collision test (confirmed via
  `docker ps -a`). `make test.unit` — run informationally (not part of this task's
  `## Validation`); the pre-existing 34 `Describe 'parse_options()'` failures from task
  `phase-01-dispatch-foundation/001` are unchanged (still deferred to `phase-04-test-coverage`
  per that task's own `## Status`), and the `Describe 'new_profile()'` block (3 examples,
  ~line 1489) now additionally fails because `new_profile` no longer exists — expected and
  consistent with the same deferral: `phase-04-test-coverage/002-add-new-grammar-and-gating-tests.md`
  explicitly names this block as "the natural place to extend/rename" for the `profiles`
  noun's new test coverage, and this task's own `## Validation` deliberately does not include
  `make test.unit`/shellspec.
- **Affected source files:** `src/profiles.sh` (renamed from `src/new-profile.sh`),
  `src/options.sh`, `src/index.sh`, `src/utils.sh`, `src/create.sh`, `src/help.sh`,
  `bin/ai-sandbox.sh` (rollup output, rebuilt via `make build`).

## Assumptions

- `docs/ai-sandbox-profiles-spec.md`'s bundled-profiles directory location is not fully
  pinned down by this task document — grep the repo (`find . -iname '*.yaml' -path
  '*profiles*'` or similar) to locate the actual bundled-profile files before implementing
  discovery, since the spec describes the concept but this task doc doesn't cite an exact
  path.
- The exact `profiles ls` output columns (item 2) are left to implementer judgment beyond
  "NAME, SOURCE, and MODE if cheap" — match `do_list()`'s existing formatting conventions
  in `src/list.sh` for visual consistency.

## References

- `docs/ai-sandbox-profiles-spec.md` — "Profile storage and discovery" and "Standard
  profiles (bundled)" sections.
- `plan/notes/current-dispatch-audit.md` — "Name-resolution / verb-gating design sketch"
  section.
- `plan/notes/profiles-delete-ambiguity.md` — resolution confirming no `profiles delete
  <name>` parse path.
- `src/new-profile.sh` (current implementation, to be renamed/restructured, not deleted and
  rewritten from scratch).
