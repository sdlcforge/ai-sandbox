# Complete Name Resolution And Verb Gating

## Purpose and scope

Complete the per-name "resolve to instance or profile, then verb-gate" dispatch mechanism
stubbed in `phase-01-dispatch-foundation`'s `resolve_name_kind()` extension point, add
profile deletion (via the shared per-name dispatch path, per the resolved
[profiles-delete-ambiguity](../notes/profiles-delete-ambiguity.md) — **not** a
`profiles delete <name>` noun-level command), add profile `detail` (show the profile's
YAML), and ensure profile-kind dispatch short-circuits before the Docker pre-flight and
`profile-installer.js` resolution phases in `src/index.sh`. Depends on `001` (needs
`profile_exists()` and the `profiles.sh` module). No standard skill applies — this is novel
dispatch-gating work specific to this codebase.

## Requirements

1. **Complete `resolve_name_kind()`.** Update the stub from
   `phase-01-dispatch-foundation/001-rewrite-dispatch-grammar.md` (always returning
   `instance`) to: return `profile` if `profile_exists <name>` succeeds and
   `instance_exists <name>` does not; return `instance` if `instance_exists <name>` succeeds
   (regardless of `profile_exists`, since a name cannot legitimately be both after the
   collision checks in `001` — but resolve in favor of `instance` defensively if this
   invariant is ever violated by pre-existing state); return `unknown` if neither matches.
2. **Verb-gating table.** Define the allowed-verb sets per resolved kind:
   - Profile-appropriate verbs: `detail`, `delete` only.
   - Instance-only verbs: everything else in `PER_INSTANCE_COMMANDS` (`start enter attach
     fix-ssh build user-exec root-exec detail stop delete clean up`) plus the passthrough
     fallback (any unrecognized trailing word forwarded to `docker compose`).
   When the per-name dispatch resolves `<name>` to `profile` and the requested `CMD` is not
   in the profile-appropriate set, produce a clear, distinct error: `"Error: '<name>' is a
   profile, not an instance — 'ai-sandbox <name> <cmd>' only supports detail/delete for
   profiles"` (exact wording at implementer's discretion, but must name the resolved kind
   and the offending command). Symmetrically, if a future instance-only verb were attempted
   against a resolved `profile` kind it hits this same gate — no special-casing needed
   beyond the one allow-list check. When `resolve_name_kind` returns `unknown`, produce a
   distinct error from both the reserved-name error and the profile-gating error (e.g.
   `"Error: '<name>' is not a known instance or profile"`).
3. **Profile `delete`.** When `<name>` resolves to `profile` and `CMD=delete`: remove the
   profile's YAML file. Resolve which of the three storage locations owns `<name>` (reuse
   `profile_exists`'s discovery-order logic from `001`, or refactor it to also return the
   resolved path). Refuse deletion with a clear error if the resolved location is the
   bundled/read-only location (bundled profiles ship with the install tree and are not a
   per-user file to remove) — name the bundled path in the error so the user understands why
   it can't be deleted. Deletion of a project-local or user-global profile is a direct file
   removal (`rm`), with the same `confirm_stop_running`-style pattern reused if helpful for
   consistency, or a simpler direct removal — profile deletion has no running-container
   state to protect, so a confirmation prompt is not required by this task (use judgment;
   err toward matching instance-deletion's UX only where it makes sense, not mechanically).
4. **Profile `detail`.** When `<name>` resolves to `profile` and `CMD=detail`: print the
   profile's YAML content (raw file contents is sufficient for V1 — "composed" output,
   i.e. running it through `profile-installer.js`'s merge logic, is not required since a
   single named profile has nothing to compose against). Resolve and read the file the same
   way as item 3.
5. **Docker pre-flight / profile-installer.js short-circuit.** In `src/index.sh`, add a new
   short-circuit branch — alongside the existing `list`/`help`/`kill-local-ai` short-circuits
   before the Docker pre-flight (lines ~28-51 today) — that fires when `resolve_name_kind`
   resolves the current invocation's `SANDBOX_NAME` to `profile`. This branch must run
   `do_profiles_detail`/`profiles_delete` (as dispatched by `CMD`) and `exit 0`/`exit $?`
   *before* the Docker pre-flight check, before `PROJECT_ROOT`/`SCRIPT_DIR` resolution is
   needed for anything beyond the profile file lookup, and before the
   `profile-installer.js` invocation block. A bare YAML file lookup/deletion must not
   require Docker to be running or the profile-composition machinery to execute. Note: this
   requires calling `resolve_name_kind` (or equivalently `profile_exists`) from
   `src/index.sh` itself, early — before `SANDBOX_NAME` is used for anything else — since
   the existing short-circuit block runs before `PROJECT_ROOT` is even computed.
6. **Grouped `ls` output.** Extend `do_list()` (or add a new combined-listing wrapper
   function, implementer's choice — match whichever is less invasive to the existing
   instance-listing table format) so bare `ai-sandbox ls` / `ai-sandbox instances ls` +
   `ai-sandbox profiles ls`'s combined view produces grouped `Instances:` / `Profiles:`
   sections when invoked via the bare `ls` word specifically (not `instances ls`, which
   should remain instances-only, and not `profiles ls`, which should remain profiles-only —
   only the noun-less bare `ls` combines both).

## Validation

- `shellcheck src/index.sh src/options.sh src/profiles.sh src/list.sh` passes with no new
  warnings.
- `make build` succeeds.
- Manual smoke checks:
  - `ai-sandbox <profile-name> detail` (Docker daemon stopped) succeeds and prints the
    profile's YAML — confirms the short-circuit bypasses the Docker pre-flight.
  - `ai-sandbox <profile-name> delete` removes the project-local/user-global profile file;
    repeating `ai-sandbox profiles ls` no longer lists it.
  - `ai-sandbox base delete` (a bundled profile name) is refused with a clear error naming
    the bundled/read-only location.
  - `ai-sandbox <profile-name> enter` (an instance-only verb against a resolved profile)
    produces the "is a profile, not an instance" error, not a passthrough or generic
    error.
  - `ai-sandbox <instance-name> delete` (unchanged instance-deletion behavior) still works
    exactly as before this phase.
  - `ai-sandbox nonexistent-name detail` (resolves to neither) produces the distinct
    "not a known instance or profile" error, not the profile-gating error and not the
    reserved-name error.
  - Bare `ai-sandbox ls` output shows both `Instances:` and `Profiles:` sections;
    `ai-sandbox instances ls` shows only instances; `ai-sandbox profiles ls` shows only
    profiles.

## Metadata

architectural_impact: true

## References

- `plan/phase-02-profiles-resource/001-build-profiles-module.md` — prerequisite task;
  provides `profile_exists()`/`instance_exists()` and the `profiles.sh` module this task
  extends.
- `plan/phase-01-dispatch-foundation/001-rewrite-dispatch-grammar.md` — provides the
  `resolve_name_kind()` stub this task completes.
- `plan/notes/current-dispatch-audit.md` — "Name-resolution / verb-gating design sketch"
  section, including the architecturally-significant short-circuit note.
- `plan/notes/profiles-delete-ambiguity.md` — resolution; confirms `<name> delete` (not
  `profiles delete <name>`) is the only profile-deletion spelling.

## Status

- **Outcome:** succeeded
- **Date:** 2026-07-08
- **Summary:** `resolve_name_kind()` in `src/options.sh` now consults `instance_exists()`
  (src/utils.sh) and `profile_exists()` (src/profiles.sh) — instance wins on a same-name
  collision (defensive only; the phase-02 task 001 create-collision checks already prevent
  this), profile is returned when only `profile_exists` matches, `unknown` otherwise. A new
  Phase 3.5 block in `parse_options()` verb-gates `CMD` against the resolved kind once CMD's
  final value (after any Phase-3 flag-promotion) is known: a `profile`-kind name restricts
  `CMD` to `detail`/`delete` (new `PROFILE_COMMANDS` table) and errors with a distinct,
  kind-and-command-naming message otherwise; an `unknown`-kind name always errors with a
  distinct "not a known instance or profile" message; an `instance`-kind name is completely
  unrestricted (matches pre-existing per-instance dispatch). Added `_profile_resolve_location()`,
  `do_profiles_detail()`, and `profiles_delete()` to `src/profiles.sh` — the first resolves
  which of the three discovery-priority locations owns a profile name (reusing
  `profile_exists()`'s search order) and returns both the path and a source label;
  `do_profiles_detail()` cats the raw YAML (no composition, per Requirement 4);
  `profiles_delete()` does a direct `rm` with no confirmation prompt, refusing (naming the
  path) when the resolved location is `bundled`. `src/index.sh` gained a new profile-kind
  short-circuit — calling `resolve_name_kind()` directly on `SANDBOX_NAME` immediately after
  it's exported, dispatching `detail`/`delete` to the two new functions and `exit`ing —
  placed before the Docker pre-flight, before `PROJECT_ROOT`/`SCRIPT_DIR` resolution, and
  before the `profile-installer.js` invocation block, so a bare YAML lookup/deletion needs
  neither a live Docker daemon nor the profile-composition machinery (confirmed by smoke
  test: `instance_exists()`'s own `2>/dev/null || true` guard makes the `docker ps -a` call
  inside `resolve_name_kind()` fail silently and gracefully when the daemon is down). Bare
  `ls` and `instances ls` are now distinguished: `instances ls`'s sub-verb case sets
  `CMD="instances-ls"` (was `CMD="ls"`, colliding with bare `ls`) so `src/index.sh` can route
  it to an instances-only `do_list()`, while bare `ls` now calls a new `do_list_all()`
  wrapper (`src/list.sh`) that prints "Instances:" + `do_list()` + "Profiles:" +
  `do_profiles_list()` verbatim (no re-implementation of either table's rendering).
  `profiles ls` is unaffected (`CMD="profiles-ls"`, unchanged from phase-02 task 001).
- **Validation:** `shellcheck src/index.sh src/options.sh src/profiles.sh src/list.sh` (the
  literal command from this task's `## Validation`) reports 10 pre-existing SC1091 "not
  following" info notices, all on `src/index.sh` `source` lines that predate this task and
  are unchanged by it (confirmed identical, same 10 lines, against a baseline shellcheck run
  of the pre-task file versions) — an artifact of shellcheck not being given the sourced
  sibling files as input when only these 4 files are passed, not a new warning. `make lint`
  (the project's actual shellcheck target, which passes the full file set so all `source`
  targets resolve) — passed cleanly, zero output, confirming no new warnings of any kind.
  `make build` — passed. Manual smoke checks, all confirmed against the built
  `bin/ai-sandbox.sh` in a scratch project directory with an isolated `XDG_CONFIG_HOME`:
  `<profile-name> detail` with a fake `docker` on `PATH` that fails every call (simulating
  the daemon being down) printed the raw YAML with exit 0, confirming the short-circuit
  bypasses the Docker pre-flight; `<profile-name> delete` removed the project-local profile
  file and a subsequent `profiles ls` no longer listed it; `base delete` (a bundled profile)
  was refused with a clear error naming the bundled path; `base enter` (an instance-only verb
  against a resolved profile) produced the "is a profile, not an instance" error naming both
  the resolved kind and the offending command; `nonexistent-name-xyz detail` produced the
  distinct "not a known instance or profile" error, not the profile-gating or reserved-name
  error; bare `ls` showed grouped `Instances:`/`Profiles:` sections, `instances ls` showed
  instances only, `profiles ls` showed profiles only. `<instance-name> delete` was confirmed
  end-to-end against a real, freshly `instances create`-d throwaway instance (built, started,
  then deleted via `docker compose down`, all through the unmodified `elif CMD == "delete"`
  branch in `src/index.sh`) — the pre-existing real `flow-rook` instance on this host was
  verified untouched (`exited`, same state before and after) throughout all smoke testing.
  `make test.unit` (informational, not part of this task's `## Validation`, matching every
  other task in this plan) — baseline (this task's changes stashed) is 36 failing examples;
  with this task's changes, 54 fail — 18 net-new failures, all attributable to the same root
  cause: `test/unit/ai_sandbox_spec.sh`'s `Describe 'parse_options()'` block (and one
  unrelated `Describe 'command dispatch: exec/passthrough...'` block testing a prior,
  already-fixed unbound-ARGS bug) dispatch synthetic placeholder names (`mybox`/`myname`/
  `dispatchtest`) with no `instance_exists`/`profile_exists`-satisfying mock, so they now hit
  the new, deliberately unconditional `unknown`-kind error this task adds. See
  `flagged_for_manager` in this task's structured report for the full accounting and the
  specific behavior-change tradeoff (implicit instance creation via a bare `enter`/`start` on
  a never-`create`d name is no longer possible — the name must resolve to an existing
  instance or profile, or the dispatch is now rejected up front) this implies, and why phase-
  04-test-coverage's two current task docs (001/002) do not appear to fully anticipate this
  specific breakage category as currently scoped.
- **Affected source files:** `src/options.sh`, `src/profiles.sh`, `src/list.sh`,
  `src/index.sh`, `bin/ai-sandbox.sh` (rollup output, rebuilt via `make build`; not committed
  — gitignored build artifact).
